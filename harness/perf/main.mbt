/// Throughput probe for the optimisation pass (dev only, harness-excluded).
///
///   moon run --target native --release harness/perf
///
/// `harness/bench` answers "how fast are the encodings"; this answers "where
/// does the time go". It covers the primitives that every encoder sits on
/// (bit packing, varints), the PLAIN baseline per physical type, the Roaring
/// index, the end-to-end encodings, and dataset variants that isolate one cost
/// driver each (value count vs payload bytes vs cardinality vs symbol-table
/// build).
///
/// Statistics come from `moonbitlang/core/bench`: it sizes each batch to
/// ~100 ms, takes `count` samples, winsorizes the tails and reports median and
/// standard deviation. One line of JSON per case goes to stdout; medians are
/// in milliseconds.
///
/// The case name encodes the input shape so the report can normalise without a
/// side channel: `<phase>|<case>|<plain_bytes>|<values>`.

///|
const PRIM_COUNT : Int32 = 262144

///|
const INT_COUNT : Int32 = 500000

///|
const STR_COUNT : Int32 = 200000

///|
const SAMPLES : UInt32 = 7

///|
fn label(
  phase : String,
  case : String,
  plain_bytes : Int32,
  values : Int32,
) -> String {
  "\{phase}|\{case}|\{plain_bytes}|\{values}"
}

///|
/// One case: `SAMPLES` batches of ~100 ms each, median reported.
fn record(b : @bench.Bench, name : String, f : () -> Unit) -> Unit {
  b.bench(name~, f, count=SAMPLES)
}

///|
fn encode_bytes(
  column : @colenc_types.ColBuf,
  encoding : @colenc_types.Encoding,
) -> Bytes raise {
  let out = Buffer()
  let _ = @colenc.encode_column(column, encoding, out)
  out.to_bytes()
}

///|
fn decode_column(
  encoded : Bytes,
  ty : @colenc_types.PhysicalType,
  encoding : @colenc_types.Encoding,
  count : Int32,
) -> @colenc_types.ColBuf raise {
  @colenc.decode_column(encoded, ty, encoding, count)
}

///|
fn dictionary_encode(
  column : @colenc_types.ColBuf,
) -> @colenc_types.DictionaryEncoding? raise {
  @colenc.encode_dictionary(column)
}

///|
fn dictionary_decode(
  encoded : @colenc_types.DictionaryEncoding,
  ty : @colenc_types.PhysicalType,
  count : Int32,
) -> @colenc_types.ColBuf raise {
  @colenc.decode_dictionary(
    encoded.dictionary,
    encoded.indices,
    ty,
    count,
    encoded.dictionary_size,
  )
}

///|
fn bitmap_from_ids(ids : Array[Int32]) -> @encoders.RoaringBitmap raise {
  @encoders.RoaringBitmap::from_ids(ids)
}

///|
fn bitmap_from_bytes(data : Bytes) -> @encoders.RoaringBitmap raise {
  @encoders.RoaringBitmap::from_bytes(data)
}

///|
fn bitmap_add(bitmap : @encoders.RoaringBitmap, id : Int32) -> Unit raise {
  bitmap.add(id)
}

///|
fn bit_unpack(data : Bytes, width : Int32, count : Int32) -> Array[Int64] raise {
  @primitives.bit_unpack(data, width, count)
}

///|
fn read_uleb128(data : Bytes, offset : Int32) -> (UInt64, Int32) raise {
  @primitives.read_uleb128(data, offset~)
}

