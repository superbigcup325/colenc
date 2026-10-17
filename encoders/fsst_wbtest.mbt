/// Whitebox tests for the FSST-style compressor: round trip, the scoreboard
/// direction, and the rejection paths. There is no reference stream to diff
/// against, so these tests carry the correctness argument together with the
/// scoreboard.

///|
test "fsst round trips short strings" {
  let values : Array[Bytes] = [
    b"abcabcabc", b"abcabc", b"xyz", b"", b"abcabcabc",
  ]
  let out = @buffer.Buffer()
  encode_fsst(values, out)
  let back = decode_fsst(out.to_bytes(), values.length()) catch { _ => ([], 0) }
  assert_eq(back.0, values)
  assert_eq(back.1, out.length())
}

///|
test "fsst compresses repetitive input" {
  let text = b"the quick brown fox jumps over the lazy dog"
  let values = Array::make(200, text)
  let out = @buffer.Buffer()
  encode_fsst(values, out)
  let plain = values.length() * (4 + text.length())
  assert_true(out.length() < plain)
}

///|
test "fsst decode reports malformed input" {
  let error = capture_error(() => ignore(decode_fsst(b"", 1)))
  match error {
    @types.EncodingError::Truncated(0, 1, 0) => ()
    _ => abort("expected Truncated(0, 1, 0)")
  }

  let out = @buffer.Buffer()
  encode_fsst([b"abcabc"], out)
  let error = capture_error(() => ignore(decode_fsst(out.to_bytes(), 2)))
  match error {
    @types.EncodingError::Incomplete(1, 2) => ()
    _ => abort("expected Incomplete(1, 2)")
  }

  // a symbol count of one, a one-byte symbol, one value whose code is 5
  let malformed = b"\x01\x01a\x01\x00\x00\x00\x01\x00\x00\x00\x05"
  let error = capture_error(() => ignore(decode_fsst(malformed, 1)))
  match error {
    @types.EncodingError::InvalidIndex(5, 1) => ()
    _ => abort("expected InvalidIndex(5, 1)")
  }
}
