/// Encode a value sequence with the library's RLE / bit-packed hybrid and
/// write the raw stream, so the harness can diff it against a reference.
///
///   moon run harness/rle_probe -- --in values.u64le --width 2 --out out.bin
///
/// The input is one little-endian u64 per value; the output is the hybrid
/// stream with no page-level prefix.

///|
fn read_u64_le(data : Bytes, offset : Int32) -> Int64 {
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (data[offset + index].to_int().to_uint64() << (index * 8))
  }
  value.reinterpret_as_int64()
}

///|
fn usage() -> Unit {
  println(
    "usage: moon run harness/rle_probe -- --in <values.u64le> --width <n> --out <stream.bin>",
  )
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut output = ""
  let mut width = -1
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--width" && index + 1 < args.length() {
      width = @string.parse_int(args[index + 1]) catch { _ => -1 }
      index += 2
    } else if args[index] == "--out" && index + 1 < args.length() {
      output = args[index + 1]
      index += 2
    } else {
      eprintln("rle_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" || output == "" || width < 0 {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("rle_probe: cannot read \{input}: \{message}")
      return
    }
  }
  let count = raw.length() / 8
  let values = Array::makei(count, fn(position) {
    read_u64_le(raw, position * 8)
  })
  let out = Buffer()
  @encoders.encode_rle_hybrid(values[:], width, out) catch {
    error => {
      eprintln("rle_probe: \{@types.EncodingError::message(error)}")
      return
    }
  }
  let bytes = out.to_bytes()
  @fs.write_bytes_to_file(output, bytes) catch {
    @fs.IOError(message) => {
      eprintln("rle_probe: cannot write \{output}: \{message}")
      return
    }
  }
  println(
    "rle_probe: \{count} values at width \{width} -> \{bytes.length()} bytes",
  )
}
