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
  let _ = @colenc.encode_column(
    @types.ColBuf::Int32s(values),
    @types.Roaring,
    encoded,
  )
  ensure(
    same(
      @colenc.decode_column(
        encoded.to_bytes(),
        @types.Int32,
        @types.Roaring,
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
  dictionary([7, 7, 9, 7, 11, 9, 7, 11, 11])
  roaring([1, 5, 9, 13, 65536, 65537, 131072])
  names()
  errors()
}