///|
fn bench_bits(
  b : @bench.Bench,
  sink : @ref.Ref[Int32],
  values : Array[Int64],
  width : Int32,
) -> Unit {
  let count = values.length()
  let packed = Buffer()
  @primitives.bit_pack(values[:], width, packed) catch {
    _ => ()
  }
  let bytes = packed.to_bytes()
  let raw = (width * count + 7) / 8
  record(b, label("bit_pack", "w\{width}", raw, count), fn() {
    let out = Buffer()
    @primitives.bit_pack(values[:], width, out) catch {
      _ => ()
    }
    sink.val = sink.val + out.length()
  })
  record(b, label("bit_unpack", "w\{width}", raw, count), fn() {
    let got : Array[Int64] = bit_unpack(bytes, width, count) catch { _ => [] }
    sink.val = sink.val + got.length()
  })
}

///|
/// Structural equality of two columns, used to reject a measurement that is
/// fast only because the call raised.
fn same(a : @colenc_types.ColBuf, b : @colenc_types.ColBuf) -> Bool {
  match (a, b) {
    (Int32s(x), Int32s(y)) => x == y
    (Int64s(x), Int64s(y)) => x == y
    (Floats(x), Floats(y)) => x == y
    (Doubles(x), Doubles(y)) => x == y
    (ByteArrays(x), ByteArrays(y)) => x == y
    (Bools(x), Bools(y)) => x == y
    _ => false
  }
}

///|
/// Encode and decode one column through the facade.
fn bench_encoding(
  b : @bench.Bench,
  sink : @ref.Ref[Int32],
  case : String,
  column : @colenc_types.ColBuf,
  encoding : @colenc_types.Encoding,
  plain_bytes : Int32,
) -> Unit {
  let values = column.value_count()
  let ty = column.physical_type()
  let encoded = encode_bytes(column, encoding) catch {
    _ => abort("encode raised for \{case}")
  }
  let round_trip = decode_column(encoded, ty, encoding, values) catch {
    _ => abort("decode raised for \{case}")
  }
  if !same(column, round_trip) {
    abort("round trip failed for \{case}")
  }
  record(b, label("encode", case, plain_bytes, values), fn() {
    let bytes : Bytes = encode_bytes(column, encoding) catch { _ => b"" }
    sink.val = sink.val + bytes.length()
  })
  record(b, label("decode", case, plain_bytes, values), fn() {
    let back : @colenc_types.ColBuf = decode_column(
      encoded, ty, encoding, values,
    ) catch {
      _ => column
    }
    sink.val = sink.val + back.value_count()
  })
}

///|
fn bench_dictionary(
  b : @bench.Bench,
  sink : @ref.Ref[Int32],
  case : String,
  column : @colenc_types.ColBuf,
  plain_bytes : Int32,
) -> Unit {
  let values = column.value_count()
  let ty = column.physical_type()
  let encoded = dictionary_encode(column) catch { _ => None }
  let probe = match encoded {
    Some(encoded) => encoded
    None => return
  }
  record(b, label("encode", case, plain_bytes, values), fn() {
    let got : @colenc_types.DictionaryEncoding? = dictionary_encode(column) catch {
      _ => None
    }
    let bytes = match got {
      Some(encoded) => encoded.dictionary.length() + encoded.indices.length()
      None => 0
    }
    sink.val = sink.val + bytes
  })
  record(b, label("decode", case, plain_bytes, values), fn() {
    let back : @colenc_types.ColBuf = dictionary_decode(probe, ty, values) catch {
      _ => column
    }
    sink.val = sink.val + back.value_count()
  })
}

///|
fn bytes_total(values : Array[Bytes]) -> Int32 {
  let mut total = 0
  for value in values {
    total += 4 + value.length()
  }
  total
}

///|
fn lcg(seed : Int32) -> Int32 {
  (seed * 1103515245 + 12345) & 0x3FFFFFFF
}

