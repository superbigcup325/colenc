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
/// in microseconds.
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

///|
/// One-value containers: the shape a sparse id column produces.
const WIDE_COUNT : Int32 = 32768

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
/// Ascending unique ids: a bitmap is a set, so this is the model every
/// assertion below compares against.
fn model_of(ids : Array[Int32]) -> Array[Int32] {
  let sorted = ids.copy()
  sorted.sort()
  sorted.dedup()
  sorted
}

///|
fn model_union(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() || j < right.length() {
    if j >= right.length() || (i < left.length() && left[i] < right[j]) {
      out.push(left[i])
      i += 1
    } else if i >= left.length() || right[j] < left[i] {
      out.push(right[j])
      j += 1
    } else {
      out.push(left[i])
      i += 1
      j += 1
    }
  }
  out
}

///|
fn model_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    if left[i] < right[j] {
      i += 1
    } else if right[j] < left[i] {
      j += 1
    } else {
      out.push(left[i])
      i += 1
      j += 1
    }
  }
  out
}

///|
/// The first id in 0..65535 that the set does not hold, or -1 when it holds
/// them all; used as a negative probe for `contains`.
fn first_missing(expected : Array[Int32]) -> Int32 {
  let mut index = 0
  let mut probe = 0
  while probe < 65536 {
    while index < expected.length() && expected[index] < probe {
      index += 1
    }
    if index >= expected.length() || expected[index] != probe {
      return probe
    }
    probe += 1
  }
  -1
}

///|
/// Reject a measurement whose result is wrong: a bitmap that looks fast because
/// a call raised, or because a container went missing, must never reach the
/// report. Called before the timers, so its cost is not read as algorithm time.
fn guard_set(
  bitmap : @encoders.RoaringBitmap,
  expected : Array[Int32],
  what : String,
) -> Unit {
  if bitmap.cardinality() != expected.length() {
    abort(
      "\{what}: cardinality \{bitmap.cardinality()} != \{expected.length()}",
    )
  }
  if bitmap.to_array() != expected {
    abort("\{what}: ids differ from the model")
  }
  for id in expected {
    if !bitmap.contains(id) {
      abort("\{what}: missing id \{id}")
    }
  }
  let missing = first_missing(expected)
  if missing >= 0 && bitmap.contains(missing) {
    abort("\{what}: reports id \{missing}, which the model does not hold")
  }
}

///|
fn guard_parse(
  bytes : Bytes,
  expected : Array[Int32],
  what : String,
) -> @encoders.RoaringBitmap {
  let parsed = @encoders.RoaringBitmap::from_bytes(bytes) catch {
    error =>
      abort(
        "\{what}: from_bytes raised (\{@colenc_types.EncodingError::message(error)})",
      )
  }
  guard_set(parsed, expected, "\{what}: round trip")
  if parsed.to_bytes() != bytes {
    abort("\{what}: re-encoding the parsed bitmap changed the bytes")
  }
  parsed
}

///|
fn build_bitmap(ids : Array[Int32], what : String) -> @encoders.RoaringBitmap {
  @encoders.RoaringBitmap::from_ids(ids) catch {
    error =>
      abort(
        "\{what}: from_ids raised (\{@colenc_types.EncodingError::message(error)})",
      )
  }
}

