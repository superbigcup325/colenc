/// A consumer of the published package, kept outside the module.
///
/// `harness/check_consumer.py` copies this file into a temporary module whose
/// only members are the archive `moon package` produced and this consumer, then
/// runs it on native, wasm-gc and JS. So: public API only, no `harness/` import,
/// no file or network access, deterministic output on one line per case.
///
/// The program checks itself (a failed round trip aborts) and prints the few
/// facts the checker compares: value counts, container cardinalities and the
/// encoded sizes it can compare against each other. Nothing here pins absolute
/// byte counts, so a future encoding change does not fail the consumer unless
/// it breaks behaviour or the size relations the checks name.

///|
/// `ColBuf` carries no `Eq` impl on purpose (arrays of floats have no single
/// right equality), so the consumer compares columns by their canonical PLAIN
/// bytes: for every physical type PLAIN is a bijection on the value stream.
fn same(back : @types.ColBuf, original : @types.ColBuf) -> Bool raise {
  let left = Buffer()
  let _ = @colenc.encode_column(back, @types.Plain, left)
  let right = Buffer()
  let _ = @colenc.encode_column(original, @types.Plain, right)
  left.to_bytes() == right.to_bytes()
}

///|
fn same_ids(left : Array[Int32], right : Array[Int32]) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for index in 0..<left.length() {
    if left[index] != right[index] {
      return false
    }
  }
  true
}

///|
fn plain_int32(values : Array[Int32]) -> Unit raise {
  let column = @types.ColBuf::Int32s(values)
  let out = Buffer()
  let stats = @colenc.encode_column(column, @types.Plain, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.Int32,
    @types.Plain,
    values.length(),
  )
  ensure(same(back, column), "plain int32 round trip")
  println(
    "plain-int32|\{stats.value_count}|\{stats.encoded_bytes}|\{bytes.length()}",
  )
}

///|
fn delta_int64(values : Array[Int64]) -> Unit raise {
  let column = @types.ColBuf::Int64s(values)
  let out = Buffer()
  let stats = @colenc.encode_column(column, @types.DeltaBinaryPacked, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.Int64,
    @types.DeltaBinaryPacked,
    values.length(),
  )
  ensure(same(back, column), "delta int64 round trip")
  // A monotonic column of a million values would still be a few kilobytes, so
  // the size relation is what the checker compares, not the exact number.
  println("delta-int64|\{stats.encoded_bytes}|\{bytes.length()}")
}

///|
fn rle_bool(values : Array[Bool]) -> Unit raise {
  let column = @types.ColBuf::Bools(values)
  let out = Buffer()
  let _ = @colenc.encode_column(column, @types.Rle, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.Bool,
    @types.Rle,
    values.length(),
  )
  ensure(same(back, column), "rle bool round trip")
  println("rle-bool|\{bytes.length()}")
}

///|
fn bss_double(values : Array[Double]) -> Unit raise {
  let column = @types.ColBuf::Doubles(values)
  let out = Buffer()
  let _ = @colenc.encode_column(column, @types.ByteStreamSplit, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.Double,
    @types.ByteStreamSplit,
    values.length(),
  )
  ensure(same(back, column), "byte stream split round trip")
  // Planes are a permutation of the same bytes, so the size is size-neutral by
  // design and worth asserting rather than inferring.
  println("bss-double|\{bytes.length()}|\{values.length() * 8}")
}

///|
fn delta_byte_array(values : Array[Bytes]) -> Unit raise {
  let column = @types.ColBuf::ByteArrays(values)
  let out = Buffer()
  let _ = @colenc.encode_column(column, @types.DeltaByteArray, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.ByteArray,
    @types.DeltaByteArray,
    values.length(),
  )
  ensure(same(back, column), "delta byte array round trip")
  let plain = Buffer()
  let _ = @colenc.encode_column(column, @types.Plain, plain)
  println("delta-byte-array|\{bytes.length()}|\{plain.length()}")
}