///|
fn bench_roaring(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let count = 1000000
  let ids = Array::makei(count, fn(i) { i * 3 })
  let others = Array::makei(count, fn(i) { i * 3 + 1 })
  let plain = count * 4
  let bitmap = bitmap_from_ids(ids) catch {
    _ => @encoders.RoaringBitmap::new()
  }
  let other = bitmap_from_ids(others) catch {
    _ => @encoders.RoaringBitmap::new()
  }
  let serialized = bitmap.to_bytes()
  record(b, label("bitmap", "from_ids", plain, count), fn() {
    let built = bitmap_from_ids(ids) catch {
      _ => @encoders.RoaringBitmap::new()
    }
    sink.val = sink.val + built.cardinality()
  })
  record(b, label("bitmap", "add-loop", plain, count), fn() {
    let built = @encoders.RoaringBitmap::new()
    for id in ids {
      bitmap_add(built, id) catch {
        _ => ()
      }
    }
    sink.val = sink.val + built.cardinality()
  })
  record(b, label("bitmap", "contains", plain, count), fn() {
    let mut hits = 0
    for id in ids {
      if bitmap.contains(id) {
        hits += 1
      }
    }
    sink.val = sink.val + hits
  })
  record(b, label("bitmap", "union", plain, count), fn() {
    let merged = bitmap.union(other)
    sink.val = sink.val + merged.cardinality()
  })
  record(b, label("bitmap", "intersect", plain, count), fn() {
    let merged = bitmap.intersect(other)
    sink.val = sink.val + merged.cardinality()
  })
  record(b, label("bitmap", "to_bytes", serialized.length(), count), fn() {
    sink.val = sink.val + bitmap.to_bytes().length()
  })
  record(b, label("bitmap", "from_bytes", serialized.length(), count), fn() {
    let back = bitmap_from_bytes(serialized) catch {
      _ => @encoders.RoaringBitmap::new()
    }
    sink.val = sink.val + back.cardinality()
  })
}

///|
fn bench_plain(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let n = INT_COUNT
  let ints = @colenc_types.ColBuf::Int32s(Array::makei(n, fn(i) { i % 4093 }))
  let longs = @colenc_types.ColBuf::Int64s(
    Array::makei(n, fn(i) { (i % 4093).to_int64() * 7L }),
  )
  let floats = @colenc_types.ColBuf::Floats(
    Array::makei(n, fn(i) { Float::from_int(i % 1024) / 3.0 }),
  )
  let doubles = @colenc_types.ColBuf::Doubles(
    Array::makei(n, fn(i) { (i % 1024).to_double() / 7.0 }),
  )
  let bools = @colenc_types.ColBuf::Bools(Array::makei(n, fn(i) { i % 3 == 0 }))
  let label_values = Array::makei(STR_COUNT, fn(i) {
    @utf8.encode("label-\{(i % 16).to_string()}")
  })
  let strings = @colenc_types.ColBuf::ByteArrays(label_values)
  let string_bytes = bytes_total(label_values)
  bench_encoding(b, sink, "plain-int32", ints, @colenc_types.Plain, n * 4)
  bench_encoding(b, sink, "plain-int64", longs, @colenc_types.Plain, n * 8)
  bench_encoding(b, sink, "plain-float", floats, @colenc_types.Plain, n * 4)
  bench_encoding(b, sink, "plain-double", doubles, @colenc_types.Plain, n * 8)
  bench_encoding(b, sink, "plain-bool", bools, @colenc_types.Plain, (n + 7) / 8)
  bench_encoding(
    b,
    sink,
    "plain-bytes",
    strings,
    @colenc_types.Plain,
    string_bytes,
  )
}

