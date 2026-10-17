/// Whitebox tests for the varint primitives: exact bytes for known values,
/// then the rejection paths.

///|
test "uleb128 encodes the reference values" {
  let cases : Array[(UInt64, Bytes)] = [
    (0UL, b"\x00"),
    (1UL, b"\x01"),
    (127UL, b"\x7f"),
    (128UL, b"\x80\x01"),
    (300UL, b"\xac\x02"),
    (624485UL, b"\xe5\x8e\x26"),
    (0xFFFFFFFFFFFFFFFFUL, b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"),
  ]
  for entry in cases {
    let out = Buffer()
    put_uleb128(out, entry.0)
    assert_eq(out.to_bytes(), entry.1)
  }
}

///|
test "zigzag encodes the reference values" {
  let cases : Array[(Int64, Bytes)] = [
    (0L, b"\x00"),
    (-1L, b"\x01"),
    (1L, b"\x02"),
    (-2L, b"\x03"),
    (2L, b"\x04"),
    (-9223372036854775808L, b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"),
    (9223372036854775807L, b"\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01"),
  ]
  for entry in cases {
    let out = Buffer()
    put_zigzag(out, entry.0)
    assert_eq(out.to_bytes(), entry.1)
  }
}

///|
test "zigzag encode and decode are inverses at the extremes" {
  let cases = [
    0L, -1L, 1L, -2L, 2L, 9223372036854775807L, -9223372036854775808L,
  ]
  for value in cases {
    assert_eq(zigzag_decode(zigzag_encode(value)), value)
  }
}

///|
test "read_uleb128 reports values and consumed bytes" {
  let out = Buffer()
  put_uleb128(out, 300UL)
  put_uleb128(out, 1UL)
  put_uleb128(out, 0xFFFFFFFFFFFFFFFFUL)
  let bytes = out.to_bytes()
  let (first, first_len) = read_uleb128(bytes) catch { _ => (0UL, 0) }
  assert_eq(first, 300UL)
  assert_eq(first_len, 2)
  let (second, second_len) = read_uleb128(bytes, offset=first_len) catch {
    _ => (0UL, 0)
  }
  assert_eq(second, 1UL)
  assert_eq(second_len, 1)
  let (third, third_len) = read_uleb128(bytes, offset=first_len + second_len) catch {
    _ => (0UL, 0)
  }
  assert_eq(third, 0xFFFFFFFFFFFFFFFFUL)
  assert_eq(third_len, 10)
  assert_eq(first_len + second_len + third_len, bytes.length())
}

///|
test "read_uleb128 rejects truncated and overlong input" {
  let error = capture_error(() => ignore(read_uleb128(b"\x80")))
  match error {
    Truncated(1, 1, 1) => ()
    _ => abort("expected Truncated(1, 1, 1)")
  }

  // ten continuation bytes: the value would need more than 64 bits
  let error = capture_error(() => {
    ignore(read_uleb128(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00"))
  })
  match error {
    InvalidVarint(0) => ()
    _ => abort("expected InvalidVarint(0)")
  }

  // a tenth byte with bits above bit 63 set
  let error = capture_error(() => {
    ignore(read_uleb128(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f"))
  })
  match error {
    InvalidVarint(0) => ()
    _ => abort("expected InvalidVarint(0)")
  }
}

///|
test "read_uleb128 at an offset out of range" {
  let error = capture_error(() => ignore(read_uleb128(b"\x01", offset=1)))
  match error {
    Truncated(1, 1, 0) => ()
    _ => abort("expected Truncated(1, 1, 0)")
  }
}
