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
test "delta byte array consumes both headers of an empty page" {
  let out = @buffer.Buffer()
  out.write_byte(b'\xff')
  encode_delta_byte_array([], out)
  let next_page = out.length()
  encode_delta_byte_array([b"next"], out)
  let bytes = out.to_bytes()
  let (empty, consumed) = decode_delta_byte_array(bytes, 0, offset=1)
  assert_true(empty.is_empty())
  assert_eq(1 + consumed, next_page)
  let (next, _) = decode_delta_byte_array(bytes, 1, offset=1 + consumed)
  assert_eq(next, [b"next"])
}

///|
test "delta byte array consumes both headers for a zero-length single-value prefix" {
  let out = @buffer.Buffer()
  out.write_byte(b'\xff')
  encode_delta_byte_array([b"abc"], out)
  let bytes = out.to_bytes()
  let (prefix, consumed) = decode_delta_byte_array(bytes, 0, offset=1)
  assert_true(prefix.is_empty())
  assert_eq(consumed, bytes.length() - 1 - b"abc".length())
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

///|
test "delta decode refuses a count above the ceiling" {
  // The header declares 2^31 - 1 values and the body is nine bytes, which is a
  // legal stream: a block whose deltas are all zero and whose miniblocks carry
  // width zero produces `block_size` values from no data at all. Before the
  // ceiling this call allocated 16 GiB.
  let header = b"\x80\x01\x04\xff\xff\xff\xff\x07\x00"
  let error = capture_error(() => ignore(decode_delta_int64(header, 2147483647)))
  match error {
    @types.EncodingError::TooManyValues(count, limit) => {
      assert_eq(count, 2147483647)
      assert_eq(limit, @types.DEFAULT_MAX_VALUES)
    }
    _ => abort("expected TooManyValues")
  }
  let error = capture_error(() => ignore(decode_delta_int32(header, 2147483647)))
  match error {
    @types.EncodingError::TooManyValues(count, _) =>
      assert_eq(count, 2147483647)
    _ => abort("expected TooManyValues")
  }

  // The boundary is inclusive, and the knob reaches the two byte-array
  // families that decode a length stream through this decoder.
  let out = @buffer.Buffer()
  encode_delta_int64([1L, 2L, 3L], out)
  let (values, _) = decode_delta_int64(out.to_bytes(), 3, max_values=3) catch {
    _ => ([], 0)
  }
  assert_eq(values, [1L, 2L, 3L])
  let error = capture_error(() => {
    ignore(decode_delta_int64(out.to_bytes(), 3, max_values=2))
  })
  match error {
    @types.EncodingError::TooManyValues(count, limit) => {
      assert_eq(count, 3)
      assert_eq(limit, 2)
    }
    _ => abort("expected TooManyValues(3, 2)")
  }
  let strings : Array[Bytes] = [b"a", b"b", b"c"]
  let strings_out = @buffer.Buffer()
  encode_delta_length_byte_array(strings, strings_out)
  let error = capture_error(() => {
    ignore(
      decode_delta_length_byte_array(strings_out.to_bytes(), 3, max_values=2),
    )
  })
  match error {
    @types.EncodingError::TooManyValues(3, 2) => ()
    _ => abort("expected TooManyValues(3, 2) through the length stream")
  }
}

///|
/// A column long enough that its delta streams span several 128-value blocks,
/// with values that differ so a wrong byte offset cannot pass unnoticed.
fn delta_prefix_column() -> Array[Bytes] {
  Array::makei(1000, fn(index) {
    let fill = (index % 251 + 1).to_byte()
    let length = index % 9 + 1
    Bytes::from_array(FixedArray::make(length, fill).exact_view())
  })
}

///|
test "delta length byte array: a prefix decode starts at the right raw offset" {
  // The two streams are laid out end to end, and the raw bytes start where the
  // *whole* length stream ends. Decoding `count` lengths stops at the end of the
  // block that produced them, so for a count below the header's the raw stream
  // used to be read from inside the length stream: `count = 2` on this column
  // answered `b"\x0f"`, `b"\x04\x04"` with no error at all.
  let values = delta_prefix_column()
  let out = @buffer.Buffer()
  encode_delta_length_byte_array(values, out) catch {
    _ => abort("encode")
  }
  let bytes = out.to_bytes()
  let (all, consumed) = decode_delta_length_byte_array(bytes, 1000) catch {
    _ => abort("full decode")
  }
  assert_eq(all, values)
  assert_eq(consumed, bytes.length())
  for count in [0, 1, 2, 50, 128, 500, 999] {
    let (prefix, _) = decode_delta_length_byte_array(bytes, count) catch {
      error => abort("prefix \{count}: \{@types.EncodingError::message(error)}")
    }
    assert_eq(prefix.length(), count)
    for index in 0..<count {
      assert_eq(prefix[index], values[index])
    }
  }
}

///|
test "delta byte array: a prefix decode starts at both right stream offsets" {
  // Same shape, twice: the prefix-length stream and then the suffix-length
  // stream both have to be measured at the header's count, not at the caller's.
  let values = delta_prefix_column()
  let out = @buffer.Buffer()
  encode_delta_byte_array(values, out) catch {
    _ => abort("encode")
  }
  let bytes = out.to_bytes()
  let (all, consumed) = decode_delta_byte_array(bytes, 1000) catch {
    _ => abort("full decode")
  }
  assert_eq(all, values)
  assert_eq(consumed, bytes.length())
  for count in [0, 1, 2, 50, 128, 500, 999] {
    let (prefix, _) = decode_delta_byte_array(bytes, count) catch {
      error => abort("prefix \{count}: \{@types.EncodingError::message(error)}")
    }
    assert_eq(prefix.length(), count)
    for index in 0..<count {
      assert_eq(prefix[index], values[index])
    }
  }
}

///|
test "delta decode refuses a short stream before allocating" {
  // The header declares 2^31 - 1 values and the count is at the ceiling, so the
  // ceiling check passes; the body ends at byte 9. The output used to be
  // allocated (128 MiB of `Int64`) before the first block was read.
  let error = capture_error(() => {
    ignore(
      decode_delta_int64(
        b"\x80\x01\x04\xff\xff\xff\xff\x07\x00",
        @types.DEFAULT_MAX_VALUES,
      ),
    )
  })
  match error {
    @types.EncodingError::Truncated(9, 1, 0) => ()
    _ => abort("expected Truncated(9, 1, 0)")
  }
  let error = capture_error(() => {
    ignore(
      decode_delta_int32(
        b"\x80\x01\x04\xff\xff\xff\xff\x07\x00",
        @types.DEFAULT_MAX_VALUES,
      ),
    )
  })
  match error {
    @types.EncodingError::Truncated(9, 1, 0) => ()
    _ => abort("expected Truncated(9, 1, 0)")
  }
}

///|
test "delta prefix decode returns the same prefix as the full decode" {
  // Same guard as the hybrid: the walk stops inside the block that produces the
  // last requested value and still consumes the rest of that block's width
  // bytes, so a prefix decode must return exactly the first `n` values.
  let values = Array::makei(300, fn(i) { i.to_int64() * 7L - 100L })
  let out = @buffer.Buffer()
  encode_delta_int64(values[:], out) catch {
    _ => ()
  }
  let bytes = out.to_bytes()
  for n in [1, 2, 3, 127, 128, 129, 255, 256, 257, 299, 300] {
    let (got, _) = decode_delta_int64(bytes, n) catch { _ => ([], 0) }
    assert_eq(got.length(), n)
    for index in 0..<n {
      assert_eq(got[index], values[index])
    }
  }
}

///|
test "delta validation pass round trips just above the threshold" {
  // Same guard as the hybrid: the pass only runs above `PREVALIDATE_ABOVE`.
  let count = @types.PREVALIDATE_ABOVE + 1
  let values = Array::makei(count, fn(i) { i.to_int64() })
  let out = @buffer.Buffer()
  encode_delta_int64(values[:], out) catch {
    _ => ()
  }
  let bytes = out.to_bytes()
  let (got, _) = decode_delta_int64(bytes, count) catch { _ => ([], 0) }
  assert_eq(got.length(), count)
  assert_eq(got[count - 1], values[count - 1])
  // Half the stream: the pass sees the end before the output is sized.
  let error = capture_error(() => {
    ignore(decode_delta_int64(bytes[:bytes.length() / 2], count))
  })
  match error {
    @types.EncodingError::Truncated(_, _, _) => ()
    _ => abort("expected Truncated")
  }
}

///|
test "delta miniblock payload must be a whole number of bytes" {
  // The probe charges `floor(miniblock_size * width / 8)` bytes for a miniblock
  // and the decode loop hands that same slice to `bit_unpack`, which needs
  // `ceil(take * width / 8)`. A short `take` hides the difference: with
  // miniblock_size 12, width 1 and a count of 3 the take is 2, and its one byte
  // is exactly what the probe charged, so both readers decoded it. The drift
  // needs `take == miniblock_size`, which is a count of 13 here — the decode
  // then asked for two bytes of a one-byte miniblock, and by that point
  // `Array::unsafe_make_uninit(count)` had already run. Reaching it through the
  // probe needs a count above `PREVALIDATE_ABOVE` as well; the probe is called
  // directly below, so the shape is the same either way.
  let out = @buffer.Buffer()
  @primitives.put_uleb128(out, 12UL)
  @primitives.put_uleb128(out, 1UL)
  @primitives.put_uleb128(out, 13UL)
  @primitives.put_zigzag(out, 0L)
  @primitives.put_zigzag(out, 0L)
  out.write_byte(b'\x01')
  out.write_byte(b'\x00')
  let bytes = out.to_bytes()
  // Both decoders refuse it, with the same error: the rule is shared, and a
  // regression in either copy has to fail here.
  let wide = capture_error(() => ignore(decode_delta_int64(bytes, 13)))
  match wide {
    @types.EncodingError::Corrupt(6) => ()
    other =>
      abort(
        "int64: expected Corrupt(6), got \{@types.EncodingError::message(other)}",
      )
  }
  let narrow = capture_error(() => ignore(decode_delta_int32(bytes, 13)))
  match narrow {
    @types.EncodingError::Corrupt(6) => ()
    other =>
      abort(
        "int32: expected Corrupt(6), got \{@types.EncodingError::message(other)}",
      )
  }
  let (header, header_len) = read_delta_header(bytes, 0) catch {
    e => abort("header: \{@types.EncodingError::message(e)}")
  }
  let probed = capture_error(() => {
    ignore(delta_probe(bytes, 13, header_len, header, 64))
  })
  match probed {
    @types.EncodingError::Corrupt(6) => ()
    other =>
      abort(
        "probe: expected Corrupt(6), got \{@types.EncodingError::message(other)}",
      )
  }
  // The header shape is refused whatever the count: the format defines a
  // miniblock's payload as `miniblock_size * width / 8` bytes, which is only a
  // whole number when the size is a multiple of eight, so a shorter take is not
  // a licence to read the stream — that is the narrowing this rule makes, and
  // the Parquet spec requires a miniblock size that is a multiple of 32.
  let short_take = capture_error(() => ignore(decode_delta_int64(bytes, 3)))
  match short_take {
    @types.EncodingError::Corrupt(6) => ()
    other =>
      abort(
        "short take: expected Corrupt(6), got \{@types.EncodingError::message(other)}",
      )
  }
  // The shape a writer produces (block 128 or 256, four miniblocks, so a
  // miniblock of 32 or 64) satisfies the invariant and still decodes.
  let values : Array[Int64] = [1L, 2L, 3L, 4L, 5L]
  let wave = @buffer.Buffer()
  encode_delta_int64(values[:], wave) catch {
    _ => ()
  }
  let (back, _) = decode_delta_int64(wave.to_bytes(), 5) catch {
    e => abort(@types.EncodingError::message(e))
  }
  assert_eq(back, values)
}

///|
test "delta probe ends exactly where the encoded stream ends" {
  // The two-stream byte-array decoders locate their second stream with this
  // walk when the caller asks for fewer values than the header declares, so the
  // returned position is a correctness dependency, not just a memory guard: a
  // walk that stops one block early reads the next stream from the wrong byte.
  let longs = Array::makei(300, fn(index) { index.to_int64() * 7L })
  let out = @buffer.Buffer()
  encode_delta_int64(longs[:], out) catch {
    e => abort(@types.EncodingError::message(e))
  }
  let bytes = out.to_bytes()
  let (header, header_len) = read_delta_header(bytes, 0) catch {
    e => abort(@types.EncodingError::message(e))
  }
  assert_eq(header.count, 300)
  let end = delta_probe(bytes, 300, header_len, header, 64) catch {
    e => abort(@types.EncodingError::message(e))
  }
  assert_eq(end, bytes.length())
  // A count below the declared one stops *inside* the stream, which is exactly
  // why a decoder may not read the layout from the position it stops at.
  let midway = delta_probe(bytes, 100, header_len, header, 64) catch {
    e => abort(@types.EncodingError::message(e))
  }
  assert_true(midway > header_len)
  assert_true(midway < bytes.length())
}

///|
test "hybrid produced counts what the decoder would decode" {
  let values = Array::makei(900, fn(index) { (index % 5).to_int64() })
  let out = @buffer.Buffer()
  encode_rle_hybrid(values[:], 3, out) catch {
    e => abort(@types.EncodingError::message(e))
  }
  let bytes = out.to_bytes()
  let produced = hybrid_produced(bytes, 3, 900, 0) catch {
    e => abort(@types.EncodingError::message(e))
  }
  assert_eq(produced, 900)
  // A stream that ends early is refused by the walk before anything is
  // allocated: either the run it cannot satisfy raises, or the walk reports how
  // many values it could produce, and both are < 900.
  let cut = bytes[:bytes.length() - 3]
  let short = hybrid_produced(cut, 3, 900, 0) catch {
    @types.EncodingError::Truncated(_, _, _) => -1
    e => abort("probe: \{@types.EncodingError::message(e)}")
  }
  assert_true(short < 900)
}
