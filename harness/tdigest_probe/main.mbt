/// Drives the quantile summary from the acceptance rig: it reads the same
/// little-endian doubles the Python side generated, so our sketch and the
/// reference implementation see byte-identical input.
///
///   moon run --target native harness/tdigest_probe -- <file.f64le> <k> <quantiles> [parts]

///|
fn parse_int(text : String) -> Int32 {
  let mut value = 0
  for char in text {
    value = value * 10 + (char.to_int() - 48)
  }
  value
}

///|
fn read_f64_le(bytes : Bytes, offset : Int32) -> Double {
  let mut bits : Int64 = 0L
  for index in 0..<8 {
    bits = bits | (bytes[offset + index].to_int64() << (8 * index))
  }
  bits.reinterpret_as_double()
}

///|
fn parse_quantiles(text : String) -> Array[Double] {
  let out : Array[Double] = []
  let mut current = 0.0
  let mut scale = 0.1
  let mut seen_dot = false
  for char in text {
    if char == ',' {
      out.push(current)
      current = 0.0
      scale = 0.1
      seen_dot = false
    } else if char == '.' {
      seen_dot = true
    } else {
      let digit = (char.to_int() - 48).to_double()
      if seen_dot {
        current = current + digit * scale
        scale = scale * 0.1
      } else {
        current = current * 10.0 + digit
      }
    }
  }
  out.push(current)
  out
}

///|
fn checksum(bytes : Bytes) -> Int32 {
  let mut hash = 0
  for index in 0..<bytes.length() {
    hash = (hash * 31 + bytes[index].to_int()) % 1000000007
  }
  hash
}

///|
fn build(
  values : Array[Double],
  from : Int32,
  to : Int32,
  compression : Int32,
) -> @sketches.TDigest {
  let digest = @sketches.TDigest::new(compression) catch {
    error => abort(@types.EncodingError::message(error))
  }
  for index in from..<to {
    digest.update(values[index]) catch {
      error => abort(@types.EncodingError::message(error))
    }
  }
  digest
}

///|
fn report(
  prefix : String,
  digest : @sketches.TDigest,
  quantiles : Array[Double],
) -> Unit {
  for q in quantiles {
    let value = digest.quantile(q) catch {
      error => abort(@types.EncodingError::message(error))
    }
    println("RESULT|\{prefix}q|\{q}|\{value}")
  }
}

///|
fn main {
  let argv = @env.args()
  if argv.length() < 4 {
    abort("usage: tdigest_probe <file.f64le> <k> <quantiles> [parts]")
  }
  let raw = @fs.read_file_to_bytes(argv[1]) catch {
    @fs.IOError(message) => abort("cannot read \{argv[1]}: \{message}")
  }
  let count = raw.length() / 8
  let values : Array[Double] = []
  for index in 0..<count {
    values.push(read_f64_le(raw, index * 8))
  }
  let compression = parse_int(argv[2])
  let quantiles = parse_quantiles(argv[3])
  let parts = if argv.length() > 4 { parse_int(argv[4]) } else { 1 }
  println("RESULT|count|\{count}")

  let whole = build(values, 0, count, compression)
  println("RESULT|centroids|\{whole.centroid_count()}")
  println("RESULT|min|\{whole.minimum() catch { _ => 0.0 }}")
  println("RESULT|max|\{whole.maximum() catch { _ => 0.0 }}")
  report("", whole, quantiles)
  let bytes = whole.to_bytes()
  println("RESULT|bytes_length|\{bytes.length()}")
  println("RESULT|bytes_checksum|\{checksum(bytes)}")
  let back = @sketches.TDigest::from_bytes(bytes.exact_view()) catch {
    error => abort(@types.EncodingError::message(error))
  }
  println("RESULT|roundtrip|\{back.to_bytes() == bytes}")

  if parts > 1 {
    let chunk = count / parts
    // Sequential: fold one chunk at a time.
    let mut sequential = @sketches.TDigest::new(compression) catch {
      error => abort(@types.EncodingError::message(error))
    }
    for part in 0..<parts {
      let from = part * chunk
      let to = if part == parts - 1 { count } else { from + chunk }
      let piece = build(values, from, to, compression)
      sequential = sequential.merge(piece) catch {
        error => abort(@types.EncodingError::message(error))
      }
    }
    report("sequential_", sequential, quantiles)
    println("RESULT|sequential_count|\{sequential.count()}")
    // Balanced: pairwise rounds until one digest is left.
    let mut level : Array[@sketches.TDigest] = []
    for part in 0..<parts {
      let from = part * chunk
      let to = if part == parts - 1 { count } else { from + chunk }
      level.push(build(values, from, to, compression))
    }
    while level.length() > 1 {
      let next : Array[@sketches.TDigest] = []
      let mut index = 0
      while index + 1 < level.length() {
        next.push(
          level[index].merge(level[index + 1]) catch {
            error => abort(@types.EncodingError::message(error))
          },
        )
        index += 2
      }
      if index < level.length() {
        next.push(level[index])
      }
      level = next
    }
    report("balanced_", level[0], quantiles)
    println("RESULT|balanced_count|\{level[0].count()}")
  }
}
