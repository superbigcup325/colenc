/// Whitebox tests for the delta family: reference bytes for small sequences,
/// block and miniblock boundaries, extremes, and the rejection paths.

///|
test "delta int32 matches the reference bytes" {
  let out = @buffer.Buffer()
  encode_delta_int32([1, 2, 3], out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x80\x01\x04\x03\x02\x02\x00\x00\x00\x00")

  let out = @buffer.Buffer()
  encode_delta_int32([7], out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x80\x01\x04\x01\x0e")

  let out = @buffer.Buffer()
  encode_delta_int32([-1, 0, -2, 5], out) catch {
    _ => ()
  }
  assert_eq(
    out.to_bytes(),
    b"\x80\x01\x04\x04\x01\x03\x04\x00\x00\x00\x03\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
test "delta int64 matches the reference bytes" {
  let out = @buffer.Buffer()
  encode_delta_int64([7L, 10L, 13L], out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x80\x02\x04\x03\x0e\x06\x00\x00\x00\x00")
}

///|
test "delta round trips across block boundaries and extremes" {
  let ints = Array::makei(1000, fn(index) { index * 7 - 300 })
  let out = @buffer.Buffer()
  encode_delta_int32(ints[:], out) catch {
    _ => ()
  }
  let back = decode_delta_int32(out.to_bytes(), ints.length()) catch {
    _ => ([], 0)
  }
  assert_eq(back.0, ints)
  assert_eq(back.1, out.length())

  let longs = Array::makei(600, fn(index) {
    if index % 97 == 0 {
      -9223372036854775807L - 1L + index.to_int64()
    } else {
      index.to_int64() * 123456789L - 7L
    }
  })
  let out = @buffer.Buffer()
  encode_delta_int64(longs[:], out) catch {
    _ => ()
  }
  let back = decode_delta_int64(out.to_bytes(), longs.length()) catch {
    _ => ([], 0)
  }
  assert_eq(back.0, longs)
  assert_eq(back.1, out.length())
}

///|
test "delta handles empty and single-value columns" {
  let out = @buffer.Buffer()
  encode_delta_int64([], out) catch {
    _ => ()
  }
  let back = decode_delta_int64(out.to_bytes(), 0) catch { _ => ([], 0) }
  assert_eq(back.0, [])
  assert_eq(back.1, out.length())

  let out = @buffer.Buffer()
  encode_delta_int32([-42], out) catch {
    _ => ()
  }
  let back = decode_delta_int32(out.to_bytes(), 1) catch { _ => ([], 0) }
  assert_eq(back.0, [-42])
}

///|
test "delta length byte array round trips" {
  let values : Array[Bytes] = [b"", b"a", b"beat", b"bead", b"zzzz"]
  let out = @buffer.Buffer()
  encode_delta_length_byte_array(values, out) catch {
    _ => ()
  }
  let back = decode_delta_length_byte_array(out.to_bytes(), values.length()) catch {
    _ => ([], 0)
  }
  assert_eq(back.0, values)
  assert_eq(back.1, out.length())
}

///|
test "delta byte array shares prefixes and round trips" {
  let values : Array[Bytes] = [
    b"prefix-one", b"prefix-two", b"prefix-three", b"", b"prefix-one",
  ]
  let out = @buffer.Buffer()
  encode_delta_byte_array(values, out) catch {
    _ => ()
  }
  let back = decode_delta_byte_array(out.to_bytes(), values.length()) catch {
    _ => ([], 0)
  }
  assert_eq(back.0, values)
  assert_eq(back.1, out.length())
}

///|
test "delta decode reports truncation and count mismatches" {
  let error = capture_error(() => ignore(decode_delta_int32(b"", 1)))
  match error {
    @types.EncodingError::Truncated(0, 1, 0) => ()
    _ => abort("expected Truncated(0, 1, 0)")
  }

  let out = @buffer.Buffer()
  encode_delta_int32([1, 2, 3], out) catch {
    _ => ()
  }
  let bytes = out.to_bytes()
  let error = capture_error(() => ignore(decode_delta_int32(bytes, 4)))
  match error {
    @types.EncodingError::Incomplete(3, 4) => ()
    _ => abort("expected Incomplete(3, 4)")
  }
}
