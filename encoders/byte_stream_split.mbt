/// BYTE_STREAM_SPLIT (E6): instead of interleaving each value's bytes, every
/// byte position gets its own plane. For little-endian floats the result is
/// four planes (eight for doubles), which puts the exponent bytes and the
/// mantissa bytes next to their peers and makes the stream far more
/// byte-stream-friendly to compress afterwards.
///
/// Plane `j` holds byte `j` of every value in order, so the stride inside a
/// plane is the value count.

///|
pub fn encode_byte_stream_split_float(
  values : Array[Float],
  out : @buffer.Buffer,
) -> Unit {
  for plane in 0..<4 {
    for value in values {
      let bits = value.reinterpret_as_int()
      out.write_byte(((bits >> (plane * 8)) & 0xFF).to_byte())
    }
  }
}

///|
pub fn encode_byte_stream_split_double(
  values : Array[Double],
  out : @buffer.Buffer,
) -> Unit {
  for plane in 0..<8 {
    for value in values {
      let bits = value.reinterpret_as_uint64()
      out.write_byte(((bits >> (plane * 8)).to_int() & 0xFF).to_byte())
    }
  }
}

///|
pub fn decode_byte_stream_split_float(
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
    let mut bits = 0
    for plane in 0..<4 {
      bits = bits | (data[plane * count + index].to_int() << (plane * 8))
    }
    out[index] = Float::reinterpret_from_int(bits)
  }
  out
}

///|
pub fn decode_byte_stream_split_double(
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
    let mut bits = 0UL
    for plane in 0..<8 {
      bits = bits |
        (data[plane * count + index].to_int().to_uint64() << (plane * 8))
    }
    out[index] = bits.reinterpret_as_double()
  }
  out
}
