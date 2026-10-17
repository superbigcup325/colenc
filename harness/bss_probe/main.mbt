/// Encode float or double values with BYTE_STREAM_SPLIT and write the raw
/// stream, so the harness can diff it against a reference.
///
///   moon run harness/bss_probe -- --in values.bin --type float --out out.bin
///
/// Input is the values themselves, little-endian: f32 for `float`, f64 for
/// `double`, one after another.

///|
fn read_u32_le(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

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
    "usage: moon run harness/bss_probe -- --in <values> --type <float|double> --out <file>",
  )
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut kind = ""
  let mut output = ""
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--type" && index + 1 < args.length() {
      kind = args[index + 1]
      index += 2
    } else if args[index] == "--out" && index + 1 < args.length() {
      output = args[index + 1]
      index += 2
    } else {
      eprintln("bss_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" || kind == "" || output == "" {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("bss_probe: cannot read \{input}: \{message}")
      return
    }
  }
  let column = if kind == "float" {
    let count = raw.length() / 4
    @types.ColBuf::Floats(
      Array::makei(count, fn(position) {
        Float::reinterpret_from_int(read_u32_le(raw, position * 4))
      }),
    )
  } else if kind == "double" {
    let count = raw.length() / 8
    @types.ColBuf::Doubles(
      Array::makei(count, fn(position) {
        read_u64_le(raw, position * 8)
        .reinterpret_as_uint64()
        .reinterpret_as_double()
      }),
    )
  } else {
    eprintln("bss_probe: unknown type \{kind}")
    return
  }

  let out = Buffer()
  let stats = @colpack.encode_column(column, @types.ByteStreamSplit, out) catch {
    error => {
      eprintln("bss_probe: \{@types.EncodingError::message(error)}")
      return
    }
  }
  let bytes = out.to_bytes()
  @fs.write_bytes_to_file(output, bytes) catch {
    @fs.IOError(message) => {
      eprintln("bss_probe: cannot write \{output}: \{message}")
      return
    }
  }
  let plain = Buffer()
  let plain_stats = @colpack.encode_column(column, @types.Plain, plain) catch {
    error => {
      eprintln(
        "bss_probe: plain failed: \{@types.EncodingError::message(error)}",
      )
      return
    }
  }
  println(
    "bss_probe: \{kind} count=\{stats.value_count} encoded=\{stats.encoded_bytes}B plain=\{plain_stats.encoded_bytes}B",
  )
}
