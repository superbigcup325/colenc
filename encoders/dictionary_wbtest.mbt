/// Whitebox tests for dictionary encoding: dictionary contents and order, the
/// bit-width rule, exact payload bytes, and the fallback and rejection paths.

///|
test "dictionary keeps first-appearance order and dedups" {
  let column = @types.ColBuf::Int32s([5, 7, 5, 9])
  let encoding = encode_dictionary(column) catch { _ => abort("encode failed") }
  let encoding = match encoding {
    Some(encoding) => encoding
    None => abort("unexpected fallback")
  }
  assert_eq(encoding.dictionary_size, 3)
  assert_eq(encoding.bit_width, 2)
  assert_eq(
    encoding.dictionary,
    b"\x05\x00\x00\x00\x07\x00\x00\x00\x09\x00\x00\x00",
  )
  // width 2, one literal group: 0,1,0,2 packed LSB first
  assert_eq(encoding.indices, b"\x02\x03\x84\x00")
}

///|
test "dictionary bit width follows the reference rule" {
  let cases : Array[(Int32, Int32)] = [
    (1, 1),
    (2, 1),
    (3, 2),
    (4, 2),
    (5, 3),
    (8, 3),
    (9, 4),
  ]
  for entry in cases {
    let values = Array::makei(entry.0, fn(index) { index })
    let encoding = encode_dictionary(@types.ColBuf::Int32s(values)) catch {
      _ => abort("encode failed")
    }
    let encoding = match encoding {
      Some(encoding) => encoding
      None => abort("unexpected fallback")
    }
    assert_eq(encoding.bit_width, entry.1)
    assert_eq(encoding.dictionary_size, entry.0)
  }
}

///|
test "dictionary round trips every supported physical type" {
  let cases : Array[@types.ColBuf] = [
    @types.ColBuf::Int32s([3, 1, 3, 2, 1, 3]),
    @types.ColBuf::Int64s([1L, 2L, 1L, -1L]),
    @types.ColBuf::Floats([Float(1.5), Float(2.5), Float(1.5)]),
    @types.ColBuf::Doubles([1.5, 2.5, 1.5]),
    @types.ColBuf::ByteArrays([b"aa", b"bb", b"aa", b""]),
  ]
  for column in cases {
    let encoding = encode_dictionary(column) catch {
      _ => abort("encode failed")
    }
    let encoding = match encoding {
      Some(encoding) => encoding
      None => abort("unexpected fallback")
    }
    let back = decode_dictionary(
      encoding.dictionary,
      encoding.indices,
      column.physical_type(),
      column.value_count(),
      encoding.dictionary_size,
    ) catch {
      _ => abort("decode failed")
    }
    match (column, back) {
      (Int32s(want), Int32s(got)) => assert_eq(got, want)
      (Int64s(want), Int64s(got)) => assert_eq(got, want)
      (Floats(want), Floats(got)) => assert_eq(got, want)
      (Doubles(want), Doubles(got)) => assert_eq(got, want)
      (ByteArrays(want), ByteArrays(got)) => assert_eq(got, want)
      _ => abort("round trip changed the physical type")
    }
  }
}

///|
test "dictionary treats float zero signs as distinct entries" {
  let column = @types.ColBuf::Floats([Float(0.0), Float(-0.0), Float(0.0)])
  let encoding = encode_dictionary(column) catch { _ => abort("encode failed") }
  let encoding = match encoding {
    Some(encoding) => encoding
    None => abort("unexpected fallback")
  }
  assert_eq(encoding.dictionary_size, 2)
  assert_eq(encoding.bit_width, 1)
}

///|
test "dictionary falls back when the dictionary page is too large" {
  let column = @types.ColBuf::Int32s([5, 7, 5, 9])
  let encoding = encode_dictionary(column, max_dictionary_bytes=11) catch {
    _ => abort("encode failed")
  }
  match encoding {
    None => ()
    Some(_) => abort("expected a fallback")
  }
  let encoding = encode_dictionary(column, max_dictionary_bytes=12) catch {
    _ => abort("encode failed")
  }
  match encoding {
    Some(_) => ()
    None => abort("expected a dictionary")
  }
}

