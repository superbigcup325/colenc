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
test "delta decode returns a prefix when asked for fewer values" {
  // The output is sized from the caller's count rather than from the header's,
  // so a partial decode must stop inside the block walk: it returns the first
  // `count` values and never writes past them.
  let ints = Array::makei(300, fn(index) { index * 3 - 50 })
  let out = @buffer.Buffer()
  encode_delta_int32(ints[:], out) catch {
    _ => ()
  }
  let (values, _) = decode_delta_int32(out.to_bytes(), 137) catch {
    _ => ([], 0)
  }
  assert_eq(values, Array::makei(137, fn(index) { index * 3 - 50 }))

  let longs = Array::makei(300, fn(index) { index.to_int64() * 99991L })
  let out = @buffer.Buffer()
  encode_delta_int64(longs[:], out) catch {
    _ => ()
  }
  let (values, _) = decode_delta_int64(out.to_bytes(), 137) catch {
    _ => ([], 0)
  }
  assert_eq(values, Array::makei(137, fn(index) { index.to_int64() * 99991L }))
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

///|
test "delta decode rejects a block the input cannot hold" {
  // miniblock_size 2^30 at bit width zero: the unpack used to size 2^30 values
  // from the header before the value count was consulted. Only the one value
  // the caller asked for is unpacked now.
  let (values, consumed) = decode_delta_int64(
    b"\x80\x80\x80\x80\x04\x01\x02\x00\x00\x00", 2,
  ) catch {
    _ => ([], 0)
  }
  assert_eq(values, [0L, 0L])
  assert_eq(consumed, 10)

  // `miniblock_size * width` wraps in Int32 for the same header at width 64,
  // which used to reach the unpack with an empty slice and read past it.
  let error = capture_error(() => {
    ignore(decode_delta_int64(b"\x80\x80\x80\x80\x02\x01\x02\x00\x00\x40", 2))
  })
  match error {
    @types.EncodingError::Truncated(10, 2147483647, 0) => ()
    _ => abort("expected a saturated Truncated")
  }

  // `pos + miniblocks` wraps for 2^31 - 2 miniblocks, and the width table was
  // sized from it before the comparison could reject it.
  let error = capture_error(() => {
    ignore(
      decode_delta_int64(
        b"\xfe\xff\xff\xff\x07\xfe\xff\xff\xff\x07\x02\x00\x00", 2,
      ),
    )
  })
  match error {
    @types.EncodingError::Truncated(13, 2147483646, 0) => ()
    _ => abort("expected Truncated(13, 2147483646, 0)")
  }
}

///|
test "delta byte array decoders reject lengths that would wrap" {
  // A decoded length of Int32 max made `pos + length` negative, so the value
  // came back empty and the consumed count negative instead of raising.
  let out = @buffer.Buffer()
  encode_delta_int32([2147483647], out) catch {
    _ => ()
  }
  let error = capture_error(() => {
    ignore(decode_delta_length_byte_array(out.to_bytes(), 1))
  })
  match error {
    @types.EncodingError::Truncated(9, 2147483647, 0) => ()
    _ => abort("expected Truncated(9, 2147483647, 0)")
  }

  let out = @buffer.Buffer()
  encode_delta_int32([0], out) catch {
    _ => ()
  }
  encode_delta_int32([2147483647], out) catch {
    _ => ()
  }
  let error = capture_error(() => {
    ignore(decode_delta_byte_array(out.to_bytes(), 1))
  })
  match error {
    @types.EncodingError::Truncated(14, 2147483647, 0) => ()
    _ => abort("expected Truncated(14, 2147483647, 0)")
  }
}

///|
test "delta header rejects a field wider than Int32 instead of truncating" {
  // count declares 2^32 + 3 values; `to_int` used to truncate it to 3, so the
  // decoder answered `Incomplete have=3 want=5` for a header it should refuse.
  let error = capture_error(() => {
    ignore(decode_delta_int64(b"\x80\x01\x04\x83\x80\x80\x80\x10\x00", 5))
  })
  match error {
    @types.EncodingError::Corrupt(0) => ()
    _ => abort("expected Corrupt(0)")
  }
  // block_size declares 2^32 + 128, which used to read back as a valid 128.
  let error = capture_error(() => {
    ignore(decode_delta_int64(b"\x80\x81\x80\x80\x10\x04\x01\x00", 1))
  })
  match error {
    @types.EncodingError::Corrupt(0) => ()
    _ => abort("expected Corrupt(0)")
  }
}

///|
test "delta int32 decode rejects a block the input cannot hold" {
  // The int64 decoder has this test; the int32 copy is a separate function with
  // its own copy of both guards, and neither was covered: reverting either one
  // to the old `Int32` arithmetic left the suite green.
  let (values, consumed) = decode_delta_int32(
    b"\x80\x80\x80\x80\x04\x01\x02\x00\x00\x00", 2,
  ) catch {
    _ => ([], 0)
  }
  assert_eq(values, [0, 0])
  assert_eq(consumed, 10)

  // `miniblock_size * width` at width 32: 2^29 * 32 / 8 is 2^31 bytes, which
  // wrapped in Int32 and reached the unpack with an empty slice.
  let error = capture_error(() => {
    ignore(decode_delta_int32(b"\x80\x80\x80\x80\x02\x01\x02\x00\x00\x20", 2))
  })
  match error {
    @types.EncodingError::Truncated(10, 2147483647, 0) => ()
    _ => abort("expected a saturated Truncated")
  }

  // `pos + miniblocks` wraps for 2^31 - 2 miniblocks, and the width table was
  // sized from it before the comparison could reject it.
  let error = capture_error(() => {
    ignore(
      decode_delta_int32(
        b"\xfe\xff\xff\xff\x07\xfe\xff\xff\xff\x07\x02\x00\x00", 2,
      ),
    )
  })
  match error {
    @types.EncodingError::Truncated(13, 2147483646, 0) => ()
    _ => abort("expected Truncated(13, 2147483646, 0)")
  }
}
