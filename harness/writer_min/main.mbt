/// Write one required int32 column as a minimal Parquet file.
///
///   moon run harness/writer_min -- /tmp/writer_min.parquet
///   moon run harness/writer_min -- /tmp/writer_min.parquet --library
///   moon run harness/writer_min -- /tmp/writer_min.parquet --rle
///
/// The values are the same 1000 row sequence as the PLAIN reference fixture.
/// `--library` takes the page body from `colpack.encode_column` instead of the
/// hand-written encoder here, so the container interop check exercises the
/// library's PLAIN output. Both modes must produce identical files.
/// `--rle` writes a boolean column encoded as the RLE hybrid, again through the
/// library, so the E1 container path is judged the same way.

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run harness/writer_min -- <out.parquet>")
    return
  }
  let path = args[1]
  let values = Array::makei(1000, fn(index) { index * 7 - 300 })
  let bytes = if args.contains("--rle") {
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