///|
test "dictionary rejects boolean columns" {
  let error = capture_error(() => {
    ignore(encode_dictionary(@types.ColBuf::Bools([true, false])))
  })
  match error {
    @types.EncodingError::TypeMismatch(@types.Bool, @types.Dictionary) => ()
    _ => abort("expected TypeMismatch(Bool, Dictionary)")
  }
}

///|
test "dictionary decode reports bad width and out-of-range indices" {
  let error = capture_error(() => {
    ignore(decode_dictionary(b"", b"", @types.Int32, 1, 0))
  })
  match error {
    @types.EncodingError::Truncated(0, 1, 0) => ()
    _ => abort("expected Truncated(0, 1, 0)")
  }

  let error = capture_error(() => {
    ignore(decode_dictionary(b"", b"\x21", @types.Int32, 1, 0))
  })
  match error {
    @types.EncodingError::InvalidBitWidth(33) => ()
    _ => abort("expected InvalidBitWidth(33)")
  }

  // one dictionary entry, an index stream that says 1
  let dictionary = b"\x05\x00\x00\x00"
  let error = capture_error(() => {
    ignore(decode_dictionary(dictionary, b"\x01\x02\x01", @types.Int32, 1, 1))
  })
  match error {
    @types.EncodingError::InvalidIndex(1, 1) => ()
    _ => abort("expected InvalidIndex(1, 1)")
  }
}

///|
test "dictionary: an empty column owns an empty dictionary" {
  // The property tests used to assume a dictionary always has an entry; an
  // empty column is legal and its dictionary is empty, so pin the shape here.
  let encoding = encode_dictionary(@types.ColBuf::Int32s([])) catch {
    error => abort(@types.EncodingError::message(error))
  }
  match encoding {
    None => abort("an empty column must not fall back")
    Some(encoding) => {
      assert_eq(encoding.dictionary_size, 0)
      assert_eq(encoding.dictionary.length(), 0)
      // the index stream still carries its bit-width byte
      assert_eq(encoding.indices.length(), 1)
      let back = decode_dictionary(
        encoding.dictionary,
        encoding.indices,
        @types.Int32,
        0,
        encoding.dictionary_size,
      ) catch {
        error => abort(@types.EncodingError::message(error))
      }
      match back {
        Int32s(values) => assert_eq(values.length(), 0)
        _ => abort("expected an INT32 column")
      }
    }
  }
}

///|
test "planner keeps the first appearance of an extreme value" {
  let values = [-2147483648, 2147483647, 0, -1, -2147483648, 2147483647, 0, -1]
  let (distinct, indices) = plan_int32(values, 1048576).unwrap()
  assert_eq(distinct, [-2147483648, 2147483647, 0, -1])
  assert_eq(indices, [0L, 1L, 2L, 3L, 0L, 1L, 2L, 3L])
}

///|
/// Whether the column keeps its dictionary under `limit` bytes.
fn dictionary_fits(column : @types.ColBuf, limit : Int32) -> Bool {
  let result = encode_dictionary(column, max_dictionary_bytes=limit) catch {
    error => abort(@types.EncodingError::message(error))
  }
  match result {
    Some(_) => true
    None => false
  }
}

///|
test "dictionary budget is exact at the byte for every fixed-width type" {
  // three distinct values: 12 bytes at four-byte width, 24 at eight
  let ints = @types.ColBuf::Int32s([5, 6, 7, 5, 6, 7])
  assert_eq(dictionary_fits(ints, 12), true)
  assert_eq(dictionary_fits(ints, 11), false)
  let longs = @types.ColBuf::Int64s([5L, 6L, 7L, 5L])
  assert_eq(dictionary_fits(longs, 24), true)
  assert_eq(dictionary_fits(longs, 23), false)
  let floats = @types.ColBuf::Floats([Float(1.0), Float(2.0), Float(3.0)])
  assert_eq(dictionary_fits(floats, 12), true)
  assert_eq(dictionary_fits(floats, 11), false)
  let doubles = @types.ColBuf::Doubles([1.0, 2.0, 3.0, 1.0])
  assert_eq(dictionary_fits(doubles, 24), true)
  assert_eq(dictionary_fits(doubles, 23), false)
}

