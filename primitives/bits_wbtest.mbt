/// Whitebox tests for the bit primitives: exact bytes at the bit level, not
/// just round trips, because an off-by-one in the bit order still round-trips
/// against the same wrong unpacker.

///|
test "bit_width_for boundaries" {
  assert_eq(bit_width_for(0UL), 0)
  assert_eq(bit_width_for(1UL), 1)
  assert_eq(bit_width_for(2UL), 2)
  assert_eq(bit_width_for(3UL), 2)
  assert_eq(bit_width_for(4UL), 3)
  assert_eq(bit_width_for(7UL), 3)
  assert_eq(bit_width_for(255UL), 8)
  assert_eq(bit_width_for(256UL), 9)
  assert_eq(bit_width_for(0xFFFFFFFFFFFFFFFFUL), 64)
}

///|
test "bit_pack fills a single byte LSB first" {
  let out = Buffer()
  bit_pack([1L, 2L, 3L][:], 2, out) catch {
    _ => ()
  }
  // 01, 10, 11 in bits 0..5: 0b00111001
  assert_eq(out.to_bytes(), b"\x39")
}

///|
test "bit_pack crosses byte boundaries without padding" {
  let out = Buffer()
  // 101 then 010: 0b00010101
  bit_pack([5L, 2L][:], 3, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x15")

  let out = Buffer()
  // 0xABC then 0x123 at 12 bits: low byte, then 0xA | 0x3 << 4, then 0x12
  bit_pack([0xABCL, 0x123L][:], 12, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\xbc\x3a\x12")
}

///|
test "bit_pack at width 1 and 8" {
  let out = Buffer()
  bit_pack([1L, 0L, 1L, 1L, 0L, 0L, 1L, 0L, 1L][:], 1, out) catch {
    _ => ()
  }
  // 1,0,1,1,0,0,1,0 in bits 0..7 then a final 1 in bit 8
  assert_eq(out.to_bytes(), b"\x4d\x01")

  let out = Buffer()
  bit_pack([0x11L, 0x22L][:], 8, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x11\x22")
}

///|
test "bit_pack at width 0 writes nothing" {
  let out = Buffer()
  bit_pack([7L, -1L][:], 0, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"")
}

///|
test "bit_pack masks values to the width" {
  let out = Buffer()
  // 0xFF at width 4 is 0xF; a caller that mis-sized the width gets truncation
  bit_pack([0xFFL][:], 4, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x0f")
}

///|
test "bit_unpack reads the same bits" {
  let values = bit_unpack(b"\x39", 2, 3) catch { _ => [] }
  assert_eq(values, [1L, 2L, 3L])
  let values = bit_unpack(b"\xbc\x3a\x12", 12, 2) catch { _ => [] }
  assert_eq(values, [0xABCL, 0x123L])
}

///|
test "bit_unpack at width 0 and count 0" {
  let values = bit_unpack(b"", 0, 3) catch { _ => [] }
  assert_eq(values, [0L, 0L, 0L])
  let values = bit_unpack(b"", 7, 0) catch { _ => [] }
  assert_eq(values, [])
}

///|
test "bit_unpack ignores trailing bytes" {
  let values = bit_unpack(b"\x39\xff", 2, 3) catch { _ => [] }
  assert_eq(values, [1L, 2L, 3L])
}

///|
test "bit_unpack at width 64 preserves every bit" {
  let input = [-1L, 0L, 0x0123456789ABCDEFL, -9223372036854775808L]
  let out = Buffer()
  bit_pack(input[:], 64, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes().length(), 32)
  let back = bit_unpack(out.to_bytes(), 64, input.length()) catch { _ => [] }
  assert_eq(back, input)
}

///|
test "bit_unpack reports truncation and bad arguments" {
  let error = capture_error(() => ignore(bit_unpack(b"\xbc", 12, 2)))
  match error {
    Truncated(offset, need, available) => {
      assert_eq(offset, 0)
      assert_eq(need, 3)
      assert_eq(available, 1)
    }
    _ => abort("expected Truncated")
  }

  let error = capture_error(() => ignore(bit_unpack(b"", 65, 1)))
  match error {
    InvalidBitWidth(width) => assert_eq(width, 65)
    _ => abort("expected InvalidBitWidth")
  }

  let error = capture_error(() => ignore(bit_unpack(b"", 4, -1)))
  match error {
    InvalidCount(count) => assert_eq(count, -1)
    _ => abort("expected InvalidCount")
  }
}