///|
/// One bitmap case: verify it against the model, then report the phases. The
/// case name says which container shape it exercises, and `meta|...` carries
/// the values, cardinality and encoded size that a report needs alongside the
/// timings.
fn bench_bitmap_case(
  b : @bench.Bench,
  sink : @ref.Ref[Int32],
  name : String,
  ids : Array[Int32],
  optimize : Bool,
) -> Unit {
  let expected = model_of(ids)
  let plain = ids.length() * 4
  let values = expected.length()
  let bitmap = build_bitmap(ids, name)
  if optimize {
    bitmap.run_optimize()
  }
  guard_set(bitmap, expected, "\{name}: built")
  let bytes = bitmap.to_bytes()
  let _ = guard_parse(bytes, expected, name)
  // The add path is checked once, here: input order and duplicates must not
  // change the set, and without `run_optimize` it must agree with `from_ids`
  // byte for byte.
  let added = @encoders.RoaringBitmap::new()
  for id in ids {
    added.add(id) catch {
      error =>
        abort(
          "\{name}: add raised (\{@colenc_types.EncodingError::message(error)})",
        )
    }
  }
  guard_set(added, expected, "\{name}: add loop")
  if !optimize && added.to_bytes() != bytes {
    abort("\{name}: the add path and from_ids disagree on the bytes")
  }
  record(b, label("bitmap", name + "-from_ids", plain, values), fn() {
    let built = @encoders.RoaringBitmap::from_ids(ids) catch {
      _ => abort("\{name}: from_ids raised")
    }
    sink.val = sink.val + built.cardinality()
  })
  record(b, label("bitmap", name + "-add", plain, values), fn() {
    let built = @encoders.RoaringBitmap::new()
    for id in ids {
      built.add(id) catch {
        _ => abort("\{name}: add raised")
      }
    }
    sink.val = sink.val + built.cardinality()
  })
  record(b, label("bitmap", name + "-contains", plain, values), fn() {
    let mut hits = 0
    for id in ids {
      if bitmap.contains(id) {
        hits += 1
      }
    }
    sink.val = sink.val + hits
  })
  record(b, label("bitmap", name + "-to_bytes", bytes.length(), values), fn() {
    sink.val = sink.val + bitmap.to_bytes().length()
  })
  record(b, label("bitmap", name + "-from_bytes", bytes.length(), values), fn() {
    let back = @encoders.RoaringBitmap::from_bytes(bytes) catch {
      _ => abort("\{name}: from_bytes raised")
    }
    sink.val = sink.val + back.cardinality()
  })
  // Expanding a set to ids is a separate query from rebuilding it, and the
  // scoreboard timer folds the two together — B asks for them apart.
  if bitmap.to_array().length() != values {
    abort("\{name}: to_array disagrees with the model")
  }
  record(b, label("bitmap", name + "-to_array", plain, values), fn() {
    sink.val = sink.val + bitmap.to_array().length()
  })
  record(
    b,
    label("bitmap", name + "-from_bytes-to_array", bytes.length(), values),
    fn() {
      let back = @encoders.RoaringBitmap::from_bytes(bytes) catch {
        _ => abort("\{name}: from_bytes raised")
      }
      sink.val = sink.val + back.to_array().length()
    },
  )
  // A miss stops inside a present container instead of matching a value, so it
  // gets its own case: one probe per key finds lows the container does not
  // hold. A container filled edge to edge has nothing to miss — the row is
  // dropped rather than timed over three probes.
  let misses : Array[Int32] = []
  let mut seen_key = -65537
  for id in ids {
    let low = id & 0xFFFF
    let base = id - low
    if base != seen_key {
      seen_key = base
      for probe in [1, 65535, 2] {
        let candidate = base + probe
        if !bitmap.contains(candidate) {
          misses.push(candidate)
        }
      }
    }
  }
  if misses.length() >= 256 {
    // The probe count is the miss list, not the set's cardinality: normalizing
    // a miss row by the set size would report a cost ten times too low.
    record(
      b,
      label(
        "bitmap",
        name + "-contains-miss",
        misses.length() * 4,
        misses.length(),
      ),
      fn() {
        let mut found = 0
        for id in misses {
          if bitmap.contains(id) {
            found += 1
          }
        }
        sink.val = sink.val + found
      },
    )
  }
  if optimize {
    record(b, label("bitmap", name + "-run_optimize", plain, values), fn() {
      let copy = @encoders.RoaringBitmap::from_ids(ids) catch {
        _ => abort("\{name}: from_ids raised")
      }
      copy.run_optimize()
      sink.val = sink.val + copy.cardinality()
    })
  }
  println("meta|\{name}|\{ids.length()}|\{values}|\{bytes.length()}|\{plain}")
}