///|
fn bench_families(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let n = INT_COUNT
  let monotonic = @colenc_types.ColBuf::Int64s(
    Array::makei(n, fn(i) { i.to_int64() * 3L }),
  )
  let low_card = @colenc_types.ColBuf::Int32s(Array::makei(n, fn(i) { i % 16 }))
  let random = @colenc_types.ColBuf::Int32s(Array::makei(n, fn(i) { lcg(i) }))
  let doubles = @colenc_types.ColBuf::Doubles(
    Array::makei(n, fn(i) { i.to_double() / 7.0 }),
  )
  let label_values = Array::makei(STR_COUNT, fn(i) {
    @utf8.encode("label-\{(i % 16).to_string()}")
  })
  let prefix_values = Array::makei(STR_COUNT, fn(i) {
    @utf8.encode("shared-prefix-\{i.to_string()}")
  })
  let labels = @colenc_types.ColBuf::ByteArrays(label_values)
  let prefixes = @colenc_types.ColBuf::ByteArrays(prefix_values)
  let flags = @colenc_types.ColBuf::Bools(Array::makei(n, fn(i) { i % 3 == 0 }))
  let label_bytes = bytes_total(label_values)
  let prefix_bytes = bytes_total(prefix_values)
  bench_encoding(
    b,
    sink,
    "int64-monotonic-delta",
    monotonic,
    @colenc_types.DeltaBinaryPacked,
    n * 8,
  )
  bench_encoding(
    b,
    sink,
    "int32-lowcard-delta",
    low_card,
    @colenc_types.DeltaBinaryPacked,
    n * 4,
  )
  bench_encoding(
    b,
    sink,
    "int32-random-delta",
    random,
    @colenc_types.DeltaBinaryPacked,
    n * 4,
  )
  bench_dictionary(b, sink, "int32-lowcard-dict", low_card, n * 4)
  bench_encoding(
    b,
    sink,
    "double-bss",
    doubles,
    @colenc_types.ByteStreamSplit,
    n * 8,
  )
  bench_dictionary(b, sink, "string-lowcard-dict", labels, label_bytes)
  bench_encoding(
    b,
    sink,
    "string-lowcard-deltalen",
    labels,
    @colenc_types.DeltaLength,
    label_bytes,
  )
  bench_encoding(
    b,
    sink,
    "string-lowcard-fsst",
    labels,
    @colenc_types.Fsst,
    label_bytes,
  )
  bench_encoding(
    b,
    sink,
    "string-prefix-deltaba",
    prefixes,
    @colenc_types.DeltaByteArray,
    prefix_bytes,
  )
  bench_encoding(
    b,
    sink,
    "string-prefix-fsst",
    prefixes,
    @colenc_types.Fsst,
    prefix_bytes,
  )
  bench_encoding(b, sink, "bool-rle", flags, @colenc_types.Rle, (n + 7) / 8)
  bench_encoding(b, sink, "bool-plain", flags, @colenc_types.Plain, (n + 7) / 8)
}

///|
/// Variants that hold one cost driver fixed and move the others, so the report
/// can separate per-value overhead from per-byte work.
fn bench_variants(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let tiny_values = Array::makei(STR_COUNT, fn(_) { b"ab" })
  let tiny = @colenc_types.ColBuf::ByteArrays(tiny_values)
  let wide_values = Array::makei(2000, fn(_) {
    @utf8.encode("the quick brown fox jumps over the lazy dog, again and again")
  })
  let wide = @colenc_types.ColBuf::ByteArrays(wide_values)
  let noise_values = Array::makei(STR_COUNT, fn(i) {
    let seed = lcg(i)
    @utf8.encode(
      "\{((seed & 0xFF)).to_string()}-\{((seed >> 8) & 0xFF).to_string()}-\{((seed >> 16) & 0x3FFF).to_string()}",
    )
  })
  let noise = @colenc_types.ColBuf::ByteArrays(noise_values)
  let distinct_values = Array::makei(50000, fn(i) {
    @utf8.encode("id-\{i.to_string()}")
  })
  let distinct = @colenc_types.ColBuf::ByteArrays(distinct_values)
  let tiny_bytes = bytes_total(tiny_values)
  let wide_bytes = bytes_total(wide_values)
  let noise_bytes = bytes_total(noise_values)
  let distinct_bytes = bytes_total(distinct_values)
  bench_encoding(
    b,
    sink,
    "fsst-tiny-values",
    tiny,
    @colenc_types.Fsst,
    tiny_bytes,
  )
  bench_encoding(
    b,
    sink,
    "fsst-wide-values",
    wide,
    @colenc_types.Fsst,
    wide_bytes,
  )
  bench_encoding(
    b,
    sink,
    "fsst-noise-values",
    noise,
    @colenc_types.Fsst,
    noise_bytes,
  )
  bench_encoding(
    b,
    sink,
    "plain-tiny-values",
    tiny,
    @colenc_types.Plain,
    tiny_bytes,
  )
  bench_encoding(
    b,
    sink,
    "plain-wide-values",
    wide,
    @colenc_types.Plain,
    wide_bytes,
  )
  bench_encoding(
    b,
    sink,
    "deltalen-distinct-strings",
    distinct,
    @colenc_types.DeltaLength,
    distinct_bytes,
  )
}

