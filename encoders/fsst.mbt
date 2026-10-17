/// FSST-style string compression (E7): a symbol table of up to 255 short
/// strings (at most eight bytes each), greedy longest-match encoding, and an
/// escape byte for literals.
///
/// This is deliberately colenc's own framing, not DuckDB's FSST wire format:
/// Parquet has no native FSST encoding, so there is nothing to byte-diff
/// against. The criteria are round trip plus a compression scoreboard, as the
/// roadmap states.
///
/// Framing:
///
///   [mode u8]  0 = compressed, 1 = stored raw
///   compressed: [symbol count u8]
///               per symbol: [length u8][bytes]
///               [value count u32le]
///               per value: [compressed length u32le][codes and literals]
///   stored:     [value count u32le]
///               per value: [length u32le][bytes]
///
/// Codes 0..count-1 select a symbol; 255 escapes one raw literal byte.
/// The encoder compares both bodies and stores the smaller one, so FSST never
/// expands a column by more than the mode byte. The symbol table is built from
/// a bounded sample (64 KiB, at most 4 KiB per value), which keeps the substring
/// counter linear on large inputs.

///|
const FSST_MAX_SYMBOLS : Int32 = 255

///|
const FSST_MAX_SYMBOL_LENGTH : Int32 = 8

///|
const FSST_ESCAPE : Int32 = 255

///|
const FSST_MODE_COMPRESSED : Int32 = 0

///|
const FSST_MODE_STORED : Int32 = 1

///|
const FSST_SAMPLE_BYTES : Int32 = 65536

///|
const FSST_SAMPLE_VALUE_PREFIX : Int32 = 4096

///|
fn symbol_savings(entry : (Bytes, Int32)) -> Int32 {
  entry.1 * (entry.0.length() - 1)
}

///|
fn compare_symbols(a : (Bytes, Int32), b : (Bytes, Int32)) -> Int32 {
  let savings_a = symbol_savings(a)
  let savings_b = symbol_savings(b)
  if savings_a != savings_b {
    return savings_b - savings_a
  }
  if a.0.length() != b.0.length() {
    return b.0.length() - a.0.length()
  }
  a.0[:].compare(b.0[:])
}

///|
/// Pick the symbol table: count every substring of two to eight bytes, keep
/// the ones that occur at least twice, rank by bytes saved, and take the best
/// 255. Ties break on length then bytes so the table is deterministic.
fn build_symbols(values : Array[Bytes]) -> Array[Bytes] {
  let counts : Map[Bytes, Int32] = Map([])
  let mut budget = 0
  for value in values {
    if budget >= FSST_SAMPLE_BYTES {
      break
    }
    let length = if value.length() < FSST_SAMPLE_VALUE_PREFIX {
      value.length()
    } else {
      FSST_SAMPLE_VALUE_PREFIX
    }
    budget += length
    for start in 0..<length {
      let room = if length - start < FSST_MAX_SYMBOL_LENGTH {
        length - start
      } else {
        FSST_MAX_SYMBOL_LENGTH
      }
      for piece_length in 2..<=room {
        let piece = value[start:start + piece_length].to_owned()
        match counts.get(piece) {
          Some(count) => counts.set(piece, count + 1)
          None => counts.set(piece, 1)
        }
      }
    }
  }
  let entries : Array[(Bytes, Int32)] = []
  counts.each(fn(piece, count) {
    // a symbol must pay for its own table entry
    if count >= 2 && symbol_savings((piece, count)) > piece.length() + 1 {
      entries.push((piece, count))
    }
  })
  entries.sort_by(compare_symbols)
  let symbols : Array[Bytes] = []
  let limit = if entries.length() < FSST_MAX_SYMBOLS {
    entries.length()
  } else {
    FSST_MAX_SYMBOLS
  }
  for index in 0..<limit {
    symbols.push(entries[index].0)
  }
  symbols
}

///|
fn encode_value(
  value : Bytes,
  codes : Map[Bytes, Int32],
  out : @buffer.Buffer,
) -> Unit {
  let length = value.length()
  let mut position = 0
  while position < length {
    let room = if length - position < FSST_MAX_SYMBOL_LENGTH {
      length - position
    } else {
      FSST_MAX_SYMBOL_LENGTH
    }
    let mut matched = 0
    let mut candidate = room
    while candidate >= 2 {
      let view = value[position:position + candidate]
      match codes.get_from_bytes(view) {
        Some(code) => {
          matched = candidate
          out.write_byte(code.to_byte())
          break
        }
        None => candidate -= 1
      }
    }
    if matched == 0 {
      out.write_byte(FSST_ESCAPE.to_byte())
      out.write_byte(value[position])
      position += 1
    } else {
      position += matched
    }
  }
}