///|
/// Union and intersect for one overlap shape, validated against the model
/// before either timer starts.
fn bench_bitmap_setop(
  b : @bench.Bench,
  sink : @ref.Ref[Int32],
  name : String,
  left_ids : Array[Int32],
  right_ids : Array[Int32],
  optimize : Bool,
) -> Unit {
  let left_model = model_of(left_ids)
  let right_model = model_of(right_ids)
  let union_model = model_union(left_model, right_model)
  let intersect_model = model_intersect(left_model, right_model)
  let left = build_bitmap(left_ids, name)
  let right = build_bitmap(right_ids, name)
  if optimize {
    left.run_optimize()
    right.run_optimize()
  }
  let merged = left.union(right)
  guard_set(merged, union_model, "\{name}: union")
  let shared = left.intersect(right)
  guard_set(shared, intersect_model, "\{name}: intersect")
  // The result must own its containers: a later add may not rewrite an operand.
  merged.add(union_model.length() + 1) catch {
    error =>
      abort(
        "\{name}: add on the union result raised (\{@colenc_types.EncodingError::message(error)})",
      )
  }
  guard_set(left, left_model, "\{name}: left operand after mutating the result")
  guard_set(
    right,
    right_model,
    "\{name}: right operand after mutating the result",
  )
  let plain = (left_ids.length() + right_ids.length()) * 4
  let values = left_ids.length() + right_ids.length()
  record(b, label("bitmap-setop", name + "-union", plain, values), fn() {
    sink.val = sink.val + left.union(right).cardinality()
  })
  record(b, label("bitmap-setop", name + "-intersect", plain, values), fn() {
    sink.val = sink.val + left.intersect(right).cardinality()
  })
  println(
    "meta|setop-\{name}|\{values}|\{union_model.length()}|\{merged.to_bytes().length()}|\{plain}|\{optimize}",
  )
}

