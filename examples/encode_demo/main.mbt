// Encode one column with every family that applies to it, decode it back,
// and print the encoded size against the PLAIN baseline.
//
//   moon run examples/encode_demo
//   moon run examples/encode_demo | sort -t$'\t' -k4,4n
//
// Output columns: encoding/type, value count, encoded bytes, ratio to PLAIN.
// A mismatch aborts: the demo is also a smoke test for the facade.

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
fn ratio(bytes : Int32, plain : Int32) -> String {
  if plain == 0 {
    return "n/a"
  }
  let tenths = bytes * 1000 / plain
  "\{tenths / 10}.\{tenths % 10}%"
}

///|
fn roundtrip(
  column : @colpack_types.ColBuf,
  encoding : @colpack_types.Encoding,
) -> Bytes raise {
  let bytes = encode(column, encoding)
  let back = @colpack.decode_column(
    bytes,
    type_of(column),
    encoding,
    column.value_count(),
  )
  if !same(column, back) {
    abort("round trip failed for \{@colpack_types.encoding_name(encoding)}")
  }
  bytes
}

///|
fn row(name : String, count : Int32, bytes : Int32, plain : Int32) -> Unit {
  println("\{name}\t\{count}\t\{bytes}\t\{ratio(bytes, plain)}")
}

///|
fn main raise {
  let n = 1000

  // Monotonic integers: PLAIN, DELTA, and the dictionary path are all fair.
  let ints = @colpack_types.ColBuf::Int64s(
    Array::makei(n, fn(i) { i.to_int64() * 7L }),
  )
  let plain_ints = roundtrip(ints, @colpack_types.Plain)
  row("plain/int64", n, plain_ints.length(), plain_ints.length())
  let delta = roundtrip(ints, @colpack_types.DeltaBinaryPacked)
  row("delta/int64", n, delta.length(), plain_ints.length())

  // Low-cardinality strings: dictionary and both delta string forms.
  let strings = @colpack_types.ColBuf::ByteArrays(
    Array::makei(n, fn(i) {
      let label = ["bead", "board", "iron", "tray"][i % 4]
      @utf8.encode(label)
    }),
  )
  let plain_strings = roundtrip(strings, @colpack_types.Plain)
  row("plain/string", n, plain_strings.length(), plain_strings.length())
  let dict = @colpack.encode_dictionary(strings) catch {
    e => abort("dictionary failed: \{@colpack_types.EncodingError::message(e)}")
  }
  let dict = match dict {
    Some(dict) => dict
    None => abort("dictionary unexpectedly fell back")
  }
  let dict_bytes = dict.dictionary.length() + dict.indices.length()
  let dict_back = @colpack.decode_dictionary(
    dict.dictionary,
    dict.indices,
    @colpack_types.ByteArray,
    n,
    dict.dictionary_size,
  )
  if !same(strings, dict_back) {
    abort("dictionary round trip failed")
  }
  row("dictionary/string", n, dict_bytes, plain_strings.length())
  let delta_length = roundtrip(strings, @colpack_types.DeltaLength)
  row("delta-length/string", n, delta_length.length(), plain_strings.length())
  let delta_byte_array = roundtrip(strings, @colpack_types.DeltaByteArray)
  row(
    "delta-byte-array/string",
    n,
    delta_byte_array.length(),
    plain_strings.length(),
  )
  let fsst = roundtrip(strings, @colpack_types.Fsst)
  row("fsst/string", n, fsst.length(), plain_strings.length())

  // Floats: BYTE_STREAM_SPLIT is size neutral by design.
  let floats = @colpack_types.ColBuf::Floats(
    Array::makei(n, fn(i) { Float::from_double(i.to_double() / 7.0) }),
  )
  let plain_floats = roundtrip(floats, @colpack_types.Plain)
  row("plain/float", n, plain_floats.length(), plain_floats.length())
  let bss = roundtrip(floats, @colpack_types.ByteStreamSplit)
  row("byte-stream-split/float", n, bss.length(), plain_floats.length())

  // Booleans: the RLE hybrid carries the four-byte length prefix.
  let flags = @colpack_types.ColBuf::Bools(
    Array::makei(n, fn(i) { i % 3 == 0 }),
  )
  let plain_bools = roundtrip(flags, @colpack_types.Plain)
  row("plain/bool", n, plain_bools.length(), plain_bools.length())
  let rle = roundtrip(flags, @colpack_types.Rle)
  row("rle/bool", n, rle.length(), plain_bools.length())
}
