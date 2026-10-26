/// Whitebox tests for PLAIN: exact bytes first, then round trips and the
/// rejection paths.

///|
fn capture_error(
  run : () -> Unit raise @types.EncodingError,
) -> @types.EncodingError {
  let mut captured : @types.EncodingError? = None
  run() catch {
    error => captured = Some(error)
  }
  match captured {
    Some(error) => error
    None => abort("expected the call to raise")
  }
}

///|
test "plain int32 is little endian" {
  let out = @buffer.Buffer()
  encode_int32([1, -1, 256], out)
  assert_eq(out.to_bytes(), b"\x01\x00\x00\x00\xff\xff\xff\xff\x00\x01\x00\x00")
}

///|
test "plain int64 is little endian" {
  let out = @buffer.Buffer()
  encode_int64([1L, -1L], out)
  assert_eq(
    out.to_bytes(),
    b"\x01\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff",
  )
}

///|
test "plain byte arrays carry a u32le length" {
  let out = @buffer.Buffer()
  encode_byte_arrays([b"ab", b""], out)
  assert_eq(out.to_bytes(), b"\x02\x00\x00\x00ab\x00\x00\x00\x00")
}

///|
test "plain booleans are bit packed LSB first" {
  let out = @buffer.Buffer()
  encode_bool([true, false, true, true, false, false, false, true, true], out)
  // 1,0,1,1,0,0,0,1 then a final 1 in the low bit of the next byte
  assert_eq(out.to_bytes(), b"\x8d\x01")
}

///|
test "plain round trips every physical type" {
  let ints : Array[Int32] = [0, 1, -1, 2147483647, -2147483647 - 1]
  let out = @buffer.Buffer()
  encode_int32(ints, out)
  let back = decode_int32(out.to_bytes(), ints.length()) catch { _ => [] }
  assert_eq(back, ints)

  let longs : Array[Int64] = [
    0L,
    1L,
    -1L,
    9223372036854775807L,
    -9223372036854775807L - 1L,
  ]
  let out = @buffer.Buffer()
  encode_int64(longs, out)
  let back = decode_int64(out.to_bytes(), longs.length()) catch { _ => [] }
  assert_eq(back, longs)

  let floats : Array[Float] = [
    Float(0.0),
    Float(-0.0),
    Float(1.5),
    Float(-2.25),
  ]
  let out = @buffer.Buffer()
  encode_float(floats, out)
  let back = decode_float(out.to_bytes(), floats.length()) catch { _ => [] }
  assert_eq(back, floats)

  let doubles : Array[Double] = [0.0, -0.0, 1.5, -2.25]
  let out = @buffer.Buffer()
  encode_double(doubles, out)
  let back = decode_double(out.to_bytes(), doubles.length()) catch { _ => [] }
  assert_eq(back, doubles)

  let strings : Array[Bytes] = [b"", b"abc", b"\x00\xff"]
  let out = @buffer.Buffer()
  encode_byte_arrays(strings, out)
  let back = decode_byte_arrays(out.to_bytes(), strings.length()) catch {
    _ => []
  }
  assert_eq(back, strings)

  let flags : Array[Bool] = [true, false, true, true, false, false, false, true]
  let out = @buffer.Buffer()
  encode_bool(flags, out)
  let back = decode_bool(out.to_bytes(), flags.length()) catch { _ => [] }
  assert_eq(back, flags)
}

///|
test "plain empty columns encode to nothing and decode to nothing" {
  let out = @buffer.Buffer()
  encode_int32([], out)
  assert_eq(out.to_bytes(), b"")
  assert_eq(decode_int32(out.to_bytes(), 0) catch { _ => [] }, [])

  let out = @buffer.Buffer()
  encode_bool([], out)
  assert_eq(out.to_bytes(), b"")
  assert_eq(decode_bool(out.to_bytes(), 0) catch { _ => [] }, [])
}

///|
test "plain decode reports the first short read" {
  let error = capture_error(() => ignore(decode_int32(b"\x01\x00", 1)))
  match error {
    @types.EncodingError::Truncated(offset, need, available) => {
      assert_eq(offset, 0)
      assert_eq(need, 4)
      assert_eq(available, 2)
    }
    _ => abort("expected Truncated")
  }

  let error = capture_error(() => ignore(decode_float(b"", 2)))
  match error {
    @types.EncodingError::Truncated(0, 8, 0) => ()
    _ => abort("expected Truncated(0, 8, 0)")
  }
}