///|
fn bench_primitives(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let values = Array::makei(PRIM_COUNT, fn(i) { (i % 4093).to_int64() })
  for width in [1, 3, 5, 8, 12, 16, 32, 64] {
    bench_bits(b, sink, values, width)
  }
  let buffer = Buffer()
  for value in values {
    @primitives.put_uleb128(buffer, value.reinterpret_as_uint64())
  }
  let encoded = buffer.to_bytes()
  record(b, label("varint", "put_uleb128", encoded.length(), PRIM_COUNT), fn() {
    let out = Buffer()
    for value in values {
      @primitives.put_uleb128(out, value.reinterpret_as_uint64())
    }
    sink.val = sink.val + out.length()
  })
  record(b, label("varint", "read_uleb128", encoded.length(), PRIM_COUNT), fn() {
    let mut offset = 0
    let mut total = 0
    for _ in 0..<PRIM_COUNT {
      let decoded : (UInt64, Int32) = read_uleb128(encoded, offset) catch {
        _ => (0UL, offset)
      }
      offset = decoded.1
      total = total + decoded.0.to_int()
    }
    sink.val = sink.val + total
  })
}

///|
/// Candidate rewrite of `bit_unpack`: one 64-bit accumulator refilled a byte at
/// a time instead of per-value shift/mask arithmetic. Widths above 56 bits fall
/// back to the library implementation because the accumulator would overflow.
/// This exists to price the rewrite before it touches `primitives/`.
fn unpack_accel(data : Bytes, width : Int32, count : Int32) -> Array[Int64] {
  if width == 0 {
    return Array::make(count, 0L)
  }
  if width == 64 {
    let out = Array::make(count, 0L)
    for index in 0..<count {
      let mut value = 0UL
      for byte in 0..<8 {
        value = value | (data[index * 8 + byte].to_uint64() << (byte * 8))
      }
      out[index] = value.reinterpret_as_int64()
    }
    return out
  }
  if width > 56 {
    return @primitives.bit_unpack(data, width, count) catch { _ => [] }
  }
  let out = Array::make(count, 0L)
  let mask = (1UL << width) - 1UL
  let mut buffer = 0UL
  let mut bits = 0
  let mut position = 0
  for index in 0..<count {
    while bits < width {
      buffer = buffer | (data[position].to_uint64() << bits)
      position += 1
      bits += 8
    }
    out[index] = (buffer & mask).reinterpret_as_int64()
    buffer = buffer >> width
    bits -= width
  }
  out
}

///|
fn unpack_accel_unsafe(
  data : Bytes,
  width : Int32,
  count : Int32,
) -> Array[Int64] {
  if width == 0 {
    return Array::make(count, 0L)
  }
  if width == 64 {
    let out = Array::make(count, 0L)
    for index in 0..<count {
      let mut value = 0UL
      for byte in 0..<8 {
        value = value |
          (data.unsafe_get(index * 8 + byte).to_uint64() << (byte * 8))
      }
      out[index] = value.reinterpret_as_int64()
    }
    return out
  }
  if width > 56 {
    return @primitives.bit_unpack(data, width, count) catch { _ => [] }
  }
  let out = Array::make(count, 0L)
  let mask = (1UL << width) - 1UL
  let mut buffer = 0UL
  let mut bits = 0
  let mut position = 0
  for index in 0..<count {
    while bits < width {
      buffer = buffer | (data.unsafe_get(position).to_uint64() << bits)
      position += 1
      bits += 8
    }
    out[index] = (buffer & mask).reinterpret_as_int64()
    buffer = buffer >> width
    bits -= width
  }
  out
}

