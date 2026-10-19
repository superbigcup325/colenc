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
  let (distinct, indices) = plan_int32(values)
  assert_eq(distinct, [-2147483648, 2147483647, 0, -1])
  assert_eq(indices, [0L, 1L, 2L, 3L, 0L, 1L, 2L, 3L])
}
