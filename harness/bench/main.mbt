// Throughput bench for the scoreboard (dev only).
//
//   moon run --target native harness/bench
//   moon run --target wasm-gc harness/bench
//
// Times encode and decode per encoding on fixed datasets. Output is one
// tab-separated line per case; `harness/scoreboard.py` turns it into the
// markdown table. Iterations adapt to a ~200 ms target per phase so wasm-gc
// gets the same treatment as native.

///|
fn encode(
  column : @colenc_types.ColBuf,
  encoding : @colenc_types.Encoding,
) -> Bytes raise {
  let out = Buffer()
  let _ = @colenc.encode_column(column, encoding, out)
  out.to_bytes()
}

///|
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
fn type_of(column : @colenc_types.ColBuf) -> @colenc_types.PhysicalType {
  match column {
    Int32s(_) => @colenc_types.Int32
    Int64s(_) => @colenc_types.Int64
    Floats(_) => @colenc_types.Float
    Doubles(_) => @colenc_types.Double
    ByteArrays(_) => @colenc_types.ByteArray
    Bools(_) => @colenc_types.Bool
  }
}

///|
fn iterations(estimate_ms : UInt64) -> Int32 {
  if estimate_ms == 0UL {
    20
  } else if estimate_ms > 100UL {
    2
  } else {
    let n = (200UL / estimate_ms).to_int() + 1
    if n > 50 {
      50
    } else {
      n
    }
  }
}

///|
/// Time `body` for `reps` calls, growing the count until the run outlasts the
/// millisecond clock: a bitmap decode can finish inside one tick, and dividing
/// a zero-millisecond total would report 0 MB/s for a working case.
fn timed_loop(reps0 : Int32, body : () -> Unit) -> (Double, Int32) {
  let mut reps = reps0
  let mut elapsed = 0UL
  let mut done = false
  while !done {
    let t0 = @env.now()
    for _ in 0..<reps {
      body()
    }
    elapsed = @env.now() - t0
    if elapsed >= 20UL || reps >= 81920 {
      done = true
    } else {
      reps = reps * 4
    }
  }
  (elapsed.to_double(), reps)
}

///|
fn run(
  name : String,
  column : @colenc_types.ColBuf,
  encoding : @colenc_types.Encoding,
  plain_bytes : Int32,
) -> Unit raise {
  let values = column.value_count()
  let bytes = encode(column, encoding)
  let back = @colenc.decode_column(bytes, type_of(column), encoding, values)
  if !same(column, back) {
    abort("round trip failed for \{name}")
  }

  let t0 = @env.now()
  let _ = encode(column, encoding)
  let estimate = @env.now() - t0
  let (encode_total, encode_reps) = timed_loop(iterations(estimate), fn() {
    let _ = encode(column, encoding) catch {
      _ => abort("encode raised for \{name}")
    }
  })
  let encode_ms = encode_total / encode_reps.to_double()
  let (decode_total, decode_reps) = timed_loop(iterations(estimate), fn() {
    let _ = @colenc.decode_column(bytes, type_of(column), encoding, values) catch {
      _ => abort("decode raised for \{name}")
    }
  })
  let decode_ms = decode_total / decode_reps.to_double()

  println(
    "\{name}\t\{@colenc_types.encoding_name(encoding)}\t\{values}\t\{plain_bytes}\t\{bytes.length()}\t\{encode_ms}\t\{decode_ms}",
  )
}

///|
fn run_dictionary(
  name : String,
  column : @colenc_types.ColBuf,
  plain_bytes : Int32,
) -> Unit raise {
  let values = column.value_count()
  let encoded = @colenc.encode_dictionary(column)
  let encoded = match encoded {
    Some(encoded) => encoded
    None => abort("dictionary unexpectedly fell back for \{name}")
  }
  let bytes = encoded.dictionary.length() + encoded.indices.length()
  let back = @colenc.decode_dictionary(
    encoded.dictionary,
    encoded.indices,
    type_of(column),
    values,
    encoded.dictionary_size,
  )
  if !same(column, back) {
    abort("dictionary round trip failed for \{name}")
  }

  let t0 = @env.now()
  let _ = @colenc.encode_dictionary(column)
  let estimate = @env.now() - t0
  let (encode_total, encode_reps) = timed_loop(iterations(estimate), fn() {
    let _ = @colenc.encode_dictionary(column) catch {
      _ => abort("dictionary encode raised for \{name}")
    }
  })
  let encode_ms = encode_total / encode_reps.to_double()
  let (decode_total, decode_reps) = timed_loop(iterations(estimate), fn() {
    let _ = @colenc.decode_dictionary(
      encoded.dictionary,
      encoded.indices,
      type_of(column),
      values,
      encoded.dictionary_size,
    ) catch {
      _ => abort("dictionary decode raised for \{name}")
    }
  })
  let decode_ms = decode_total / decode_reps.to_double()

  println(
    "\{name}\tdictionary\t\{values}\t\{plain_bytes}\t\{bytes}\t\{encode_ms}\t\{decode_ms}",
  )
}

///|
/// Ascending unique ids: the Roaring encoding is a set, so its round trip
/// returns the sorted set and a bench input for it has to be in that shape.
fn sorted_unique(ids : Array[Int32]) -> Array[Int32] {
  let sorted = ids.copy()
  sorted.sort()
  sorted.dedup()
  sorted
}

///|
fn roaring_encode(ids : Array[Int32], run_optimize : Bool) -> Bytes raise {
  let bitmap = @encoders.RoaringBitmap::from_ids(ids)
  if run_optimize {
    bitmap.run_optimize()
  }
  bitmap.to_bytes()
}

