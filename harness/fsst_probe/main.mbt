/// Compress a column of strings with the FSST-style encoder, decode it back,
/// verify the round trip and report sizes. There is no reference stream: FSST
/// is not a Parquet encoding, so the criteria are round trip plus the
/// scoreboard.
///
///   moon run harness/fsst_probe -- --in values.bin [--out encoded.bin]
///
/// Input is a u32le length plus bytes per value.

///|
fn read_u32_le(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
fn usage() -> Unit {
  println("usage: moon run harness/fsst_probe -- --in <values> [--out <file>]")
}

///|
fn main {
  let args = @env.args()
  let mut input = ""
  let mut output = ""
  let mut index = 1
  while index < args.length() {
    if args[index] == "--in" && index + 1 < args.length() {
      input = args[index + 1]
      index += 2
    } else if args[index] == "--out" && index + 1 < args.length() {
      output = args[index + 1]
      index += 2
    } else {
      eprintln("fsst_probe: unexpected argument \{args[index]}")
      usage()
      return
    }
  }
  if input == "" {
    usage()
    return
  }

  let raw = @fs.read_file_to_bytes(input) catch {
    @fs.IOError(message) => {
      eprintln("fsst_probe: cannot read \{input}: \{message}")
      @sys.exit(1)
      return
    }
  }
  let values : Array[Bytes] = []
  let mut plain_bytes = 0
  let mut offset = 0
  while offset + 4 <= raw.length() {
    let length = read_u32_le(raw, offset)
    offset += 4
    values.push(raw[offset:offset + length].to_owned())
    offset += length
    plain_bytes += 4 + length
  }

  let out = Buffer()
  let _ = @colpack.encode_column(
    @types.ColBuf::ByteArrays(values),
    @types.Fsst,
    out,
  ) catch {
    error => {
      eprintln("fsst_probe: \{@types.EncodingError::message(error)}")
      @sys.exit(1)
      return
    }
  }
  let encoded = out.to_bytes()
  let decoded = @colpack.decode_column(
    encoded,
    @types.ByteArray,
    @types.Fsst,
    values.length(),
  ) catch {
    error => {
      eprintln("fsst_probe: \{@types.EncodingError::message(error)}")
      @sys.exit(1)
      return
    }
  }
  let roundtrip_ok = match decoded {
    ByteArrays(back) => back == values
    _ => false
  }
  if !roundtrip_ok {
    eprintln("fsst_probe: round trip mismatch")
    @sys.exit(1)
    return
  }
  if output != "" {
    @fs.write_bytes_to_file(output, encoded) catch {
      @fs.IOError(message) => {
        eprintln("fsst_probe: cannot write \{output}: \{message}")
        @sys.exit(1)
        return
      }
    }
  }
  println(
    "fsst_probe: count=\{values.length()} encoded=\{encoded.length()}B plain=\{plain_bytes}B roundtrip=ok",
  )
}