///|
test "dictionary budget rounds a limit that is not a whole number of values" {
  let ints = @types.ColBuf::Int32s([1, 2])
  // room for one four-byte entry only
  assert_eq(dictionary_fits(ints, 7), false)
  assert_eq(dictionary_fits(@types.ColBuf::Int32s([1, 1, 1]), 7), true)
  assert_eq(dictionary_fits(@types.ColBuf::Int64s([1L, 2L]), 15), false)
  assert_eq(dictionary_fits(@types.ColBuf::Int64s([1L, 2L]), 16), true)
}

///|
test "dictionary budget counts the length prefix of byte arrays" {
  // "ab" and "c" cost (4 + 2) + (4 + 1) = 11 bytes
  let strings = @types.ColBuf::ByteArrays([b"ab", b"c", b"ab", b"c"])
  assert_eq(dictionary_fits(strings, 11), true)
  assert_eq(dictionary_fits(strings, 10), false)
  // a duplicate costs nothing, an empty value costs its prefix
  let empties = @types.ColBuf::ByteArrays([b"", b"", b"x"])
  assert_eq(dictionary_fits(empties, 9), true)
  assert_eq(dictionary_fits(empties, 8), false)
}

///|
test "dictionary budget edge cases: empty column and zero limit" {
  assert_eq(dictionary_fits(@types.ColBuf::Int32s([]), 0), true)
  assert_eq(dictionary_fits(@types.ColBuf::ByteArrays([]), 0), true)
  assert_eq(dictionary_fits(@types.ColBuf::Int32s([1]), 0), false)
  assert_eq(dictionary_fits(@types.ColBuf::ByteArrays([b""]), 0), false)
  assert_eq(dictionary_fits(@types.ColBuf::ByteArrays([b""]), 4), true)
}

///|
test "dictionary budget stops a high-cardinality column early" {
  let values : Array[Int32] = Array::makei(20000, fn(i) { i })
  // 20000 distinct values need 80000 bytes; a 1000-byte budget refuses them
  assert_eq(dictionary_fits(@types.ColBuf::Int32s(values), 1000), false)
  assert_eq(dictionary_fits(@types.ColBuf::Int32s(values), 80000), true)
  assert_eq(dictionary_fits(@types.ColBuf::Int32s(values), 79999), false)
}

///|
test "dictionary under budget is unchanged by the early exit" {
  let column = @types.ColBuf::Int32s([3, 1, 3, 2, 1, 3])
  let result = encode_dictionary(column) catch {
    error => abort(@types.EncodingError::message(error))
  }
  match result {
    Some(encoding) => {
      assert_eq(encoding.dictionary_size, 3)
      assert_eq(encoding.bit_width, 2)
      assert_eq(
        encoding.dictionary,
        b"\x03\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00",
      )
    }
    None => abort("expected a dictionary")
  }
}

///|
/// The fused index walk writes looked-up values straight out of the run walker.
/// This pins it against the two-step decode it replaced: unpack the indices into
/// an array, then look each one up.
test "fused dictionary decode matches a two-step decode" {
  let int32_cases : Array[Array[Int32]] = [
    Array::makei(1500, fn(i) { i % 16 }), // several literal runs, partial tail
    Array::makei(64, fn(_) { 7 }), // one repeated run
    Array::makei(9, fn(i) { i % 3 }), // shorter than one literal run
    [42], // a single value
    [], // empty
  ]
  for values in int32_cases {
    let column = @types.ColBuf::Int32s(values)
    let encoding = match encode_dictionary(column) {
      Some(encoding) => encoding
      None => abort("expected a dictionary")
    }
    let count = column.value_count()
    let got = decode_dictionary(
      encoding.dictionary,
      encoding.indices,
      Int32,
      count,
      encoding.dictionary_size,
    ) catch {
      error => abort(@types.EncodingError::message(error))
    }
    let (positions, _) = decode_rle_hybrid(
      encoding.indices[1:],
      encoding.bit_width,
      count,
    ) catch {
      error => abort(@types.EncodingError::message(error))
    }
    let distinct = decode_int32(encoding.dictionary, encoding.dictionary_size) catch {
      error => abort(@types.EncodingError::message(error))
    }
    let want : Array[Int32] = Array::make(positions.length(), 0)
    for index in 0..<positions.length() {
      want[index] = distinct[positions[index].to_int()]
    }
    match got {
      Int32s(have) => assert_eq(have, want)
      _ => abort("expected int32 values")
    }
  }
}

