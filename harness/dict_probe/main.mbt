/// Build a dictionary encoding with the library and write both payloads, so
/// the harness can diff them against the reference.
///
///   moon run harness/dict_probe -- --in values.bin --type int32 \
///     --out-dict dict.bin --out-indices indices.bin
///
/// int32 input is little-endian u64 per value; string input is a u32le length
/// followed by the bytes, once per value.

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
    "usage: moon run harness/dict_probe -- --in <values> --type <int32|string> --out-dict <file> --out-indices <file>",
  )
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut kind = ""
  let mut dict_path = ""
  let mut indices_path = ""
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--type" && index + 1 < args.length() {
      kind = args[index + 1]
      index += 2
    } else if args[index] == "--out-dict" && index + 1 < args.length() {
      dict_path = args[index + 1]
      index += 2
    } else if args[index] == "--out-indices" && index + 1 < args.length() {
      indices_path = args[index + 1]
      index += 2
    } else {
      eprintln("dict_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" || kind == "" || dict_path == "" || indices_path == "" {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("dict_probe: cannot read \{input}: \{message}")
      return
    }
  }
  let column = if kind == "int32" {
    let count = raw.length() / 8
    Array::makei(count, fn(position) { read_u64_le(raw, position * 8).to_int() })
    |> @types.ColBuf::Int32s
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
    eprintln("dict_probe: unknown type \{kind}")
    return
  }

  let encoding = @colpack.encode_dictionary(column) catch {
    error => {
      eprintln(
        "dict_probe: encode failed: \{@types.EncodingError::message(error)}",
      )
      return
    }
  }
  let encoding = match encoding {
    Some(encoding) => encoding
    None => {
      eprintln("dict_probe: dictionary fell back to plain")
      return
    }
  }

  @fs.write_bytes_to_file(dict_path, encoding.dictionary) catch {
    @fs.IOError(message) => {
      eprintln("dict_probe: cannot write \{dict_path}: \{message}")
      return
    }
  }
  @fs.write_bytes_to_file(indices_path, encoding.indices) catch {
    @fs.IOError(message) => {
      eprintln("dict_probe: cannot write \{indices_path}: \{message}")
      return
    }
  }

  let plain = Buffer()
  let plain_stats = @colpack.encode_column(column, @types.Plain, plain) catch {
    error => {
      eprintln(
        "dict_probe: plain encode failed: \{@types.EncodingError::message(error)}",
      )
      return
    }
  }
  println(
    "dict_probe: \{kind} count=\{encoding.dictionary_size}ent|\{plain_stats.value_count}vals dict=\{encoding.dictionary.length()}B indices=\{encoding.indices.length()}B width=\{encoding.bit_width} plain=\{plain_stats.encoded_bytes}B",
  )
}
