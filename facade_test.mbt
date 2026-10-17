/// Blackbox tests for the dispatch layer: every ColBuf variant must survive an
/// encode/decode round trip through the facade, statistics must describe the
/// call, and unimplemented families must be reported rather than guessed.

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
test "facade plain round trips every physical type" {
  let cases : Array[@types.ColBuf] = [
    @types.ColBuf::Int32s([0, 1, -1]),
    @types.ColBuf::Int64s([0L, 1L, -1L]),
    @types.ColBuf::Floats([Float(0.0), Float(1.5), Float(-2.25)]),
    @types.ColBuf::Doubles([0.0, 1.5, -2.25]),
    @types.ColBuf::ByteArrays([b"", b"abc"]),
    @types.ColBuf::Bools([true, false, true]),
  ]
  for column in cases {
    let out = @buffer.Buffer()
    let stats = @colenc.encode_column(column, @types.Plain, out) catch {
      _ => abort("encode failed")
    }
    assert_eq(stats.value_count, column.value_count())
    assert_eq(stats.encoded_bytes, out.length())
    let back = @colenc.decode_column(
      out.to_bytes(),
      column.physical_type(),
      @types.Plain,
      column.value_count(),
    ) catch {
      _ => abort("decode failed")
    }
    match (column, back) {
      (Int32s(want), Int32s(got)) => assert_eq(got, want)
      (Int64s(want), Int64s(got)) => assert_eq(got, want)
      (Floats(want), Floats(got)) => assert_eq(got, want)
      (Doubles(want), Doubles(got)) => assert_eq(got, want)
      (ByteArrays(want), ByteArrays(got)) => assert_eq(got, want)
      (Bools(want), Bools(got)) => assert_eq(got, want)
      _ => abort("round trip changed the physical type")
    }
  }
}

///|
test "facade reports bytes appended, not total length" {
  let out = @buffer.Buffer()
  out.write_bytes(b"prefix")
  let stats = @colenc.encode_column(
    @types.ColBuf::Int32s([1]),
    @types.Plain,
    out,
  ) catch {
    _ => abort("encode failed")
  }
  assert_eq(stats.encoded_bytes, 4)
  assert_eq(out.to_bytes(), b"prefix\x01\x00\x00\x00")
}

///|
test "facade rejects unimplemented families" {
  let out = @buffer.Buffer()
  let error = capture_error(() => {
    ignore(
      @colenc.encode_column(@types.ColBuf::Int32s([1]), @types.Dictionary, out),
    )
  })
  match error {
    @types.EncodingError::Unsupported(@types.Dictionary) => ()
    _ => abort("expected Unsupported(Dictionary)")
  }

  let error = capture_error(() => {
    ignore(@colenc.decode_column(b"", @types.Int32, @types.Rle, 0))
  })
  match error {
    @types.EncodingError::TypeMismatch(@types.Int32, @types.Rle) => ()
    _ => abort("expected TypeMismatch(Int32, Rle)")
  }

  // Dictionary needs its own entry point because it has two streams
  let error = capture_error(() => {
    ignore(@colenc.decode_column(b"", @types.Int32, @types.Dictionary, 0))
  })
  match error {
    @types.EncodingError::Unsupported(@types.Dictionary) => ()
    _ => abort("expected Unsupported(Dictionary)")
  }
}

///|
test "facade decode surfaces truncation with the offset" {
  let error = capture_error(() => {
    ignore(@colenc.decode_column(b"\x01\x02", @types.Int32, @types.Plain, 2))
  })
  match error {
    @types.EncodingError::Truncated(0, 8, 2) => ()
    _ => abort("expected Truncated(0, 8, 2)")
  }
}