///|
fn fsst(values : Array[Bytes]) -> Unit raise {
  let column = @types.ColBuf::ByteArrays(values)
  let out = Buffer()
  let _ = @colenc.encode_column(column, @types.Fsst, out)
  let bytes = out.to_bytes()
  let back = @colenc.decode_column(
    bytes,
    @types.ByteArray,
    @types.Fsst,
    values.length(),
  )
  ensure(same(back, column), "fsst round trip")
  println("fsst|\{bytes.length()}")
}

///|
fn dictionary(values : Array[Int32]) -> Unit raise {
  let column = @types.ColBuf::Int32s(values)
  let encoded = @colenc.encode_dictionary(column)
  let encoded = match encoded {
    Some(encoded) => encoded
    None => abort("consumer: dictionary unexpectedly fell back to PLAIN")
  }
  let back = @colenc.decode_dictionary(
    encoded.dictionary,
    encoded.indices,
    @types.Int32,
    values.length(),
    encoded.dictionary_size,
  )
  ensure(same(back, column), "dictionary round trip")
  println(
    "dictionary|\{encoded.dictionary_size}|\{encoded.bit_width}|\{encoded.dictionary.length()}|\{encoded.indices.length()}",
  )
}

///|
fn roaring(values : Array[Int32]) -> Unit raise {
  // The facade path: a set encoding over non-negative INT32 ids. The round trip
  // returns the sorted, duplicate-free set, which is what the guard compares.
  let bitmap = @encoders.RoaringBitmap::from_ids(values)
  let sorted = bitmap.to_array()
  ensure(sorted.length() == bitmap.cardinality(), "roaring cardinality")
  ensure(
    same_ids(@encoders.decode_roaring(bitmap.to_bytes()), sorted),
    "roaring round trip",
  )
  let encoded = Buffer()
  let _ = @colenc.encode_roaring_column(@types.ColBuf::Int32s(values), encoded)
  ensure(
    same(
      @colenc.decode_roaring_column(
        encoded.to_bytes(),
        @types.Int32,
        sorted.length(),
      ),
      @types.ColBuf::Int32s(sorted),
    ),
    "roaring column round trip",
  )
  // Set semantics: a union with a disjoint set adds its ids and leaves both
  // operands alone.
  let left = @encoders.RoaringBitmap::from_ids([1, 5, 9])
  let right = @encoders.RoaringBitmap::from_ids([2, 6, 10])
  let merged = left.union(right)
  ensure(merged.cardinality() == 6, "roaring union cardinality")
  ensure(
    left.cardinality() == 3 && right.cardinality() == 3,
    "roaring operands",
  )
  ensure(merged.intersect(left).cardinality() == 3, "roaring intersect")
  println(
    "roaring|\{bitmap.cardinality()}|\{encoded.to_bytes().length()}|\{merged.cardinality()}",
  )
}

///|
fn sketches() -> Unit raise {
  // The sketch package is public surface from 0.1.1 on: a consumer builds both,
  // serializes them, reads them back and compares an answer. If the archive ever
  // ships this package without its interfaces, this call is what notices.
  let hll = @sketches.HllSketch::new_default()
  for index in 0..<500 {
    hll.add_int32(index)
  }
  let hll_bytes = hll.to_bytes()
  let hll_back = @sketches.HllSketch::from_bytes(hll_bytes.exact_view())
  ensure(
    hll_back.to_bytes() == hll_bytes,
    "hll round trip through the packaged surface",
  )
  ensure(hll.estimate() > 400.0 && hll.estimate() < 600.0, "hll estimate")

  let digest = @sketches.TDigest::new_default()
  for index in 0..<500 {
    digest.update(index.to_double())
  }
  let median = digest.quantile(0.5)
  ensure(median > 200.0 && median < 300.0, "t-digest median")
  let digest_bytes = digest.to_bytes()
  let digest_back = @sketches.TDigest::from_bytes(digest_bytes.exact_view())
  ensure(
    digest_back.to_bytes() == digest_bytes,
    "t-digest round trip through the packaged surface",
  )
  println(
    "sketches|\{hll.estimate()}|\{hll_back.precision()}|\{median}|\{digest_back.compression()}",
  )
}

///|

