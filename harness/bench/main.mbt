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
  column : @colpack_types.ColBuf,
  encoding : @colpack_types.Encoding,
) -> Bytes raise {
  let out = Buffer()
  let _ = @colpack.encode_column(column, encoding, out)
  out.to_bytes()
}

///|
fn same(a : @colpack_types.ColBuf, b : @colpack_types.ColBuf) -> Bool {
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
fn type_of(column : @colpack_types.ColBuf) -> @colpack_types.PhysicalType {
  match column {
    Int32s(_) => @colpack_types.Int32
    Int64s(_) => @colpack_types.Int64
    Floats(_) => @colpack_types.Float
    Doubles(_) => @colpack_types.Double
    ByteArrays(_) => @colpack_types.ByteArray
    Bools(_) => @colpack_types.Bool
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
fn run(
  name : String,
  column : @colpack_types.ColBuf,
  encoding : @colpack_types.Encoding,
  plain_bytes : Int32,
) -> Unit raise {
  let values = column.value_count()
  let bytes = encode(column, encoding)
  let back = @colpack.decode_column(bytes, type_of(column), encoding, values)
  if !same(column, back) {
    abort("round trip failed for \{name}")
  }

  let t0 = @env.now()
  let _ = encode(column, encoding)
  let estimate = @env.now() - t0
  let reps = iterations(estimate)
  let t0 = @env.now()
  for _ in 0..<reps {
    let _ = encode(column, encoding)
  }
  let encode_ms = (@env.now() - t0).to_double() / reps.to_double()

  let t0 = @env.now()
  for _ in 0..<reps {
    let _ = @colpack.decode_column(bytes, type_of(column), encoding, values)
  }
  let decode_ms = (@env.now() - t0).to_double() / reps.to_double()

  println(
    "\{name}\t\{@colpack_types.encoding_name(encoding)}\t\{values}\t\{plain_bytes}\t\{bytes.length()}\t\{encode_ms}\t\{decode_ms}",
  )
}

///|
fn run_dictionary(
  name : String,
  column : @colpack_types.ColBuf,
  plain_bytes : Int32,
) -> Unit raise {
  let values = column.value_count()
  let encoded = @colpack.encode_dictionary(column)
  let encoded = match encoded {
    Some(encoded) => encoded
    None => abort("dictionary unexpectedly fell back for \{name}")
  }
  let bytes = encoded.dictionary.length() + encoded.indices.length()
  let back = @colpack.decode_dictionary(
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
  let _ = @colpack.encode_dictionary(column)
  let estimate = @env.now() - t0
  let reps = iterations(estimate)
  let t0 = @env.now()
  for _ in 0..<reps {
    let _ = @colpack.encode_dictionary(column)
  }
  let encode_ms = (@env.now() - t0).to_double() / reps.to_double()

  let t0 = @env.now()
  for _ in 0..<reps {
    let _ = @colpack.decode_dictionary(
      encoded.dictionary,
      encoded.indices,
      type_of(column),
      values,
      encoded.dictionary_size,
    )
  }
  let decode_ms = (@env.now() - t0).to_double() / reps.to_double()

  println(
    "\{name}\tdictionary\t\{values}\t\{plain_bytes}\t\{bytes}\t\{encode_ms}\t\{decode_ms}",
  )
}

///|
fn main raise {
  let n_int = 1000000
  let n_str = 200000

  let monotonic = @colpack_types.ColBuf::Int64s(
    Array::makei(n_int, fn(i) { i.to_int64() * 3L }),
  )
  run("int64-monotonic", monotonic, @colpack_types.Plain, n_int * 8)
  run("int64-monotonic", monotonic, @colpack_types.DeltaBinaryPacked, n_int * 8)

  let low_card = @colpack_types.ColBuf::Int32s(
    Array::makei(n_int, fn(i) { i % 16 }),
  )
  run("int32-low-card", low_card, @colpack_types.Plain, n_int * 4)
  run("int32-low-card", low_card, @colpack_types.DeltaBinaryPacked, n_int * 4)
  run_dictionary("int32-low-card", low_card, n_int * 4)

  let doubles = @colpack_types.ColBuf::Doubles(
    Array::makei(n_int, fn(i) { i.to_double() / 7.0 }),
  )
  run("double", doubles, @colpack_types.Plain, n_int * 8)
  run("double", doubles, @colpack_types.ByteStreamSplit, n_int * 8)

  let labels = @colpack_types.ColBuf::ByteArrays(
    Array::makei(n_str, fn(i) { @utf8.encode("label-\{(i % 16).to_string()}") }),
  )
  let label_bytes = Array::makei(n_str, fn(i) {
    "label-\{(i % 16).to_string()}".length() + 4
  }).fold(init=0, fn(acc, x) { acc + x })
  run("string-low-card", labels, @colpack_types.Plain, label_bytes)
  run_dictionary("string-low-card", labels, label_bytes)
  run("string-low-card", labels, @colpack_types.DeltaLength, label_bytes)
  run("string-low-card", labels, @colpack_types.Fsst, label_bytes)

  let prefixes = @colpack_types.ColBuf::ByteArrays(
    Array::makei(n_str, fn(i) { @utf8.encode("shared-prefix-\{i.to_string()}") }),
  )
  let prefix_bytes = Array::makei(n_str, fn(i) {
    "shared-prefix-\{i.to_string()}".length() + 4
  }).fold(init=0, fn(acc, x) { acc + x })
  run("string-prefix", prefixes, @colpack_types.Plain, prefix_bytes)
  run("string-prefix", prefixes, @colpack_types.DeltaByteArray, prefix_bytes)
  run("string-prefix", prefixes, @colpack_types.Fsst, prefix_bytes)

  let flags = @colpack_types.ColBuf::Bools(
    Array::makei(n_int, fn(i) { i % 3 == 0 }),
  )
  run("bool", flags, @colpack_types.Plain, (n_int + 7) / 8)
  run("bool", flags, @colpack_types.Rle, (n_int + 7) / 8)
}