///|
test "fused dictionary decode of strings matches a two-step decode" {
  let pool : Array[Bytes] = [b"alpha", b"beta", b"gamma", b"delta", b"epsilon"]
  let values = Array::makei(700, fn(i) { pool[(i % 5).to_int()] })
  let column = @types.ColBuf::ByteArrays(values)
  let encoding = match encode_dictionary(column) {
    Some(encoding) => encoding
    None => abort("expected a dictionary")
  }
  let count = column.value_count()
  let got = decode_dictionary(
    encoding.dictionary,
    encoding.indices,
    ByteArray,
    count,
    encoding.dictionary_size,
  ) catch {
    error => abort(@types.EncodingError::message(error))
  }
  let (positions, _) = decode_rle_hybrid(
    encoding.indices[1:],
    encoding.bit_width,
    count,
  ) catch {
    error => abort(@types.EncodingError::message(error))
  }
  let distinct = decode_byte_arrays(
    encoding.dictionary,
    encoding.dictionary_size,
  ) catch {
    error => abort(@types.EncodingError::message(error))
  }
  let want : Array[Bytes] = Array::make(positions.length(), b"")
  for index in 0..<positions.length() {
    want[index] = distinct[positions[index].to_int()]
  }
  match got {
    ByteArrays(have) => assert_eq(have, want)
    _ => abort("expected byte arrays")
  }
}

///|
/// An index past the end of the dictionary is still rejected with the same
/// error, and it is rejected from inside the run walk rather than from a second
/// pass over an index array.
test "fused dictionary decode rejects an out-of-range index" {
  // width 4, one literal run of one group: indices 0..7, with 15 in slot 1
  let indices = b"\x04\x03\x00\x0f\x00\x00\x00\x00\x00"
  let dictionary = b"\x0a\x00\x00\x00\x0b\x00\x00\x00"
  let result = decode_dictionary(dictionary, indices, Int32, 8, 2) catch {
    @types.EncodingError::InvalidIndex(index, size) => {
      assert_eq(index, 15)
      assert_eq(size, 2)
      return
    }
    error => abort(@types.EncodingError::message(error))
  }
  ignore(result)
  abort("expected InvalidIndex")
}

///|
test "fused dictionary decode reports a truncated index stream" {
  let dictionary = b"\x0a\x00\x00\x00\x0b\x00\x00\x00"
  // width 4, literal run header claiming one group (4 bytes) with 2 present
  let indices = b"\x04\x03\x00\x0f"
  let result = decode_dictionary(dictionary, indices, Int32, 8, 2) catch {
    @types.EncodingError::Truncated(_, _, _) => return
    error => abort(@types.EncodingError::message(error))
  }
  ignore(result)
  abort("expected Truncated")
}

///|
test "fused dictionary decode reports an incomplete index stream" {
  let dictionary = b"\x0a\x00\x00\x00\x0b\x00\x00\x00"
  // width 1, a repeated run of two zeros: two values, eight asked for
  let indices = b"\x01\x04\x00"
  let result = decode_dictionary(dictionary, indices, Int32, 8, 2) catch {
    @types.EncodingError::Incomplete(got, want) => {
      assert_eq(got, 2)
      assert_eq(want, 8)
      return
    }
    error => abort(@types.EncodingError::message(error))
  }
  ignore(result)
  abort("expected Incomplete")
}

