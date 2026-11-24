/// Whitebox tests for the RLE / bit-packed hybrid: hand-computed bytes for the
/// small cases, then the boundary behaviour (a trailing short run, padding,
/// the 63-group literal cap) and the rejection paths.

///|
test "rle repeated runs carry count and value" {
  let out = @buffer.Buffer()
  encode_rle_hybrid([0L], 1, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x02\x00")

  let out = @buffer.Buffer()
  encode_rle_hybrid([1L], 1, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x02\x01")

  let out = @buffer.Buffer()
  encode_rle_hybrid([1L, 1L, 1L, 1L, 1L, 1L, 1L], 1, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x0e\x01")
}

///|
test "rle literal runs pad the last group with zeros" {
  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 1L], 1, out) catch {
    _ => ()
  }
  // one group, values 0,1,0,0,0,0,0,0
  assert_eq(out.to_bytes(), b"\x03\x02")

  let out = @buffer.Buffer()
  encode_rle_hybrid([1L, 2L, 3L], 2, out) catch {
    _ => ()
  }
  // 01,10,11 then zeros: 0x39 in the first byte, the second stays zero
  assert_eq(out.to_bytes(), b"\x03\x39\x00")
}

///|
test "rle eight identical values become a repeated run, seven do not" {
  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L], 1, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x10\x00")

  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 0L, 0L, 0L, 0L, 0L, 0L], 1, out) catch {
    _ => ()
  }
  // seven only: the end flush turns it into a repeat run of seven
  assert_eq(out.to_bytes(), b"\x0e\x00")
}

///|
test "rle trailing value joins the literal group" {
  let out = @buffer.Buffer()
  encode_rle_hybrid([1L, 1L, 1L, 1L, 1L, 1L, 1L, 0L], 1, out) catch {
    _ => ()
  }
  // seven ones followed by a zero were still buffered: one literal group
  assert_eq(out.to_bytes(), b"\x03\x7f")

  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 0L, 0L, 1L, 1L], 1, out) catch {
    _ => ()
  }
  // three zeros and two ones, padded: 0,0,0,1,1,0,0,0
  assert_eq(out.to_bytes(), b"\x03\x18")
}

///|
test "rle at bit width 0 writes no value bytes" {
  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 0L, 0L], 0, out) catch {
    _ => ()
  }
  // three identical values are a repeated run: header 6, no value bytes
  assert_eq(out.to_bytes(), b"\x06")

  let out = @buffer.Buffer()
  encode_rle_hybrid([0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L], 0, out) catch {
    _ => ()
  }
  assert_eq(out.to_bytes(), b"\x10")
}

///|
test "rle decode returns values and consumed bytes" {
  let (values, consumed) = decode_rle_hybrid(b"\x02\x01", 1, 1) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L])
  assert_eq(consumed, 2)

  let (values, consumed) = decode_rle_hybrid(b"\x03\x02", 1, 2) catch {
    _ => ([], 0)
  }
  assert_eq(values, [0L, 1L])
  assert_eq(consumed, 2)

  let (values, consumed) = decode_rle_hybrid(b"\x03\x39\x00", 2, 3) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L, 2L, 3L])
  assert_eq(consumed, 3)
}

///|
test "rle decode reports truncation and incomplete streams" {
  let error = capture_error(() => ignore(decode_rle_hybrid(b"\x7f\x00", 1, 504)))
  match error {
    @types.EncodingError::Truncated(offset, need, available) => {
      assert_eq(offset, 1)
      assert_eq(need, 63)
      assert_eq(available, 1)
    }
    _ => abort("expected Truncated(1, 63, 1)")
  }

  let error = capture_error(() => ignore(decode_rle_hybrid(b"\x04", 16, 2)))
  match error {
    @types.EncodingError::Truncated(1, 2, 0) => ()
    _ => abort("expected Truncated(1, 2, 0)")
  }

  let error = capture_error(() => ignore(decode_rle_hybrid(b"\x03\x02", 1, 9)))
  match error {
    @types.EncodingError::Incomplete(8, 9) => ()
    _ => abort("expected Incomplete(8, 9)")
  }
}

///|
test "bool rle carries the four byte length prefix" {
  let out = @buffer.Buffer()
  encode_bool_rle([true, false, true], out) catch {
    _ => ()
  }
  // stream is one padded literal group: 1,0,1,0,0,0,0,0 = 0x05
  assert_eq(out.to_bytes(), b"\x02\x00\x00\x00\x03\x05")

  let back = decode_bool_rle(b"\x02\x00\x00\x00\x03\x05", 3) catch { _ => [] }
  assert_eq(back, [true, false, true])
}

///|
test "rle rejects invalid widths" {
  let out = @buffer.Buffer()
  let error = capture_error(() => ignore(encode_rle_hybrid([0L], 65, out)))
  match error {
    @types.EncodingError::InvalidBitWidth(65) => ()
    _ => abort("expected InvalidBitWidth(65)")
  }

  let error = capture_error(() => ignore(decode_rle_hybrid(b"", -1, 1)))
  match error {
    @types.EncodingError::InvalidBitWidth(-1) => ()
    _ => abort("expected InvalidBitWidth(-1)")
  }
}

///|
test "rle hybrid decode rejects a run whose byte count wraps" {
  // A literal run of 2^25 groups at bit width 64 needs 2^31 bytes: the product
  // wrapped to a negative byte count, passed the length check and reached the
  // slice. The requirement is derived in 64 bits now.
  let error = capture_error(() => {
    ignore(decode_rle_hybrid(b"\x81\x80\x80\x20", 64, 4))
  })
  match error {
    @types.EncodingError::Truncated(4, 2147483647, 0) => ()
    _ => abort("expected a saturated Truncated")
  }
  // 2^28 groups is 2^31 values, which no page can ask for: `groups * 8` used
  // to wrap as well.
  let error = capture_error(() => {
    ignore(decode_rle_hybrid(b"\x81\x80\x80\x80\x02", 1, 4))
  })
  match error {
    @types.EncodingError::Truncated(5, 2147483647, 0) => ()
    _ => abort("expected a saturated Truncated")
  }
}