///|
/// The bitmap matrix: one case per container shape and per key count, then the
/// three overlap shapes a set operation actually has to handle. Every case is
/// validated against a plain sorted-array model first, so a swallowed error can
/// no longer read as a fast path.
fn bench_roaring(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  // Array containers: 32 ids per key across 3125 keys.
  let sparse = Array::makei(100000, fn(i) { i * 2048 })
  bench_bitmap_case(b, sink, "sparse-array", sparse, false)
  // The same shape at the scoreboard's size: 1M ids over 31250 keys. The
  // per-id cost is the question — a column of 4 MB stops fitting in cache, and
  // the scoreboard row is this size, not the 100k one above.
  let sparse_wide = Array::makei(1000000, fn(i) { i * 2048 })
  bench_bitmap_case(b, sink, "sparse-1m", sparse_wide, false)
  // Bitmap containers: five keys filled edge to edge.
  let dense = Array::makei(300000, fn(i) { i })
  bench_bitmap_case(b, sink, "dense-bitmap", dense, false)
  // The same ids as runs.
  bench_bitmap_case(b, sink, "dense-run", dense, true)
  // All three shapes in one bitmap: an array key, a bitmap key and a run key.
  let mixed : Array[Int32] = []
  for id in [1, 5, 9, 13] {
    mixed.push(id)
  }
  for index in 0..<5000 {
    mixed.push(65536 + index * 2)
  }
  for index in 0..<8000 {
    mixed.push(196608 + index)
  }
  bench_bitmap_case(b, sink, "mixed-shapes", mixed, true)
  // One id per key: 32768 containers, which is the key walk itself.
  let wide = Array::makei(32768, fn(i) { i * 65536 })
  bench_bitmap_case(b, sink, "wide-keys", wide, false)
  // The same 32768 ids, eight per key: 4096 containers instead of 32768, so
  // the difference between this case and `wide-keys` is the per-container cost
  // rather than the per-value cost.
  let grouped : Array[Int32] = []
  for key in 0..<4096 {
    for offset in 0..<8 {
      grouped.push(key * 65536 + offset)
    }
  }
  bench_bitmap_case(b, sink, "few-keys", grouped, false)
  // Overlap shapes: disjoint, partial and identical.
  let disjoint = Array::makei(2000, fn(i) { 400000 + i * 2 })
  bench_bitmap_setop(b, sink, "disjoint", mixed, disjoint, false)
  let partial : Array[Int32] = []
  for index in 0..<mixed.length() {
    if index % 2 == 0 {
      partial.push(mixed[index])
    }
  }
  bench_bitmap_setop(b, sink, "partial", mixed, partial, false)
  bench_bitmap_setop(b, sink, "identical", mixed, mixed, false)
  // A set operation answers differently per container shape, and the
  // scoreboard carries one mixed case. Array, bitmap and run containers, each
  // against a disjoint, a partially overlapping and an identical operand.
  let arr_left : Array[Int32] = []
  for key in 0..<4096 {
    for offset in 0..<8 {
      arr_left.push(key * 65536 + offset)
    }
  }
  let arr_overlap : Array[Int32] = []
  for index in 0..<arr_left.length() {
    if index % 3 == 0 {
      arr_overlap.push(arr_left[index])
    }
  }
  let arr_apart : Array[Int32] = []
  for key in 0..<4096 {
    for offset in 0..<8 {
      arr_apart.push(key * 65536 + 1000 + offset)
    }
  }
  bench_bitmap_setop(b, sink, "array-disjoint", arr_left, arr_apart, false)
  bench_bitmap_setop(b, sink, "array-partial", arr_left, arr_overlap, false)
  bench_bitmap_setop(b, sink, "array-identical", arr_left, arr_left, false)
  let bmp_left = Array::makei(300000, fn(i) { i })
  let bmp_overlap : Array[Int32] = []
  for index in 0..<300000 {
    if index % 2 == 0 {
      bmp_overlap.push(index)
    }
  }
  let bmp_apart = Array::makei(300000, fn(i) { 1048576 + i })
  bench_bitmap_setop(b, sink, "bitmap-disjoint", bmp_left, bmp_apart, false)
  bench_bitmap_setop(b, sink, "bitmap-partial", bmp_left, bmp_overlap, false)
  bench_bitmap_setop(b, sink, "bitmap-identical", bmp_left, bmp_left, false)
  let run_apart = Array::makei(300000, fn(i) { 400000 + i })
  let run_shift : Array[Int32] = Array::makei(300000, fn(i) { i + 1 })
  bench_bitmap_setop(b, sink, "run-disjoint", dense, run_apart, true)
  bench_bitmap_setop(b, sink, "run-partial", dense, run_shift, true)
  bench_bitmap_setop(b, sink, "run-identical", dense, dense, true)
}

