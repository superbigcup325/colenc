/// Bit packing and unpacking, LSB first, contiguous with no padding.
///
/// The packed stream is the one Parquet's bit-packed runs use inside a run:
/// value zero occupies the lowest bits of the first byte, and values continue
/// across byte boundaries without gaps. Group padding (multiples of eight
/// values per RLE run) is the RLE encoder's job, not this layer's.

///|
/// Number of bits needed to represent `max_value`: `ceil(log2(max + 1))`, and
/// zero for zero.
pub fn bit_width_for(max_value : UInt64) -> Int32 {
  if max_value == 0UL {
    0
  } else {
    64 - max_value.clz()
  }
}

///|
/// Append `values` at `bit_width` bits each, LSB first.
///
/// Values are masked to `bit_width`: bits above the width are dropped, so a
/// caller that mis-derived the width gets truncated values rather than a
/// corrupt stream. Encoding never fails on the data itself.
pub fn bit_pack(
  values : ArrayView[Int64],
  bit_width : Int32,
  out : @buffer.Buffer,
) -> Unit raise PrimitivesError {
  if bit_width < 0 || bit_width > 64 {
    raise InvalidBitWidth(bit_width)
  }
  if bit_width == 0 {
    return
  }
  let mut pending = 0UL
  let mut filled = 0
  for value in values {
    let mut rest = value.reinterpret_as_uint64()
    let mut remaining = bit_width
    while remaining > 0 {
      let free = 8 - filled
      let take = if free < remaining { free } else { remaining }
      let mask = (1UL << take) - 1UL
      pending = pending | ((rest & mask) << filled)
      rest = rest >> take
      filled += take
      remaining -= take
      if filled == 8 {
        out.write_byte(pending.to_int().to_byte())
        pending = 0UL
        filled = 0
      }
    }
  }
  if filled > 0 {
    out.write_byte(pending.to_int().to_byte())
  }
}

///|
/// Read `count` values of `bit_width` bits each from the start of `data`,
/// LSB first. The input may be longer than needed; trailing bytes are ignored.
pub fn bit_unpack(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
) -> Array[Int64] raise PrimitivesError {
  if bit_width < 0 || bit_width > 64 {
    raise InvalidBitWidth(bit_width)
  }
  if count < 0 {
    raise InvalidCount(count)
  }
  let need = (bit_width * count + 7) / 8
  if need > data.length() {
    raise Truncated(0, need, data.length())
  }
  let out = Array::make(count, 0L)
  let mut bit_pos = 0
  for index in 0..<count {
    let mut acc = 0UL
    let mut got = 0
    while got < bit_width {
      let byte_index = bit_pos >> 3
      let bit_in_byte = bit_pos & 7
      let free = 8 - bit_in_byte
      let missing = bit_width - got
      let take = if free < missing { free } else { missing }
      let mask = (1 << take) - 1
      let part = (data[byte_index].to_int() >> bit_in_byte) & mask
      acc = acc | (part.to_uint64() << got)
      got += take
      bit_pos += take
    }
    out[index] = acc.reinterpret_as_int64()
  }
  out
}