///|
test "plain byte array decode points at the bad length or body" {
  // length says 5, no bytes follow
  let error = capture_error(() => {
    ignore(decode_byte_arrays(b"\x05\x00\x00\x00", 1))
  })
  match error {
    @types.EncodingError::Truncated(offset, need, available) => {
      assert_eq(offset, 4)
      assert_eq(need, 5)
      assert_eq(available, 0)
    }
    _ => abort("expected Truncated(4, 5, 0)")
  }

  // a second value with a truncated length field
  let error = capture_error(() => {
    ignore(decode_byte_arrays(b"\x01\x00\x00\x00a\x01\x00", 2))
  })
  match error {
    @types.EncodingError::Truncated(offset, need, available) => {
      assert_eq(offset, 5)
      assert_eq(need, 4)
      assert_eq(available, 2)
    }
    _ => abort("expected Truncated(5, 4, 2)")
  }
}

///|
test "plain wide decode keeps extremes, specials and trailing bytes" {
  let longs : Array[Int64] = [
    0L,
    1L,
    -1L,
    0x0102030405060708L,
    9223372036854775807L,
    -9223372036854775807L - 1L,
  ]
  let out = @buffer.Buffer()
  encode_int64(longs, out)
  out.write_bytes(b"\xaa\xbb\xcc")
  let bytes = out.to_bytes()
  assert_eq(decode_int64(bytes, longs.length()) catch { _ => [] }, longs)
  assert_eq(decode_int64(bytes, 0) catch { _ => [1L] }, [])
  assert_eq(decode_int64(bytes, 1) catch { _ => [] }, [0L])

  let doubles : Array[Double] = [
    0.0,
    -0.0,
    1.5,
    0x7fefffffffffffffUL.reinterpret_as_double(),
    0x0000000000000001UL.reinterpret_as_double(),
    0x7ff0000000000000UL.reinterpret_as_double(),
    0xfff0000000000000UL.reinterpret_as_double(),
  ]
  let out = @buffer.Buffer()
  encode_double(doubles, out)
  let back = decode_double(out.to_bytes(), doubles.length()) catch { _ => [] }
  assert_eq(back.length(), doubles.length())
  for index in 0..<doubles.length() {
    assert_eq(
      back[index].reinterpret_as_uint64(),
      doubles[index].reinterpret_as_uint64(),
    )
  }
  // A NaN stays a NaN. The payload is not asserted: the js backend
  // canonicalizes NaN, so only the class is common to all three targets.
  let nan_bytes = b"\x01\x00\x00\x00\x00\x00\xf8\x7f"
  let nan = decode_double(nan_bytes, 1) catch { _ => [] }
  assert_eq(nan.length(), 1)
  assert_eq(nan[0] != nan[0], true)
}

///|
test "plain wide decode reads from an unaligned view" {
  let out = @buffer.Buffer()
  out.write_byte(b'\x7f')
  encode_int64([0x1122334455667788L, -2L], out)
  let view = out.to_bytes()[1:]
  assert_eq(decode_int64(view, 2) catch { _ => [] }, [0x1122334455667788L, -2L])
  let short = out.to_bytes()[1:16]
  let error = capture_error(() => ignore(decode_int64(short, 2)))
  match error {
    @types.EncodingError::Truncated(0, 16, 15) => ()
    _ => abort("expected Truncated(0, 16, 15)")
  }
}

///|
test "plain wide decode rejects counts whose byte size overflows" {
  // 2^29 values of eight bytes wrap to zero in 32-bit arithmetic
  let error = capture_error(() => ignore(decode_int64(b"", 536870912)))
  match error {
    @types.EncodingError::Truncated(0, 2147483647, 0) => ()
    _ => abort("expected a saturated Truncated")
  }
  let error = capture_error(() => ignore(decode_double(b"\x00", 2147483647)))
  match error {
    @types.EncodingError::Truncated(0, 2147483647, 1) => ()
    _ => abort("expected a saturated Truncated")
  }
  // the largest count that still fits keeps its exact requirement
  let error = capture_error(() => ignore(decode_int64(b"", 268435455)))
  match error {
    @types.EncodingError::Truncated(0, 2147483640, 0) => ()
    _ => abort("expected Truncated(0, 2147483640, 0)")
  }
}

///|
test "plain decode rejects negative counts" {
  let error = capture_error(() => ignore(decode_int64(b"", -1)))
  match error {
    @types.EncodingError::InvalidCount(-1) => ()
    _ => abort("expected InvalidCount(-1)")
  }
}