///|
/// Compress a column of byte strings. The table is built from a bounded sample
/// and the framing falls back to stored raw values whenever compression does
/// not pay for the table, so the output never exceeds the raw size by more
/// than the mode byte.
pub fn encode_fsst(values : Array[Bytes], out : @buffer.Buffer) -> Unit {
  let symbols = build_symbols(values)

  let compressed = Buffer()
  compressed.write_byte(symbols.length().to_byte())
  let codes : Map[Bytes, Int32] = Map([])
  for index in 0..<symbols.length() {
    let symbol = symbols[index]
    compressed.write_byte(symbol.length().to_byte())
    compressed.write_bytes(symbol)
    codes.set(symbol, index)
  }
  compressed.write_int_le(values.length())
  for value in values {
    let body = Buffer()
    encode_value(value, codes, body)
    let bytes = body.to_bytes()
    compressed.write_int_le(bytes.length())
    compressed.write_bytes(bytes)
  }

  let stored = Buffer()
  stored.write_int_le(values.length())
  for value in values {
    stored.write_int_le(value.length())
    stored.write_bytes(value)
  }

  let compressed_bytes = compressed.to_bytes()
  let stored_bytes = stored.to_bytes()
  if compressed_bytes.length() < stored_bytes.length() {
    out.write_byte(FSST_MODE_COMPRESSED.to_byte())
    out.write_bytes(compressed_bytes)
  } else {
    out.write_byte(FSST_MODE_STORED.to_byte())
    out.write_bytes(stored_bytes)
  }
}

///|
/// Decode a column written by `encode_fsst`. `count` is the number of values
/// the caller expects; a different stored count is reported rather than
/// silently truncating.
pub fn decode_fsst(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
) -> (Array[Bytes], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let mut position = offset
  if position >= data.length() {
    raise @types.EncodingError::Truncated(position, 1, 0)
  }
  let mode = data[position].to_int()
  position += 1
  match mode {
    FSST_MODE_STORED => {
      if position + 4 > data.length() {
        raise @types.EncodingError::Truncated(
          position,
          4,
          data.length() - position,
        )
      }
      let stored_count = read_u32_le(data, position)
      position += 4
      if stored_count != count {
        raise @types.EncodingError::Incomplete(stored_count, count)
      }
      let values : Array[Bytes] = []
      for _ in 0..<count {
        if position + 4 > data.length() {
          raise @types.EncodingError::Truncated(
            position,
            4,
            data.length() - position,
          )
        }
        let length = read_u32_le(data, position)
        position += 4
        if length < 0 {
          raise @types.EncodingError::InvalidCount(length)
        }
        if position + length > data.length() {
          raise @types.EncodingError::Truncated(
            position,
            length,
            data.length() - position,
          )
        }
        values.push(data[position:position + length].to_owned())
        position += length
      }
      (values, position - offset)
    }
    FSST_MODE_COMPRESSED => {
      if position >= data.length() {
        raise @types.EncodingError::Truncated(position, 1, 0)
      }
      let symbol_count = data[position].to_int()
      position += 1
      let symbols : Array[Bytes] = []
      for _ in 0..<symbol_count {
        if position >= data.length() {
          raise @types.EncodingError::Truncated(position, 1, 0)
        }
        let length = data[position].to_int()
        position += 1
        if position + length > data.length() {
          raise @types.EncodingError::Truncated(
            position,
            length,
            data.length() - position,
          )
        }
        symbols.push(data[position:position + length].to_owned())
        position += length
      }
      if position + 4 > data.length() {
        raise @types.EncodingError::Truncated(
          position,
          4,
          data.length() - position,
        )
      }
      let stored_count = read_u32_le(data, position)
      position += 4
      if stored_count != count {
        raise @types.EncodingError::Incomplete(stored_count, count)
      }
      let values : Array[Bytes] = []
      for _ in 0..<count {
        if position + 4 > data.length() {
          raise @types.EncodingError::Truncated(
            position,
            4,
            data.length() - position,
          )
        }
        let compressed_length = read_u32_le(data, position)
        position += 4
        if compressed_length < 0 {
          raise @types.EncodingError::InvalidCount(compressed_length)
        }
        if position + compressed_length > data.length() {
          raise @types.EncodingError::Truncated(
            position,
            compressed_length,
            data.length() - position,
          )
        }
        let end = position + compressed_length
        let value = Buffer()
        while position < end {
          let code = data[position].to_int()
          position += 1
          if code == FSST_ESCAPE {
            if position >= end {
              raise @types.EncodingError::Truncated(position, 1, 0)
            }
            value.write_byte(data[position])
            position += 1
          } else if code < symbols.length() {
            value.write_bytes(symbols[code])
          } else {
            raise @types.EncodingError::InvalidIndex(code, symbols.length())
          }
        }
        values.push(value.to_bytes())
      }
      (values, position - offset)
    }
    _ => raise @types.EncodingError::InvalidTag(mode)
  }
}