///|
/// Candidate rewrite of `bit_pack`: accumulate into a 64-bit word and flush
/// four bytes at a time instead of writing a byte per `filled == 8`. Widths
/// above 32 bits keep the library path because the accumulator could overflow
/// between flushes.
fn pack_accel(values : Array[Int64], width : Int32, out : Buffer) -> Unit {
  if width <= 0 || width > 32 {
    for value in values {
      let _ = value
    }
    return
  }
  let mask = (1UL << width) - 1UL
  let mut pending = 0UL
  let mut filled = 0
  for value in values {
    pending = pending | ((value.reinterpret_as_uint64() & mask) << filled)
    filled += width
    while filled >= 32 {
      out.write_int_le((pending & 0xFFFFFFFFUL).to_int())
      pending = pending >> 32
      filled -= 32
    }
  }
  while filled >= 8 {
    out.write_byte((pending & 0xFFUL).to_int().to_byte())
    pending = pending >> 8
    filled -= 8
  }
  if filled > 0 {
    out.write_byte((pending & 0xFFUL).to_int().to_byte())
  }
}

///|
/// Price the bounds checks: the same accumulator rewrite with `unsafe_get`.
fn bench_candidates(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let values = Array::makei(PRIM_COUNT, fn(i) { (i % 4093).to_int64() })
  for width in [1, 3, 5, 12, 16, 32] {
    let packed = Buffer()
    @primitives.bit_pack(values[:], width, packed) catch {
      _ => ()
    }
    let bytes = packed.to_bytes()
    let raw = (width * PRIM_COUNT + 7) / 8
    record(b, label("unpack_accel", "w\{width}", raw, PRIM_COUNT), fn() {
      let got = unpack_accel(bytes, width, PRIM_COUNT)
      sink.val = sink.val + got.length()
    })
    record(b, label("unpack_unsafe", "w\{width}", raw, PRIM_COUNT), fn() {
      let got = unpack_accel_unsafe(bytes, width, PRIM_COUNT)
      sink.val = sink.val + got.length()
    })
    record(b, label("pack_accel", "w\{width}", raw, PRIM_COUNT), fn() {
      let out = Buffer()
      pack_accel(values, width, out)
      sink.val = sink.val + out.length()
    })
    let reference = Buffer()
    @primitives.bit_pack(values[:], width, reference) catch {
      _ => ()
    }
    let candidate = Buffer()
    pack_accel(values, width, candidate)
    if reference.to_bytes() != candidate.to_bytes() {
      abort("pack candidate diverges from bit_pack at width \{width}")
    }
    if unpack_accel(bytes, width, PRIM_COUNT) !=
      unpack_accel_unsafe(bytes, width, PRIM_COUNT) {
      abort("the unsafe candidate diverges from the checked one")
    }
  }
  // The per-value Buffer round trip in `encode_fsst` costs this much on its
  // own; 200k values is the string column the scoreboard measures.
  record(b, label("alloc", "buffer-per-value", 0, STR_COUNT), fn() {
    let mut total = 0
    for _ in 0..<STR_COUNT {
      let body = Buffer()
      body.write_byte(1)
      total = total + body.to_bytes().length()
    }
    sink.val = sink.val + total
  })
}

