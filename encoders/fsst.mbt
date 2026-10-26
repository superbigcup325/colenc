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
/// Little-endian byte pattern of `length` bytes at `start`, zero-extended to a
/// word. `length` is between two and eight.
fn pack_prefix(value : Bytes, start : Int32, length : Int32) -> UInt64 {
  let mut prefix = 0UL
  for index in 0..<length {
    prefix = prefix | (value[start + index].to_uint64() << (index * 8))
  }
  prefix
}

///|
/// Rebuild the substring a packed key stands for. Only called for candidates
/// that survived the count filter, so the allocation is paid a few hundred
/// times per column rather than once per substring.
fn symbol_bytes(prefix : UInt64, length : Int32) -> Bytes {
  let out = Buffer()
  for index in 0..<length {
    let byte = ((prefix >> (index * 8)) & 0xFFUL).to_int()
    out.write_byte(byte.to_byte())
  }
  out.to_bytes()
}

///|
/// Substring counters keyed by packed bytes. Two tables because a length-eight
/// key uses every bit of the word, while a shorter key keeps its length in the
/// spare top byte.
priv struct SymbolCounts {
  short : Map[UInt64, Int32]
  long : Map[UInt64, Int32]
}

///|
fn SymbolCounts::new() -> SymbolCounts {
  { short: Map([]), long: Map([]), }
}

///|
fn SymbolCounts::bump(
  self : SymbolCounts,
  prefix : UInt64,
  length : Int32,
) -> Unit {
  if length == 8 {
    match self.long.get(prefix) {
      Some(count) => self.long.set(prefix, count + 1)
      None => self.long.set(prefix, 1)
    }
  } else {
    let key = (length.to_uint64() << 56) | prefix
    match self.short.get(key) {
      Some(count) => self.short.set(key, count + 1)
      None => self.short.set(key, 1)
    }
  }
}

///|
fn SymbolCounts::each(
  self : SymbolCounts,
  visit : (UInt64, Int32, Int32) -> Unit,
) -> Unit {
  self.short.each(fn(key, count) {
    visit(key & 0xFFFFFFFFFFFFFFUL, (key >> 56).to_int(), count)
  })
  self.long.each(fn(key, count) { visit(key, 8, count) })
}

///|
/// Symbol lookup for the encoder, keyed the same way as the counters: the
/// greedy match probes a word instead of hashing a fresh slice for every
/// candidate length.
priv struct SymbolCodes {
  short : Map[UInt64, Int32]
  long : Map[UInt64, Int32]
}

///|
fn SymbolCodes::new() -> SymbolCodes {
  { short: Map([]), long: Map([]), }
}

///|
fn SymbolCodes::set(
  self : SymbolCodes,
  prefix : UInt64,
  length : Int32,
  code : Int32,
) -> Unit {
  if length == 8 {
    self.long.set(prefix, code)
  } else {
    self.short.set((length.to_uint64() << 56) | prefix, code)
  }
}

///|
fn SymbolCodes::get(
  self : SymbolCodes,
  prefix : UInt64,
  length : Int32,
) -> Int32? {
  if length == 8 {
    self.long.get(prefix)
  } else {
    self.short.get((length.to_uint64() << 56) | prefix)
  }
}

