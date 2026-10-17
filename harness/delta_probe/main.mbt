/// Encode a value sequence with one of the delta encodings and write the raw
/// stream, so the harness can diff it against a reference.
///
///   moon run harness/delta_probe -- --in values.bin --type int64 \
///     --encoding delta --out stream.bin
///
/// int32/int64 input is little-endian u64 per value; string input is a u32le
/// length followed by the bytes, once per value.

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
    "usage: moon run harness/delta_probe -- --in <values> --type <int32|int64|string> --encoding <delta|delta-length|delta-byte-array> --out <file>",
  )
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut kind = ""
  let mut encoding_name = ""
  let mut output = ""
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--type" && index + 1 < args.length() {
      kind = args[index + 1]
      index += 2
    } else if args[index] == "--encoding" && index + 1 < args.length() {
      encoding_name = args[index + 1]
      index += 2
    } else if args[index] == "--out" && index + 1 < args.length() {
      output = args[index + 1]
      index += 2
    } else {
      eprintln("delta_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" || kind == "" || encoding_name == "" || output == "" {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("delta_probe: cannot read \{input}: \{message}")
      return
    }
  }
  let column = if kind == "int32" {
    let count = raw.length() / 8
    @types.ColBuf::Int32s(
      Array::makei(count, fn(position) {
        read_u64_le(raw, position * 8).to_int()
      }),
    )
  } else if kind == "int64" {
    let count = raw.length() / 8
    @types.ColBuf::Int64s(
      Array::makei(count, fn(position) { read_u64_le(raw, position * 8) }),
    )
  } else if kind == "string" {
    let values : Array[Bytes] = []
    let mut offset = 0
    while offset + 4 <= raw.length() {
      let length = read_u32_le(raw, offset)
      offset += 4
      values.push(raw[offset:offset + length].to_owned())
      offset += length
    }
    @types.ColBuf::ByteArrays(values)
  } else {
    eprintln("delta_probe: unknown type \{kind}")
    return
  }

  let encoding = if encoding_name == "delta" {
    @types.DeltaBinaryPacked
  } else if encoding_name == "delta-length" {
    @types.DeltaLength
  } else if encoding_name == "delta-byte-array" {
    @types.DeltaByteArray
  } else {
    eprintln("delta_probe: unknown encoding \{encoding_name}")
    return
  }

  let out = Buffer()
  let stats = @colpack.encode_column(column, encoding, out) catch {
    error => {
      eprintln("delta_probe: \{@types.EncodingError::message(error)}")
      return
    }
  }
  let bytes = out.to_bytes()
  @fs.write_bytes_to_file(output, bytes) catch {
    @fs.IOError(message) => {
      eprintln("delta_probe: cannot write \{output}: \{message}")
      return
    }
  }

  let plain = Buffer()
  let plain_stats = @colpack.encode_column(column, @types.Plain, plain) catch {
    error => {
      eprintln(
        "delta_probe: plain failed: \{@types.EncodingError::message(error)}",
      )
      return
    }
  }
  println(
    "delta_probe: \{kind} \{encoding_name} count=\{stats.value_count} encoded=\{stats.encoded_bytes}B plain=\{plain_stats.encoded_bytes}B",
  )
}