///|
fn bench_search(b : @bench.Bench, sink : @ref.Ref[Int32]) -> Unit {
  // The key lookup a bitmap index pays on every probe: a sorted key array of the
  // size a 1M-id column produces, probed in ascending order like a column scan.
  // Four spellings of the same search, so the choice is measured rather than
  // argued: the generic helper as it stands, the same loop with the length
  // hoisted, a branchless variant that reads both halves, and an unchecked one.
  let count = 32768
  let keys : Array[Int32] = Array::makei(count, fn(i) { i * 32 })
  let probes : Array[Int32] = Array::makei(count, fn(i) { i * 32 })
  let plain = count * 4
  record(b, label("search", "generic", plain, count), fn() {
    let mut found = 0
    for probe in probes {
      let mut low = 0
      let mut high = keys.length()
      while low < high {
        let mid = (low + high) >> 1
        if keys[mid] < probe {
          low = mid + 1
        } else {
          high = mid
        }
      }
      if low < keys.length() && keys[low] == probe {
        found += 1
      }
    }
    sink.val = sink.val + found
  })
  record(b, label("search", "hoisted", plain, count), fn() {
    let mut found = 0
    let n = keys.length()
    for probe in probes {
      let mut low = 0
      let mut high = n
      while low < high {
        let mid = low + ((high - low) >> 1)
        if keys[mid] < probe {
          low = mid + 1
        } else {
          high = mid
        }
      }
      if low < n && keys[low] == probe {
        found += 1
      }
    }
    sink.val = sink.val + found
  })
  // Two reads per step and one branch: the comparison is turned into an index
  // update, so the misprediction a data-dependent branch costs disappears.
  record(b, label("search", "branchless", plain, count), fn() {
    let mut found = 0
    let n = keys.length()
    for probe in probes {
      let mut base = 0
      let mut rest = n
      while rest > 1 {
        let half = rest >> 1
        let mid = base + half
        let v = keys[mid]
        base = if v < probe { mid } else { base }
        rest = rest - half
      }
      if base < n && keys[base] == probe {
        found += 1
      }
    }
    sink.val = sink.val + found
  })
  record(b, label("search", "unchecked", plain, count), fn() {
    let mut found = 0
    let n = keys.length()
    for probe in probes {
      let mut low = 0
      let mut high = n
      while low < high {
        let mid = low + ((high - low) >> 1)
        if keys.unsafe_get(mid) < probe {
          low = mid + 1
        } else {
          high = mid
        }
      }
      if low < n && keys.unsafe_get(low) == probe {
        found += 1
      }
    }
    sink.val = sink.val + found
  })
  // The same array probed at one fixed id, as a control: no search movement at
  // all, so it prices the call and the array read alone.
  record(b, label("search", "fixed-probe", plain, count), fn() {
    let mut found = 0
    let probe = probes[count >> 1]
    let n = keys.length()
    for _ in 0..<count {
      let mut low = 0
      let mut high = n
      while low < high {
        let mid = low + ((high - low) >> 1)
        if keys[mid] < probe {
          low = mid + 1
        } else {
          high = mid
        }
      }
      if low < n && keys[low] == probe {
        found += 1
      }
    }
    sink.val = sink.val + found
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
  // What the serialization path costs per value. The bitmap writer used to
  // reach the buffer one byte at a time, and `to_bytes` grew the buffer from
  // zero: these three cases price both halves of that.
  let byte_values : Array[Int32] = Array::makei(WIDE_COUNT, fn(i) { i & 0xFFFF })
  record(b, label("alloc", "u16-two-bytes", WIDE_COUNT * 2, WIDE_COUNT), fn() {
    let out = Buffer()
    for value in byte_values {
      out.write_byte((value & 0xFF).to_byte())
      out.write_byte(((value >> 8) & 0xFF).to_byte())
    }
    sink.val = sink.val + out.length()
  })
  record(
    b,
    label("alloc", "u16-two-bytes-hinted", WIDE_COUNT * 2, WIDE_COUNT),
    fn() {
      let out = Buffer(size_hint=WIDE_COUNT * 2)
      for value in byte_values {
        out.write_byte((value & 0xFF).to_byte())
        out.write_byte(((value >> 8) & 0xFF).to_byte())
      }
      sink.val = sink.val + out.length()
    },
  )
  record(b, label("alloc", "u16-one-call", WIDE_COUNT * 2, WIDE_COUNT), fn() {
    let out = Buffer()
    for value in byte_values {
      out.write_uint16_le(value.to_uint16())
    }
    sink.val = sink.val + out.length()
  })
  record(
    b,
    label("alloc", "u16-scratch-then-write", WIDE_COUNT * 2, WIDE_COUNT),
    fn() {
      let scratch : Array[Byte] = Array::make(WIDE_COUNT * 2, 0)
      for index in 0..<WIDE_COUNT {
        let value = byte_values[index]
        scratch[index * 2] = (value & 0xFF).to_byte()
        scratch[index * 2 + 1] = ((value >> 8) & 0xFF).to_byte()
      }
      let out = Buffer(size_hint=WIDE_COUNT * 2)
      out.write_bytes(Bytes::from_array(scratch))
      sink.val = sink.val + out.length()
    },
  )
  // What a container costs on its own. A bitmap of 32768 one-value containers
  // pays about 30 ns per container; these three cases say whether that is the
  // allocation, the array growth, or neither.
  record(b, label("alloc", "array-make-32768", 0, WIDE_COUNT), fn() {
    let made : Array[Int32] = Array::make(WIDE_COUNT, 0)
    sink.val = sink.val + made.length()
  })
  record(b, label("alloc", "array-push-32768", 0, WIDE_COUNT), fn() {
    let grown : Array[Int32] = []
    for value in 0..<WIDE_COUNT {
      grown.push(value)
    }
    sink.val = sink.val + grown.length()
  })
  record(b, label("alloc", "one-value-arrays", 0, WIDE_COUNT), fn() {
    let mut total = 0
    for value in 0..<WIDE_COUNT {
      let values : Array[Int32] = Array::make(1, value)
      total = total + values[0]
    }
    sink.val = sink.val + total
  })
  // The sparse million-id column decodes 32768 array containers of about 30
  // values each, so this prices the allocation half of that walk.
  record(b, label("alloc", "container-arrays-30", 0, WIDE_COUNT), fn() {
    let mut total = 0
    for _ in 0..<WIDE_COUNT {
      let values : Array[Int32] = Array::make(30, 0)
      total = total + values.length()
    }
    sink.val = sink.val + total
  })
  // `from_bytes` creates each container zero-filled and then overwrites every
  // slot; these two controls price the zeroing separately from the fill.
  record(b, label("alloc", "container-arrays-30-zfill", 0, WIDE_COUNT), fn() {
    let mut total = 0
    for _ in 0..<WIDE_COUNT {
      let values : Array[Int32] = Array::make(30, 0)
      for slot in 0..<30 {
        values[slot] = slot
      }
      total = total + values[29]
    }
    sink.val = sink.val + total
  })
  record(b, label("alloc", "container-arrays-30-uninit", 0, WIDE_COUNT), fn() {
    let mut total = 0
    for _ in 0..<WIDE_COUNT {
      let values : Array[Int32] = Array::unsafe_make_uninit(30)
      for slot in 0..<30 {
        values[slot] = slot
      }
      total = total + values[29]
    }
    sink.val = sink.val + total
  })
  record(b, label("alloc", "bitmap-words-1024-zfill", 0, 64), fn() {
    let mut total = 0L
    for _ in 0..<64 {
      let words : Array[Int64] = Array::make(1024, 0L)
      for slot in 0..<1024 {
        words[slot] = slot.to_int64()
      }
      total = total + words[1023]
    }
    sink.val = sink.val + total.to_int()
  })
  // Same question for a bitmap container's 1024 words: 64 of them is 512 KB.
  record(b, label("alloc", "bitmap-words-1024-uninit", 0, 64), fn() {
    let mut total = 0L
    for _ in 0..<64 {
      let words : Array[Int64] = Array::unsafe_make_uninit(1024)
      for slot in 0..<1024 {
        words[slot] = slot.to_int64()
      }
      total = total + words[1023]
    }
    sink.val = sink.val + total.to_int()
  })
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
  if argv.length() > 1 && argv[1] == "search" {
    bench_search(bencher, sink)
    println(bencher.dump_summaries())
    println("sink=\{sink.val}")
    return
  }
  if argv.length() > 1 && argv[1] == "roaring" {
    bench_roaring(bencher, sink)
    println(bencher.dump_summaries())
    println("sink=\{sink.val}")
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
