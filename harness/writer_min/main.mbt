/// Write one required int32 column as a minimal Parquet file.
///
///   moon run harness/writer_min -- /tmp/writer_min.parquet
///   moon run harness/writer_min -- /tmp/writer_min.parquet --library
///   moon run harness/writer_min -- /tmp/writer_min.parquet --rle
///   moon run harness/writer_min -- /tmp/writer_min.parquet --dict
///   moon run harness/writer_min -- /tmp/writer_min.parquet --delta
///
/// The values are the same 1000 row sequence as the PLAIN reference fixture.
/// `--library` takes the page body from `colpack.encode_column` instead of the
/// hand-written encoder here, so the container interop check exercises the
/// library's PLAIN output. Both modes must produce identical files.
/// `--rle` writes a boolean column encoded as the RLE hybrid, again through the
/// library, so the E1 container path is judged the same way. `--dict` writes a
/// dictionary-encoded int32 column and places the dictionary page first.
/// `--delta` writes a delta-packed int64 column.

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run harness/writer_min -- <out.parquet>")
    return
  }
  let path = args[1]
  let values = Array::makei(1000, fn(index) { index * 7 - 300 })
  let bytes = if args.contains("--delta") {
    let values = Array::makei(1000, fn(index) { 7L + 3L * index.to_int64() })
    let body = Buffer()
    let stats = @colpack.encode_column(
      @types.ColBuf::Int64s(values),
      @types.DeltaBinaryPacked,
      body,
    ) catch {
      error => {
        eprintln(
          "writer_min: delta failed: \{@types.EncodingError::message(error)}",
        )
        return
      }
    }
    build_delta_int64_page("i64", body.to_bytes(), stats.value_count)
  } else if args.contains("--dict") {
    let values = Array::makei(1000, fn(index) { (index * 3 + index / 7) % 8 })
    let encoding = @colpack.encode_dictionary(@types.ColBuf::Int32s(values)) catch {
      error => {
        eprintln(
          "writer_min: dictionary failed: \{@types.EncodingError::message(error)}",
        )
        return
      }
    }
    let encoding = match encoding {
      Some(encoding) => encoding
      None => {
        eprintln("writer_min: dictionary fell back to plain")
        return
      }
    }
    build_dictionary_int32_page(
      "i32",
      encoding.dictionary,
      encoding.indices,
      encoding.dictionary_size,
      values.length(),
    )
  } else if args.contains("--rle") {
    let flags = Array::makei(1000, fn(index) { index % 3 == 0 })
    let column = @types.ColBuf::Bools(flags)
    let body = Buffer()
    let stats = @colpack.encode_column(column, @types.Rle, body) catch {
      error => {
        eprintln(
          "writer_min: encode failed: \{@types.EncodingError::message(error)}",
        )
        return
      }
    }
    build_bool_rle_page("flags", body.to_bytes(), stats.value_count)
  } else if args.contains("--library") {
    let column = @types.ColBuf::Int32s(values)
    let body = Buffer()
    let stats = @colpack.encode_column(column, @types.Plain, body) catch {
      error => {
        eprintln(
          "writer_min: encode failed: \{@types.EncodingError::message(error)}",
        )
        return
      }
    }
    build_plain_page("i32", body.to_bytes(), stats.value_count)
  } else {
    build_int32_plain("i32", values)
  }
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(message) => {
      eprintln("writer_min: cannot write \{path}: \{message}")
      return
    }
  }
  println("writer_min: wrote \{bytes.length()} bytes to \{path}")
}