///|
/// Pick the symbol table: count every substring of two to eight bytes, keep
/// the ones that occur at least twice, rank by bytes saved, and take the best
/// 255. Ties break on length then bytes so the table is deterministic.
///
/// Counting keys on the packed bytes rather than on freshly allocated `Bytes`
/// changes neither the counts nor the ranking, so the table — and therefore the
/// output — stays byte-identical to the slice-keyed version.
fn build_symbols(values : Array[Bytes]) -> Array[Bytes] {
  let counts = SymbolCounts::new()
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
      // the first byte of the window is fixed across lengths; each step then
      // appends the next byte, so a position costs one load per length
      let mut prefix = value[start].to_uint64()
      for piece_length in 2..<=room {
        prefix = prefix |
          (
            value[start + piece_length - 1].to_uint64() <<
            ((piece_length - 1) * 8)
          )
        counts.bump(prefix, piece_length)
      }
    }
  }
  let entries : Array[(Bytes, Int32)] = []
  counts.each(fn(prefix, piece_length, count) {
    // a symbol must pay for its own table entry
    if count >= 2 {
      let piece = symbol_bytes(prefix, piece_length)
      if symbol_savings((piece, count)) > piece.length() + 1 {
        entries.push((piece, count))
      }
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

///|
/// Write one value as symbol codes, escaping the bytes no symbol covers.
///
/// The window is packed once per position and masked down per candidate length,
/// so the greedy longest-match scan costs one word compare per candidate
/// instead of hashing a fresh slice for each of them. The selection rule is
/// unchanged: longest match wins, otherwise the byte is escaped.
fn encode_value(
  value : Bytes,
  codes : SymbolCodes,
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
    if room >= 2 {
      let window = pack_prefix(value, position, room)
      let mut candidate = room
      while candidate >= 2 {
        let prefix = if candidate == 8 {
          window
        } else {
          window & ((1UL << (candidate * 8)) - 1UL)
        }
        match codes.get(prefix, candidate) {
          Some(code) => {
            matched = candidate
            out.write_byte(code.to_byte())
            break
          }
          None => candidate -= 1
        }
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
///
/// The per-value payloads go into one buffer and their lengths into an array,
/// which is what keeps the encoder from allocating a `Buffer` per value: the
/// only copies are the final assembly into `out`. The stored body is never
/// materialised — its size is arithmetic — so the comparison that picks the
/// smaller mode costs nothing.
pub fn encode_fsst(values : Array[Bytes], out : @buffer.Buffer) -> Unit {
  encode_fsst_with(FsstModel::train(values), values, out)
}

///|
/// A trained symbol table that can encode any number of batches. `train` pays
/// the table build once (the dominant cost of `encode_fsst` on small batches);
/// `encode_fsst_with` then only matches and writes. The model is immutable, so
/// it can be shared between batches and between calls.
///
/// The frame is unchanged: every encoded batch still carries its own copy of
/// the table, so `decode_fsst` reads it without the model and a batch stays
/// self-contained. The cost of that choice is the table bytes repeated per
/// batch (at most 2 KiB), which is why the model pays off on batches large
/// enough to amortize them. A batch the model compresses worse than storing it
/// raw falls back to the stored frame exactly as before.
pub struct FsstModel {
  priv symbols : Array[Bytes]
  priv codes : SymbolCodes
}

///|
/// Train a model on a sample batch with the same bounded-sample rule
/// `encode_fsst` uses.
pub fn FsstModel::train(values : Array[Bytes]) -> FsstModel {
  let symbols = build_symbols(values)
  let codes = SymbolCodes::new()
  for index in 0..<symbols.length() {
    let symbol = symbols[index]
    codes.set(pack_prefix(symbol, 0, symbol.length()), symbol.length(), index)
  }
  { symbols, codes, }
}

///|
pub fn FsstModel::symbol_count(self : FsstModel) -> Int32 {
  self.symbols.length()
}

///|
/// Bytes the table occupies inside one encoded batch: the count byte, then a
/// length byte and the bytes of each symbol.
pub fn FsstModel::table_bytes(self : FsstModel) -> Int32 {
  let mut total = 1
  for symbol in self.symbols {
    total += 1 + symbol.length()
  }
  total
}

///|
/// Encode `values` with a trained model. Equivalent to `encode_fsst` when the
/// model was trained on `values` themselves.
pub fn encode_fsst_with(
  model : FsstModel,
  values : Array[Bytes],
  out : @buffer.Buffer,
) -> Unit {
  let symbols = model.symbols
  let codes = model.codes
  let head = Buffer()
  head.write_byte(symbols.length().to_byte())
  for symbol in symbols {
    head.write_byte(symbol.length().to_byte())
    head.write_bytes(symbol)
  }
  head.write_int_le(values.length())

  let bodies = Buffer()
  let lengths : Array[Int32] = []
  for value in values {
    let start = bodies.length()
    encode_value(value, codes, bodies)
    lengths.push(bodies.length() - start)
  }
  let mut stored_size = 4
  for value in values {
    stored_size += 4 + value.length()
  }
  let compressed_size = head.length() + 4 * values.length() + bodies.length()
  if compressed_size < stored_size {
    out.write_byte(FSST_MODE_COMPRESSED.to_byte())
    out.write_bytes(head.to_bytes())
    let body_bytes = bodies.to_bytes()
    let mut position = 0
    for index in 0..<values.length() {
      let length = lengths[index]
      out.write_int_le(length)
      out.write_bytes(body_bytes[position:position + length])
      position += length
    }
  } else {
    out.write_byte(FSST_MODE_STORED.to_byte())
    out.write_int_le(values.length())
    for value in values {
      out.write_int_le(value.length())
      out.write_bytes(value)
    }
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