///|
/// A bitmap index row. `plain_bytes` is the raw INT32 id stream it replaces, so
/// the ratio is against the ids themselves and not against a page encoding.
fn run_roaring(
  name : String,
  ids : Array[Int32],
  run_optimize : Bool,
) -> Unit raise {
  let expected = sorted_unique(ids)
  let values = expected.length()
  let plain_bytes = ids.length() * 4
  let bytes = roaring_encode(ids, run_optimize)
  let back = @encoders.RoaringBitmap::from_bytes(bytes)
  if back.to_array() != expected || back.cardinality() != values {
    abort("roaring round trip failed for \{name}")
  }
  let label = if run_optimize { "ROARING+run_optimize" } else { "ROARING" }
  let t0 = @env.now()
  let _ = roaring_encode(ids, run_optimize)
  let estimate = @env.now() - t0
  let (encode_total, encode_reps) = timed_loop(iterations(estimate), fn() {
    let _ = roaring_encode(ids, run_optimize) catch { _ => b"" }
  })
  let encode_ms = encode_total / encode_reps.to_double()
  let (decode_total, decode_reps) = timed_loop(iterations(estimate), fn() {
    let back = @encoders.RoaringBitmap::from_bytes(bytes) catch {
      _ => @encoders.RoaringBitmap::new()
    }
    if back.cardinality() != values {
      abort("roaring decode drifted for \{name}")
    }
  })
  let decode_ms = decode_total / decode_reps.to_double()

  println(
    "\{name}\t\{label}\t\{values}\t\{plain_bytes}\t\{bytes.length()}\t\{encode_ms}\t\{decode_ms}",
  )
}

///|
/// Three container shapes in one bitmap: one array key, one bitmap key and one
/// key that `run_optimize` turns into a run.
fn mixed_ids() -> Array[Int32] {
  let ids : Array[Int32] = []
  for id in [1, 5, 9, 13] {
    ids.push(id)
  }
  for index in 0..<5000 {
    ids.push(65536 + index * 2)
  }
  for index in 0..<8000 {
    ids.push(196608 + index)
  }
  ids
}

///|
fn main raise {
  let n_int = 1000000
  let n_str = 200000

  let monotonic = @colenc_types.ColBuf::Int64s(
    Array::makei(n_int, fn(i) { i.to_int64() * 3L }),
  )
  run("int64-monotonic", monotonic, @colenc_types.Plain, n_int * 8)
  run("int64-monotonic", monotonic, @colenc_types.DeltaBinaryPacked, n_int * 8)

  let low_card = @colenc_types.ColBuf::Int32s(
    Array::makei(n_int, fn(i) { i % 16 }),
  )
  run("int32-low-card", low_card, @colenc_types.Plain, n_int * 4)
  run("int32-low-card", low_card, @colenc_types.DeltaBinaryPacked, n_int * 4)
  run_dictionary("int32-low-card", low_card, n_int * 4)

  let doubles = @colenc_types.ColBuf::Doubles(
    Array::makei(n_int, fn(i) { i.to_double() / 7.0 }),
  )
  run("double", doubles, @colenc_types.Plain, n_int * 8)
  run("double", doubles, @colenc_types.ByteStreamSplit, n_int * 8)

  let labels = @colenc_types.ColBuf::ByteArrays(
    Array::makei(n_str, fn(i) { @utf8.encode("label-\{(i % 16).to_string()}") }),
  )
  let label_bytes = Array::makei(n_str, fn(i) {
    "label-\{(i % 16).to_string()}".length() + 4
  }).fold(init=0, fn(acc, x) { acc + x })
  run("string-low-card", labels, @colenc_types.Plain, label_bytes)
  run_dictionary("string-low-card", labels, label_bytes)
  run("string-low-card", labels, @colenc_types.DeltaLength, label_bytes)
  run("string-low-card", labels, @colenc_types.Fsst, label_bytes)

  let prefixes = @colenc_types.ColBuf::ByteArrays(
    Array::makei(n_str, fn(i) { @utf8.encode("shared-prefix-\{i.to_string()}") }),
  )
  let prefix_bytes = Array::makei(n_str, fn(i) {
    "shared-prefix-\{i.to_string()}".length() + 4
  }).fold(init=0, fn(acc, x) { acc + x })
  run("string-prefix", prefixes, @colenc_types.Plain, prefix_bytes)
  run("string-prefix", prefixes, @colenc_types.DeltaByteArray, prefix_bytes)
  run("string-prefix", prefixes, @colenc_types.Fsst, prefix_bytes)

  let flags = @colenc_types.ColBuf::Bools(
    Array::makei(n_int, fn(i) { i % 3 == 0 }),
  )
  run("bool", flags, @colenc_types.Plain, (n_int + 7) / 8)
  run("bool", flags, @colenc_types.Rle, (n_int + 7) / 8)

  // Bitmap index: the "column" is the set of ids, so the PLAIN baseline is the
  // raw INT32 id stream (4 bytes per id) rather than a page encoding.
  let sparse_ids = Array::makei(n_int, fn(i) { i * 2048 })
  run_roaring("roaring-sparse", sparse_ids, false)
  let dense_ids = Array::makei(n_int, fn(i) { i })
  run_roaring("roaring-dense", dense_ids, false)
  run_roaring("roaring-dense", dense_ids, true)
  let mixed = mixed_ids()
  run_roaring("roaring-mixed", mixed, false)
  run_roaring("roaring-mixed", mixed, true)
}