///|
fn roaring_is_outside_the_dispatch() -> Unit {
  // The separation is part of the contract: the generic entry points refuse the
  // set encoding so that consumers of a page family do not link the bitmap.
  let out = Buffer()
  let refused = try {
    let _ = @colenc.encode_column(
      @types.ColBuf::Int32s([1, 2, 3]),
      @types.Roaring,
      out,
    )
    false
  } catch {
    @types.EncodingError::Unsupported(@types.Roaring) => true
    _ => false
  }
  ensure(refused, "encode_column must refuse Roaring")
  let refused = try {
    let _ = @colenc.decode_column(b"\x00"[:], @types.Int32, @types.Roaring, 0)
    false
  } catch {
    @types.EncodingError::Unsupported(@types.Roaring) => true
    _ => false
  }
  ensure(refused, "decode_column must refuse Roaring")
}

///|
/// A model trained on one batch encodes that batch to the bytes the one-shot
/// encoder writes, and encodes a held-out batch that the frame decodes without
/// the model.
fn fsst_model(train : Array[Bytes], held : Array[Bytes]) -> Unit raise {
  let model = @encoders.FsstModel::train(train)
  let own = Buffer()
  @encoders.encode_fsst_with(model, train, own)
  let one_shot = Buffer()
  @encoders.encode_fsst(train, one_shot)
  ensure(
    own.to_bytes() == one_shot.to_bytes(),
    "fsst model on its training batch matches the one-shot encoder",
  )
  let reused = Buffer()
  @encoders.encode_fsst_with(model, held, reused)
  let (back, consumed) = @encoders.decode_fsst(
    reused.to_bytes()[:],
    held.length(),
  )
  ensure(consumed == reused.length(), "fsst model frame consumed in full")
  ensure(back.length() == held.length(), "fsst model held-out count")
  for index in 0..<held.length() {
    ensure(back[index] == held[index], "fsst model held-out value \{index}")
  }
  ensure(
    same(
      @colenc.decode_column(
        reused.to_bytes(),
        @types.ByteArray,
        @types.Fsst,
        held.length(),
      ),
      @types.ColBuf::ByteArrays(held),
    ),
    "fsst model frame through decode_column",
  )
  println(
    "fsst-model|\{model.table_bytes()}|\{own.length()}|\{reused.length()}",
  )
}

///|
/// `registers()` is a snapshot and `register(index)` reads the live state; an
/// index outside the table is a typed error.
fn hll_register() -> Unit raise {
  let hll = @sketches.HllSketch::new_default()
  for index in 0..<200 {
    hll.add_int32(index)
  }
  let before = hll.registers()
  let mut before_sum = 0
  for rank in before {
    before_sum += rank
  }
  for index in 200..<5000 {
    hll.add_int32(index)
  }
  let mut still_sum = 0
  for rank in before {
    still_sum += rank
  }
  ensure(
    still_sum == before_sum,
    "hll registers() snapshot tracked a later update",
  )
  let after = hll.registers()
  ensure(after.length() == hll.register_count(), "hll snapshot length")
  let mut changed = 0
  for index in 0..<after.length() {
    ensure(hll.register(index) == after[index], "hll register(index) disagrees")
    if after[index] != before[index] {
      changed += 1
    }
  }
  ensure(changed > 0, "hll updates changed no register")
  let low = try {
    let _ = hll.register(-1)
    false
  } catch {
    @types.EncodingError::OutOfRange(_, _) => true
    _ => false
  }
  let high = try {
    let _ = hll.register(hll.register_count())
    false
  } catch {
    @types.EncodingError::OutOfRange(_, _) => true
    _ => false
  }
  ensure(low && high, "hll register out of range must be OutOfRange")
  println("hll-register|\{after.length()}|\{changed}")
}

