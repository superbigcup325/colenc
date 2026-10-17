/// Whitebox tests for BYTE_STREAM_SPLIT: plane layout, round trips and the
/// truncated read.

///|
test "byte stream split float writes one plane per byte" {
  let out = @buffer.Buffer()
  encode_byte_stream_split_float([Float(1.0), Float(2.0)], out)
  // 1.0 = 00 00 80 3f, 2.0 = 00 00 00 40, planes concatenated
  assert_eq(out.to_bytes(), b"\x00\x00\x00\x00\x80\x00\x3f\x40")
}

///|
test "byte stream split double writes eight planes" {
  let out = @buffer.Buffer()
  encode_byte_stream_split_double([1.0], out)
  assert_eq(out.to_bytes(), b"\x00\x00\x00\x00\x00\x00\xf0\x3f")
}

///|
test "byte stream split round trips floats and doubles" {
  let floats : Array[Float] = [
    Float(0.0),
    Float(-0.0),
    Float(1.5),
    Float(-2.25),
    Float(1.0e30),
  ]
  let out = @buffer.Buffer()
  encode_byte_stream_split_float(floats, out)
  let back = decode_byte_stream_split_float(out.to_bytes(), floats.length()) catch {
    _ => []
  }
  assert_eq(back, floats)

  let doubles : Array[Double] = [0.0, -0.0, 1.5, -2.25, 1.0e300]
  let out = @buffer.Buffer()
  encode_byte_stream_split_double(doubles, out)
  let back = decode_byte_stream_split_double(out.to_bytes(), doubles.length()) catch {
    _ => []
  }
  assert_eq(back, doubles)
}

///|
test "byte stream split decode reports truncation" {
  let error = capture_error(() => {
    ignore(decode_byte_stream_split_float(b"\x00\x00", 2))
  })
  match error {
    @types.EncodingError::Truncated(0, 8, 2) => ()
    _ => abort("expected Truncated(0, 8, 2)")
  }

  let error = capture_error(() => {
    ignore(decode_byte_stream_split_double(b"", -1))
  })
  match error {
    @types.EncodingError::InvalidCount(-1) => ()
    _ => abort("expected InvalidCount(-1)")
  }
}
