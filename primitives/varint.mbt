/// Unsigned LEB128 and zigzag varints, as the Parquet encodings use them.

///|
/// Append `value` as an unsigned LEB128 varint, seven bits per byte, low bits
/// first.
pub fn put_uleb128(out : @buffer.Buffer, value : UInt64) -> Unit {
  let mut rest = value
  while rest >= 0x80UL {
    out.write_byte(((rest.to_int() & 0x7F) | 0x80).to_byte())
    rest = rest >> 7
  }
  out.write_byte(rest.to_int().to_byte())
}

///|
/// Append a signed value as a zigzag varint: the magnitude doubled, with the
/// low bit carrying the sign.
pub fn put_zigzag(out : @buffer.Buffer, value : Int64) -> Unit {
  let zigzag = (value << 1) ^ (value >> 63)
  put_uleb128(out, zigzag.reinterpret_as_uint64())
}

///|
/// Read an unsigned LEB128 varint at `offset`; returns the value and how many
/// bytes it occupied. More than ten bytes, or a tenth byte with bits above
/// bit 63, is rejected rather than silently wrapped.
pub fn read_uleb128(
  data : BytesView,
  offset~ : Int32 = 0,
) -> (UInt64, Int32) raise PrimitivesError {
  if offset < 0 || offset >= data.length() {
    raise Truncated(offset, 1, 0)
  }
  let mut pos = offset
  let mut shift = 0
  let mut result = 0UL
  let mut more = true
  while more {
    if pos >= data.length() {
      raise Truncated(pos, 1, data.length() - offset)
    }
    let byte = data[pos].to_int()
    pos += 1
    if shift == 63 && (byte & 0x7E) != 0 {
      raise InvalidVarint(offset)
    }
    result = result | ((byte & 0x7F).to_uint64() << shift)
    if (byte & 0x80) == 0 {
      more = false
    } else {
      shift += 7
      if shift >= 70 {
        raise InvalidVarint(offset)
      }
    }
  }
  (result, pos - offset)
}

///|
/// Read a zigzag varint at `offset`; returns the signed value and the byte
/// count.
pub fn read_zigzag(
  data : BytesView,
  offset~ : Int32 = 0,
) -> (Int64, Int32) raise PrimitivesError {
  let (raw, consumed) = read_uleb128(data, offset~)
  let magnitude = raw >> 1
  let sign_mask = 0UL - (raw & 1UL)
  ((magnitude ^ sign_mask).reinterpret_as_int64(), consumed)
}

///|
/// Zigzag-map a signed value onto the unsigned range. Exposed for tests and
/// for callers that need the mapped value without writing a varint.
pub fn zigzag_encode(value : Int64) -> UInt64 {
  ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
}

///|
/// Inverse of `zigzag_encode`.
pub fn zigzag_decode(value : UInt64) -> Int64 {
  ((value >> 1) ^ (0UL - (value & 1UL))).reinterpret_as_int64()
}
