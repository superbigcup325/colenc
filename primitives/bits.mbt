/// Bit packing and unpacking, LSB first, contiguous with no padding.
///
/// The packed stream is the one Parquet's bit-packed runs use inside a run:
/// value zero occupies the lowest bits of the first byte, and values continue
/// across byte boundaries without gaps. Group padding (multiples of eight
/// values per RLE run) is the RLE encoder's job, not this layer's.
///
/// Both directions accumulate into a 64-bit word and move whole bytes, which is
/// what makes them fast; the number of bytes moved per step is chosen so the
/// word can never overflow:
///
/// - widths 1..32 flush four bytes at a time (four bytes leave fewer than
///   thirty-two bits pending, and thirty-two plus thirty-two still fits)
/// - widths 33..56 flush three, two or one bytes so that the pending count plus
///   the width stays under sixty-four
/// - widths 57..63 have no whole-byte stride that fits, and width 64 has no
///   carry to move, so those two ranges use dedicated paths
///
/// The choice is invisible in the output: every lane produces the same bytes as
/// the bit-at-a-time reference, which the byte diffs against parquet-cpp keep
/// honest.

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
  if bit_width <= 32 {
    pack_words(values, bit_width, 4, out)
  } else if bit_width <= 40 {
    pack_words(values, bit_width, 3, out)
  } else if bit_width <= 48 {
    pack_words(values, bit_width, 2, out)
  } else if bit_width <= 56 {
    pack_words(values, bit_width, 1, out)
  } else if bit_width == 64 {
    for value in values {
      out.write_int64_le(value)
    }
  } else {
    pack_bits(values, bit_width, out)
  }
}

///|
/// The word-accumulating packer. `flush_bytes` is one, two, three or four, and
/// the caller guarantees `bit_width <= 64 - flush_bytes * 8` so that adding one
/// value to a word holding fewer than `flush_bytes * 8` bits cannot overflow.
fn pack_words(
  values : ArrayView[Int64],
  bit_width : Int32,
  flush_bytes : Int32,
  out : @buffer.Buffer,
) -> Unit {
  let mask = (1UL << bit_width) - 1UL
  let flush_bits = flush_bytes * 8
  let mut pending = 0UL
  let mut filled = 0
  for value in values {
    pending = pending | ((value.reinterpret_as_uint64() & mask) << filled)
    filled += bit_width
    while filled >= flush_bits {
      if flush_bytes == 4 {
        out.write_int_le((pending & 0xFFFFFFFFUL).to_int())
      } else if flush_bytes == 3 {
        out.write_uint16_le((pending & 0xFFFFUL).to_uint16())
        out.write_byte(((pending >> 16) & 0xFFUL).to_int().to_byte())
      } else if flush_bytes == 2 {
        out.write_uint16_le((pending & 0xFFFFUL).to_uint16())
      } else {
        out.write_byte((pending & 0xFFUL).to_int().to_byte())
      }
      pending = pending >> flush_bits
      filled -= flush_bits
    }
  }
  while filled >= 8 {
    out.write_byte((pending & 0xFFUL).to_int().to_byte())
    pending = pending >> 8
    filled -= 8
  }
  if filled > 0 {
    out.write_byte((pending & 0xFFUL).to_int().to_byte())
  }
}

///|
/// The bit-at-a-time packer for widths 57..63, where no whole-byte stride keeps
/// the pending word under sixty-four bits. Same output, slower; the range only
/// shows up on hand-built streams because no encoder in this library derives a
/// width above 32 except for 64-bit deltas.
fn pack_bits(
  values : ArrayView[Int64],
  bit_width : Int32,
  out : @buffer.Buffer,
) -> Unit {
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
  if bit_width == 0 {
    return Array::make(count, 0L)
  }
  if bit_width <= 56 {
    unpack_words(data, bit_width, count)
  } else if bit_width == 64 {
    unpack_full_words(data, count)
  } else {
    unpack_bits(data, bit_width, count)
  }
}

///|
/// The word-accumulating unpacker: refill one byte at a time, shift out
/// `bit_width` bits per value. The refill loop reads at most
/// `ceil(bit_width * count / 8)` bytes, which the caller has already checked, so
/// the reads stay in bounds for every input the length check admits.
fn unpack_words(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
) -> Array[Int64] {
  let out = Array::make(count, 0L)
  let mask = (1UL << bit_width) - 1UL
  let mut buffer = 0UL
  let mut bits = 0
  let mut position = 0
  for index in 0..<count {
    while bits < bit_width {
      buffer = buffer | (data[position].to_uint64() << bits)
      position += 1
      bits += 8
    }
    out[index] = (buffer & mask).reinterpret_as_int64()
    buffer = buffer >> bit_width
    bits -= bit_width
  }
  out
}

///|
/// Width 64 has no bits to carry: eight bytes per value, little endian.
fn unpack_full_words(data : BytesView, count : Int32) -> Array[Int64] {
  let out = Array::make(count, 0L)
  for index in 0..<count {
    let mut value = 0UL
    let base = index * 8
    for byte in 0..<8 {
      value = value | (data[base + byte].to_uint64() << (byte * 8))
    }
    out[index] = value.reinterpret_as_int64()
  }
  out
}

///|
/// The bit-at-a-time unpacker, the mirror of `pack_bits` for widths 57..63.
fn unpack_bits(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
) -> Array[Int64] {
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