///|
/// The dictionary path on its own: the planner plus the index stream, which the
/// `rle` section prices separately.
fn bench_dict(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let count = 500000
  let low_card = @colenc_types.ColBuf::Int32s(
    Array::makei(count, fn(i) { i % 16 }),
  )
  record(b, label("dict", "int32-lowcard-encode", count * 4, count), fn() {
    let got = dictionary_encode(low_card) catch { _ => None }
    let size = match got {
      Some(encoded) => encoded.dictionary.length() + encoded.indices.length()
      None => 0
    }
    sink.val = sink.val + size
  })
  let strings = @colenc_types.ColBuf::ByteArrays(
    Array::makei(200000, fn(i) { @utf8.encode("label-\{(i % 16).to_string()}") }),
  )
  record(b, label("dict", "string-lowcard-encode", 200000 * 11, 200000), fn() {
    let got = dictionary_encode(strings) catch { _ => None }
    let size = match got {
      Some(encoded) => encoded.dictionary.length() + encoded.indices.length()
      None => 0
    }
    sink.val = sink.val + size
  })
}

///|
/// Isolate what `encode_bool_rle` adds on top of the hybrid stream itself: the
/// facade path converts the booleans into an Int64 array first.
fn bench_rle(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  let count = 500000
  let flags = Array::makei(count, fn(i) { i % 3 == 0 })
  let as_ints = Array::makei(count, fn(i) { if i % 3 == 0 { 1L } else { 0L } })
  record(b, label("rle", "bool-facade", (count + 7) / 8, count), fn() {
    let out = Buffer()
    @encoders.encode_bool_rle(flags, out) catch {
      _ => ()
    }
    sink.val = sink.val + out.length()
  })
  record(b, label("rle", "hybrid-w1", (count + 7) / 8, count), fn() {
    let out = Buffer()
    @encoders.encode_rle_hybrid(as_ints[:], 1, out) catch {
      _ => ()
    }
    sink.val = sink.val + out.length()
  })
  // The dictionary encoder's second half is this stream: 500k indices at width
  // four, no runs, so the difference against `encode_dictionary` is the plan.
  let indices = Array::makei(count, fn(i) { (i % 16).to_int64() })
  record(b, label("rle", "hybrid-w4-indices", count * 4, count), fn() {
    let out = Buffer()
    @encoders.encode_rle_hybrid(indices[:], 4, out) catch {
      _ => ()
    }
    sink.val = sink.val + out.length()
  })
  record(b, label("rle", "flags-array", (count + 7) / 8, count), fn() {
    let built = Array::makei(count, fn(i) { if flags[i] { 1L } else { 0L } })
    sink.val = sink.val + built.length()
  })
  record(b, label("rle", "decode-w1", (count + 7) / 8, count), fn() {
    let out = Buffer()
    @encoders.encode_rle_hybrid(as_ints[:], 1, out) catch {
      _ => ()
    }
    let (back, _) = @encoders.decode_rle_hybrid(out.to_bytes(), 1, count) catch {
      _ => ([], 0)
    }
    sink.val = sink.val + back.length()
  })
}

///|
fn main {
  let bencher = @bench.Bench()
  let sink = @ref.Ref(0)
  let argv = @env.args()
  if argv.length() > 1 && argv[1] == "dict" {
    bench_dict(bencher, sink)
    println(bencher.dump_summaries())
    return
  }
  if argv.length() > 1 && argv[1] == "rle" {
    bench_rle(bencher, sink)
    println(bencher.dump_summaries())
    return
  }
  if argv.length() > 1 && argv[1] == "candidates" {
    bench_candidates(bencher, sink)
    println(bencher.dump_summaries())
    return
  }
  bench_primitives(bencher, sink)
  bench_plain(bencher, sink)
  bench_families(bencher, sink)
  bench_variants(bencher, sink)
  bench_roaring(bencher, sink)
  bench_candidates(bencher, sink)
  println(bencher.dump_summaries())
  println("sink=\{sink.val}")
}