///|
test "rle hybrid decode unpacks only the values it was asked for" {
  // At bit width zero a literal run carries no bytes, so its declared length is
  // not bounded by the stream: 2^27 groups is 2^30 values from five bytes. The
  // unpack used to size an array of 2^30 `Int64` values before the caller's
  // count was consulted; it now unpacks the eight values requested.
  let (values, consumed) = decode_rle_hybrid(b"\x81\x80\x80\x80\x01", 0, 8) catch {
    _ => ([], 0)
  }
  assert_eq(values.length(), 8)
  assert_eq(values[7], 0L)
  assert_eq(consumed, 5)
}

///|
test "rle hybrid decode rejects a repeat count that does not fit" {
  // header >> 1 = 2^31 repeats: the truncating conversion used to turn that
  // into a negative run and report a short stream instead of a malformed one.
  let error = capture_error(() => {
    ignore(decode_rle_hybrid(b"\x80\x80\x80\x80\x10", 1, 1))
  })
  match error {
    @types.EncodingError::Corrupt(5) => ()
    _ => abort("expected Corrupt(5)")
  }
}

///|
test "bool rle decode rejects a length field that would wrap" {
  // `4 + length` wraps for a length near Int32 max: the stream used to be cut
  // to an empty slice and reported as incomplete instead of truncated.
  let error = capture_error(() => {
    ignore(decode_bool_rle(b"\xff\xff\xff\x7f\x00\x00", 1))
  })
  match error {
    @types.EncodingError::Truncated(4, 2147483647, 2) => ()
    _ => abort("expected Truncated(4, 2147483647, 2)")
  }
}

///|
test "rle hybrid decode validates its arguments before allocating" {
  // `Array::unsafe_make_uninit(-1)` is a runtime abort, not a typed error, and
  // a page header supplies this count. The allocation used to run before the
  // walk's own argument checks, so a negative count killed the process where
  // every other decoder reported `InvalidCount`.
  let error = capture_error(() => ignore(decode_rle_hybrid(b"", 1, -1)))
  match error {
    @types.EncodingError::InvalidCount(count) => assert_eq(count, -1)
    _ => abort("expected InvalidCount(-1)")
  }
  let error = capture_error(() => ignore(decode_rle_hybrid(b"", 65, 1)))
  match error {
    @types.EncodingError::InvalidBitWidth(width) => assert_eq(width, 65)
    _ => abort("expected InvalidBitWidth(65)")
  }
  let error = capture_error(() => {
    ignore(decode_rle_hybrid(b"", 1, 1, offset=-1))
  })
  match error {
    @types.EncodingError::Truncated(offset, _, _) => assert_eq(offset, -1)
    _ => abort("expected a Truncated that reports the negative offset")
  }
}

///|
test "bool rle decode rejects a negative count" {
  let error = capture_error(() => {
    ignore(decode_bool_rle(b"\x00\x00\x00\x00", -1))
  })
  match error {
    @types.EncodingError::InvalidCount(count) => assert_eq(count, -1)
    _ => abort("expected InvalidCount(-1)")
  }
}

///|
test "rle hybrid decode clamps a repeated run to the requested count" {
  // A run longer than the caller asked for is a legal prefix (and a cheap way
  // for a hostile page to overrun the output). The walk hands out only the
  // values that are left; the whole run's bytes are still consumed.
  let (values, consumed) = decode_rle_hybrid(b"\x10\x01", 1, 1) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L])
  assert_eq(consumed, 2)
  let (values, consumed) = decode_rle_hybrid(b"\x10\x01", 1, 3) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L, 1L, 1L])
  assert_eq(consumed, 2)
}

///|
test "rle hybrid decode refuses a count above the ceiling" {
  // A hybrid stream at bit width zero encodes 2^31 - 1 values in a handful of
  // bytes, so no input check can reject the count: without the ceiling this
  // call allocated 16 GiB and then failed, and on wasm-gc the request trapped
  // the process. The ceiling turns it into a typed error before any allocation.
  let error = capture_error(() => ignore(decode_rle_hybrid(b"", 1, 2147483647)))
  match error {
    @types.EncodingError::TooManyValues(count, limit) => {
      assert_eq(count, 2147483647)
      assert_eq(limit, @types.DEFAULT_MAX_VALUES)
    }
    _ => abort("expected TooManyValues")
  }

  // The ceiling is a policy, so a caller can raise or lower it per call, and
  // the boundary is inclusive.
  let (values, consumed) = decode_rle_hybrid(b"\x10\x01", 1, 3, max_values=3) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L, 1L, 1L])
  assert_eq(consumed, 2)
  let error = capture_error(() => {
    ignore(decode_rle_hybrid(b"\x10\x01", 1, 4, max_values=3))
  })
  match error {
    @types.EncodingError::TooManyValues(count, limit) => {
      assert_eq(count, 4)
      assert_eq(limit, 3)
    }
    _ => abort("expected TooManyValues(4, 3)")
  }
}

///|
test "bool rle decode refuses a count above the ceiling" {
  let error = capture_error(() => {
    ignore(decode_bool_rle(b"\x00\x00\x00\x00", 2147483647))
  })
  match error {
    @types.EncodingError::TooManyValues(count, _) =>
      assert_eq(count, 2147483647)
    _ => abort("expected TooManyValues")
  }
}