///|
test "fused dictionary decode fills every repeated run for each numeric type" {
  // The fused walk has one copy of the repeated-run branch per physical type,
  // and a dictionary column whose values repeat is the most common shape there
  // is: a branch that writes one value too few would shorten the output, and
  // nothing else in the suite reaches INT64, FLOAT or DOUBLE there.
  let repeated = 20
  let int64s = Array::make(repeated, 9L)
  let floats = Array::make(repeated, Float(1.5))
  let doubles = Array::make(repeated, 2.5)
  let columns : Array[@types.ColBuf] = [
    @types.ColBuf::Int64s(int64s),
    @types.ColBuf::Floats(floats),
    @types.ColBuf::Doubles(doubles),
  ]
  for column in columns {
    let encoding = match encode_dictionary(column) {
      Some(encoding) => encoding
      None => abort("expected a dictionary")
    }
    let count = column.value_count()
    let got = decode_dictionary(
      encoding.dictionary,
      encoding.indices,
      column.physical_type(),
      count,
      encoding.dictionary_size,
    ) catch {
      error => abort(@types.EncodingError::message(error))
    }
    match (column, got) {
      (Int64s(want), Int64s(have)) => assert_eq(have, want)
      (Floats(want), Floats(have)) => assert_eq(have, want)
      (Doubles(want), Doubles(have)) => assert_eq(have, want)
      _ => abort("dictionary decode changed the physical type")
    }
  }
}

///|
test "dictionary decode refuses a count above the ceiling" {
  // A dictionary repeat run declares 2^31 - 1 indices in six bytes, so the count
  // is the only thing that bounds the output: before the ceiling this sized an
  // 8 GiB index output from a two-byte index stream.
  let dictionary : Bytes = b"\x07\x00\x00\x00"
  let indices : Bytes = b"\x01\x04\x05"
  let error = capture_error(() => {
    ignore(decode_dictionary(dictionary, indices, Int32, 2147483647, 1))
  })
  match error {
    @types.EncodingError::TooManyValues(count, limit) => {
      assert_eq(count, 2147483647)
      assert_eq(limit, @types.DEFAULT_MAX_VALUES)
    }
    _ => abort("expected TooManyValues")
  }

  // The boundary is inclusive, and the knob reaches the fused walk.
  let column = @types.ColBuf::Int32s([7, 7, 7])
  let encoding = match encode_dictionary(column) {
    Some(encoding) => encoding
    None => abort("expected a dictionary")
  }
  let got = decode_dictionary(
    encoding.dictionary,
    encoding.indices,
    Int32,
    3,
    encoding.dictionary_size,
    max_values=3,
  ) catch {
    _ => abort("the inclusive boundary must decode")
  }
  match got {
    Int32s(values) => assert_eq(values, [7, 7, 7])
    _ => abort("expected int32 values")
  }
  let error = capture_error(() => {
    ignore(
      decode_dictionary(
        encoding.dictionary,
        encoding.indices,
        Int32,
        3,
        encoding.dictionary_size,
        max_values=2,
      ),
    )
  })
  match error {
    @types.EncodingError::TooManyValues(3, 2) => ()
    _ => abort("expected TooManyValues(3, 2)")
  }
}

///|
test "dictionary decode validates the index stream before the dictionary page" {
  // The order is arguments, index stream, dictionary page, then the lookups.
  // A short index stream is a stream problem, and it is found before the
  // dictionary page is decoded, so it is also found before any lookup writes
  // into an output sized from `count`.
  let error = capture_error(() => {
    ignore(decode_dictionary(b"\x07\x00\x00\x00", b"\x01\x04\x05", Int32, 4, 1))
  })
  match error {
    @types.EncodingError::Incomplete(2, 4) => ()
    _ => abort("expected Incomplete(2, 4)")
  }
  // A malformed dictionary page is still reported when the index stream is
  // sound: the stream check does not mask it.
  let error = capture_error(() => {
    ignore(decode_dictionary(b"", b"\x01\x04\x05", Int32, 2, 1))
  })
  match error {
    @types.EncodingError::Truncated(0, 4, 0) => ()
    _ => abort("expected Truncated(0, 4, 0)")
  }
}
