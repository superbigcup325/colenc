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

///|
test "facade decode refuses hostile counts without allocating" {
  // A page header can claim any value count. Every family has to reject a count
  // its handful of bytes cannot hold with a typed error, before an output is
  // sized from it; the vectors below are the page bodies a malformed file would
  // carry.
  let cases : Array[(Bytes, @types.PhysicalType, @types.Encoding, Int32)] = [
    (b"", @types.Int32, @types.Plain, 2147483647),
    (b"", @types.Int64, @types.Plain, 536870912),
    (b"", @types.Float, @types.Plain, 1073741824),
    (b"", @types.Double, @types.Plain, 268435456),
    (b"", @types.Bool, @types.Plain, 2147483647),
    (b"", @types.ByteArray, @types.Plain, 2147483647),
    (b"\x00\x00\x00\x00", @types.Float, @types.ByteStreamSplit, 536870912),
    (b"", @types.Double, @types.ByteStreamSplit, 268435456),
    (b"", @types.Int32, @types.DeltaBinaryPacked, 2147483647),
    (b"", @types.Int64, @types.DeltaBinaryPacked, 2147483647),
    (b"", @types.ByteArray, @types.DeltaLength, 2147483647),
    (b"", @types.ByteArray, @types.DeltaByteArray, 2147483647),
    (b"\x01\xff\xff\xff\x7f", @types.ByteArray, @types.Fsst, 2147483647),
  ]
  for case in cases {
    let (bytes, ty, encoding, count) = case
    let error = capture_error(() => {
      ignore(@colenc.decode_column(bytes, ty, encoding, count))
    })
    match error {
      @types.EncodingError::Truncated(_, _, _) => ()
      other =>
        fail(
          "\{@types.physical_type_name(ty)} \{@types.encoding_name(encoding)}: expected Truncated, got \{@types.EncodingError::message(other)}",
        )
    }
  }
}

///|
test "facade decode rejects a negative count on every family" {
  // A page header can carry a negative count as easily as an oversized one.
  // Every family has to answer with `InvalidCount`; the RLE path used to abort
  // inside `Array::unsafe_make_uninit(-1)` because it sized its output before
  // validating the count, and the hostile-count test above has no RLE row
  // because a hybrid stream legitimately encodes 2^31 - 1 values in six bytes
  // (the residual documented in AGENTS.md), so its oversized count is a policy
  // question rather than an input check.
  let cases : Array[(Bytes, @types.PhysicalType, @types.Encoding)] = [
    (b"", @types.Int32, @types.Plain),
    (b"", @types.Int64, @types.Plain),
    (b"", @types.Float, @types.Plain),
    (b"", @types.Double, @types.Plain),
    (b"", @types.ByteArray, @types.Plain),
    (b"", @types.Bool, @types.Plain),
    (b"\x00\x00\x00\x00", @types.Bool, @types.Rle),
    (b"", @types.Int32, @types.DeltaBinaryPacked),
    (b"", @types.Int64, @types.DeltaBinaryPacked),
    (b"", @types.ByteArray, @types.DeltaLength),
    (b"", @types.ByteArray, @types.DeltaByteArray),
    (b"", @types.Float, @types.ByteStreamSplit),
    (b"", @types.Double, @types.ByteStreamSplit),
    (b"", @types.ByteArray, @types.Fsst),
  ]
  for case in cases {
    let (bytes, ty, encoding) = case
    let error = capture_error(() => {
      ignore(@colenc.decode_column(bytes, ty, encoding, -1))
    })
    match error {
      @types.EncodingError::InvalidCount(count) => assert_eq(count, -1)
      other =>
        fail(
          "\{@types.physical_type_name(ty)} \{@types.encoding_name(encoding)}: expected InvalidCount(-1), got \{@types.EncodingError::message(other)}",
        )
    }
  }
}

///|
test "facade round trips both delta byte-array families" {
  // The two branches share a signature (`ByteArray` in, `ByteArrays` out), so
  // swapping them is invisible to the type checker and to every test that only
  // covers one of them: the DELTA_LENGTH page then parses as DELTA_BYTE_ARRAY
  // and the values come back wrong with no error at all. One round trip per
  // family through the dispatch is the guard.
  let values : Array[Bytes] = [b"", b"a", b"beat", b"bead", b"zzzz"]
  let column = @types.ColBuf::ByteArrays(values)
  for encoding in [@types.DeltaLength, @types.DeltaByteArray] {
    let out = @buffer.Buffer()
    ignore(
      @colenc.encode_column(column, encoding, out) catch {
        _ => abort("encode failed for \{@types.encoding_name(encoding)}")
      },
    )
    let back = @colenc.decode_column(
      out.to_bytes(),
      @types.ByteArray,
      encoding,
      values.length(),
    ) catch {
      _ => abort("decode failed for \{@types.encoding_name(encoding)}")
    }
    match back {
      ByteArrays(got) => assert_eq(got, values)
      _ => abort("round trip changed the physical type")
    }
  }
}
