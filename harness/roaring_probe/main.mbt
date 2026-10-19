/// Encode a set of ids as a Roaring bitmap and write the portable stream, so
/// the harness can diff it against the reference.
///
///   moon run harness/roaring_probe -- --in ids.i32le --out out.bin [--run-optimize]
///
/// The input is one little-endian INT32 id per value; duplicates and order do
/// not matter, because the encoding is a set.

///|
fn read_i32_le(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
fn usage() -> Unit {
  println(
    "usage: moon run harness/roaring_probe -- --in <ids.i32le> --out <bitmap.bin> [--run-optimize]",
  )
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut output = ""
  let mut run_optimize = false
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--out" && index + 1 < args.length() {
      output = args[index + 1]
      index += 2
    } else if args[index] == "--run-optimize" {
      run_optimize = true
      index += 1
    } else {
      eprintln("roaring_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" || output == "" {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("roaring_probe: cannot read \{input}: \{message}")
      return
    }
  }
  let count = raw.length() / 4
  let ids = Array::makei(count, fn(position) { read_i32_le(raw, position * 4) })
  let out = Buffer()
  let encode = if run_optimize {
    @encoders.encode_roaring_run_optimized
  } else {
    @encoders.encode_roaring
  }
  encode(ids, out) catch {
    error => {
      eprintln("roaring_probe: \{@types.EncodingError::message(error)}")
      return
    }
  }
  let bytes = out.to_bytes()
  @fs.write_bytes_to_file(output, bytes) catch {
    @fs.IOError(message) => {
      eprintln("roaring_probe: cannot write \{output}: \{message}")
      return
    }
  }
  let suffix = if run_optimize { " (run optimised)" } else { "" }
  println("roaring_probe: \{count} ids -> \{bytes.length()} bytes\{suffix}")
}
