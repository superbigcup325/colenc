/// Write one required int32 column as a minimal Parquet file.
///
///   moon run harness/writer_min -- /tmp/writer_min.parquet
///
/// The values are the same 1000 row sequence as the PLAIN reference fixture,
/// so the page payload can be diffed against `fixtures/plain_int32.values.bin`
/// directly as well as read back by the judges.

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run harness/writer_min -- <out.parquet>")
    return
  }
  let path = args[1]
  let values = Array::makei(1000, fn(index) { index * 7 - 300 })
  let bytes = build_int32_plain("i32", values)
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(message) => {
      eprintln("writer_min: cannot write \{path}: \{message}")
      return
    }
  }
  println("writer_min: wrote \{bytes.length()} bytes to \{path}")
}
