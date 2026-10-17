/// PLAIN encoding: fixed-width little-endian values, length-prefixed byte
/// arrays, and bit-packed booleans. This is the encoding every Parquet reader
/// must support, and the baseline the other families are measured against.

///|
/// Read a 32-bit little-endian integer. Callers check the bounds first.
fn read_u32_le(data : BytesView, offset : Int32) -> Int32 {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// Read a 64-bit little-endian bit pattern. Callers check the bounds first.
fn read_u64_le(data : BytesView, offset : Int32) -> UInt64 {
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (data[offset + index].to_int().to_uint64() << (index * 8))
  }
  value
}

///|
pub fn encode_int32(values : Array[Int32], out : @buffer.Buffer) -> Unit {
  for value in values {
    out.write_int_le(value)
  }
}

///|
pub fn encode_int64(values : Array[Int64], out : @buffer.Buffer) -> Unit {
  for value in values {
    out.write_int64_le(value)
  }
}

///|
pub fn encode_float(values : Array[Float], out : @buffer.Buffer) -> Unit {
  for value in values {
    out.write_float_le(value)
  }
}

///|
pub fn encode_double(values : Array[Double], out : @buffer.Buffer) -> Unit {
  for value in values {
    out.write_double_le(value)
  }
}

///|
/// BYTE_ARRAY: a 4-byte little-endian length followed by the raw bytes, per
/// value. No UTF-8 validation: a byte array is bytes.
pub fn encode_byte_arrays(values : Array[Bytes], out : @buffer.Buffer) -> Unit {
  for value in values {
    out.write_int_le(value.length())
    out.write_bytes(value)
  }
}

///|
/// BOOLEAN: bit-packed, LSB first, eight values per byte. The unused high bits
/// of the last byte stay zero.
pub fn encode_bool(values : Array[Bool], out : @buffer.Buffer) -> Unit {
  let mut byte = 0
  let mut bit = 0
  for value in values {
    if value {
      byte = byte | (1 << bit)
    }
    bit += 1
    if bit == 8 {
      out.write_byte(byte.to_byte())
      byte = 0
      bit = 0
    }
  }
  if bit > 0 {
    out.write_byte(byte.to_byte())
  }
}

///|
pub fn decode_int32(
  data : BytesView,
  count : Int32,
) -> Array[Int32] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let need = count * 4
  if need > data.length() {
    raise @types.EncodingError::Truncated(0, need, data.length())
  }
  let out = Array::make(count, 0)
  for index in 0..<count {
    out[index] = read_u32_le(data, index * 4)
  }
  out
}

///|
pub fn decode_int64(
  data : BytesView,
  count : Int32,
) -> Array[Int64] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let need = count * 8
  if need > data.length() {
    raise @types.EncodingError::Truncated(0, need, data.length())
  }
  let out = Array::make(count, 0L)
  for index in 0..<count {
    out[index] = read_u64_le(data, index * 8).reinterpret_as_int64()
  }
  out
}

///|
pub fn decode_float(
  data : BytesView,
  count : Int32,
) -> Array[Float] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let need = count * 4
  if need > data.length() {
    raise @types.EncodingError::Truncated(0, need, data.length())
  }
  let out = Array::make(count, Float(0.0))
  for index in 0..<count {
    out[index] = Float::reinterpret_from_int(read_u32_le(data, index * 4))
  }
  out
}

///|
pub fn decode_double(
  data : BytesView,
  count : Int32,
) -> Array[Double] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let need = count * 8
  if need > data.length() {
    raise @types.EncodingError::Truncated(0, need, data.length())
  }
  let out = Array::make(count, 0.0)
  for index in 0..<count {
    out[index] = read_u64_le(data, index * 8).reinterpret_as_double()
  }
  out
}

///|
pub fn decode_byte_arrays(
  data : BytesView,
  count : Int32,
) -> Array[Bytes] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let out : Array[Bytes] = []
  let mut offset = 0
  for _ in 0..<count {
    if offset + 4 > data.length() {
      raise @types.EncodingError::Truncated(offset, 4, data.length() - offset)
    }
    let length = read_u32_le(data, offset)
    offset += 4
    if length < 0 {
      raise @types.EncodingError::InvalidCount(length)
    }
    if offset + length > data.length() {
      raise @types.EncodingError::Truncated(
        offset,
        length,
        data.length() - offset,
      )
    }
    out.push(data[offset:offset + length].to_owned())
    offset += length
  }
  out
}

///|
pub fn decode_bool(
  data : BytesView,
  count : Int32,
) -> Array[Bool] raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let need = (count + 7) / 8
  if need > data.length() {
    raise @types.EncodingError::Truncated(0, need, data.length())
  }
  let out = Array::make(count, false)
  for index in 0..<count {
    out[index] = ((data[index >> 3].to_int() >> (index & 7)) & 1) == 1
  }
  out
}