///|
/// Count-only intersection, overlap and ordered batches, each checked against
/// the materialized operation or an expected set computed independently.
fn roaring_query() -> Unit raise {
  let left_ids = Array::makei(30000, fn(i) { i * 3 })
  let right_ids = Array::makei(18000, fn(i) { i * 5 })
  let left = @encoders.RoaringBitmap::from_ids(left_ids)
  let right = @encoders.RoaringBitmap::from_ids(right_ids)
  let count = left.intersection_cardinality(right)
  ensure(
    count == left.intersect(right).cardinality(),
    "intersection_cardinality disagrees with intersect",
  )
  // common multiples of 3 and 5 below 89996: 0, 15, ..., 89985
  ensure(count == 6000, "intersection_cardinality against the arithmetic count")
  ensure(left.intersects(right), "intersects on overlapping sets")
  let small = @encoders.RoaringBitmap::from_ids([1, 5, 70000]).intersection_cardinality(
    @encoders.RoaringBitmap::from_ids([5, 70000, 70001]),
  )
  ensure(small == 2, "intersection_cardinality across two keys")
  let disjoint = @encoders.RoaringBitmap::from_ids([1, 2, 3]).intersects(
    @encoders.RoaringBitmap::from_ids([4, 5, 65536]),
  )
  ensure(!disjoint, "intersects on disjoint sets")
  let all : Array[Int32] = []
  let mut after = -1L
  while true {
    let batch = left.ids_after(after, 1000)
    for id in batch {
      all.push(id)
    }
    if batch.length() < 1000 {
      break
    }
    after = batch[batch.length() - 1].to_int64()
  }
  ensure(same_ids(all, left.to_array()), "ids_after batches against to_array")
  ensure(same_ids(all, left_ids), "ids_after batches against the input ids")
  ensure(left.cardinality() == 30000, "operands untouched by the queries")
  println("roaring-query|\{count}|\{small}|\{all.length()}")
}

///|
fn names() -> Unit {
  // The neutral model is public surface too: a consumer switches on these.
  println(
    "names|\{@types.encoding_name(@types.Roaring)}|\{@types.physical_type_name(@types.Int32)}",
  )
}

///|
fn errors() -> Unit {
  // An id the Roaring surface cannot represent is a typed error, not a panic.
  let out = Buffer()
  let rejected = try {
    @encoders.encode_roaring([-1], out)
    false
  } catch {
    @types.EncodingError::OutOfRange(_, _) => true
    _ => false
  }
  ensure(rejected, "negative id must be OutOfRange")
  // A family the column type cannot take is reported, not silently encoded.
  let mismatched = try {
    let sink = Buffer()
    let _ = @colenc.encode_column(
      @types.ColBuf::Int32s([1, 2, 3]),
      @types.Rle,
      sink,
    )
    false
  } catch {
    @types.EncodingError::TypeMismatch(_, _) => true
    _ => false
  }
  ensure(mismatched, "RLE over int32 must be TypeMismatch")
  println("errors|out-of-range|type-mismatch")
}

///|
fn ensure(ok : Bool, what : String) -> Unit {
  if !ok {
    abort("consumer: \{what} failed")
  }
}

///|
fn main raise {
  let ints : Array[Int32] = []
  for index in 0..<16 {
    ints.push(1000 + index * 3)
  }
  plain_int32(ints)
  let longs : Array[Int64] = []
  for index in 0..<64 {
    longs.push(1_700_000_000_000L + index.to_int64() * 250L)
  }
  delta_int64(longs)
  let bools : Array[Bool] = []
  for index in 0..<60 {
    bools.push(index < 50)
  }
  rle_bool(bools)
  let doubles : Array[Double] = []
  for index in 0..<8 {
    doubles.push(index.to_double() * 1.5)
  }
  bss_double(doubles)
  let strings : Array[Bytes] = [
    b"region-0-bucket-0-suffix", b"region-1-bucket-7-suffix", b"region-2-bucket-14-suffix",
    b"region-0-bucket-21-suffix", b"region-1-bucket-28-suffix", b"region-2-bucket-35-suffix",
    b"region-0-bucket-42-suffix", b"region-1-bucket-49-suffix",
  ]
  delta_byte_array(strings)
  fsst(strings)
  let held_out : Array[Bytes] = [
    b"region-3-bucket-56-suffix", b"region-0-bucket-63-suffix", b"", b"\xff\x00\xff",
    b"region-1-bucket-70-suffix", b"unrelated",
  ]
  fsst_model(strings, held_out)
  dictionary([7, 7, 9, 7, 11, 9, 7, 11, 11])
  roaring([1, 5, 9, 13, 65536, 65537, 131072])
  roaring_is_outside_the_dispatch()
  roaring_query()
  hll_register()
  sketches()
  names()
  errors()
}
