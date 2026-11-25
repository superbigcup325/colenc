/// The delta family: DELTA_BINARY_PACKED (E3), DELTA_LENGTH_BYTE_ARRAY (E4)
/// and DELTA_BYTE_ARRAY (E5).
///
/// E3 layout, matching parquet-cpp:
///
///   header: block size, miniblocks per block, value count, first value
///   block:  min delta (zigzag), one byte per miniblock bit width,
///           then each miniblock's values packed at its own width
///
/// The first value is stored raw in the header and block deltas start at the
/// second value. parquet-cpp uses a block of 128 values for INT32 and 256 for
/// INT64, with four miniblocks either way; unused miniblocks of the last block
/// keep their width byte (zero) but carry no bytes. A partial miniblock is
/// zero-padded to its full size.
///
/// Values wrap on overflow (unsigned arithmetic under a signed compare), which
/// is what makes extreme int sequences work without special cases.

///|
const DELTA_BLOCK_INT32 : Int32 = 128

///|
const DELTA_BLOCK_INT64 : Int32 = 256

///|
const DELTA_MINIBLOCKS : Int32 = 4

///|
fn read_uleb(
  data : BytesView,
  pos : Int32,
) -> (UInt64, Int32) raise @types.EncodingError {
  @primitives.read_uleb128(data, offset=pos) catch {
    @primitives.PrimitivesError::Truncated(offset, need, available) =>
      raise @types.EncodingError::Truncated(offset, need, available)
    _ => raise @types.EncodingError::Truncated(pos, 1, data.length() - pos)
  }
}

///|
fn read_zigzag(
  data : BytesView,
  pos : Int32,
) -> (Int64, Int32) raise @types.EncodingError {
  @primitives.read_zigzag(data, offset=pos) catch {
    @primitives.PrimitivesError::Truncated(offset, need, available) =>
      raise @types.EncodingError::Truncated(offset, need, available)
    _ => raise @types.EncodingError::Truncated(pos, 1, data.length() - pos)
  }
}

///|
fn put_delta_header(
  out : @buffer.Buffer,
  block_size : Int32,
  count : Int32,
  first : Int64,
) -> Unit {
  @primitives.put_uleb128(out, block_size.to_uint64())
  @primitives.put_uleb128(out, DELTA_MINIBLOCKS.to_uint64())
  @primitives.put_uleb128(out, count.to_uint64())
  @primitives.put_zigzag(out, first)
}

///|
fn pack_miniblock(
  values : ArrayView[Int64],
  width : Int32,
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  @primitives.bit_pack(values, width, out) catch {
    _ => raise @types.EncodingError::InvalidBitWidth(width)
  }
}

///|
/// Encode INT64 values with DELTA_BINARY_PACKED. Empty input produces the
/// header only, as the reference does.
pub fn encode_delta_int64(
  values : ArrayView[Int64],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let count = values.length()
  let first = if count > 0 { values[0] } else { 0L }
  put_delta_header(out, DELTA_BLOCK_INT64, count, first)
  if count <= 1 {
    return
  }
  let miniblock_size = DELTA_BLOCK_INT64 / DELTA_MINIBLOCKS
  let deltas = Array::make(count - 1, 0L)
  for index in 1..<count {
    deltas[index - 1] = values[index] - values[index - 1]
  }

  let mut start = 0
  while start < deltas.length() {
    let end = if start + DELTA_BLOCK_INT64 < deltas.length() {
      start + DELTA_BLOCK_INT64
    } else {
      deltas.length()
    }
    let block = deltas[start:end]
    let mut min_delta = block[0]
    for delta in block {
      if delta < min_delta {
        min_delta = delta
      }
    }
    @primitives.put_zigzag(out, min_delta)

    let used_miniblocks = (block.length() + miniblock_size - 1) / miniblock_size
    let widths = FixedArray::make(DELTA_MINIBLOCKS, 0)
    for block_index in 0..<used_miniblocks {
      let from = block_index * miniblock_size
      let to = if from + miniblock_size < block.length() {
        from + miniblock_size
      } else {
        block.length()
      }
      let mut max_delta = block[from]
      for index in from..<to {
        if block[index] > max_delta {
          max_delta = block[index]
        }
      }
      let range = max_delta.reinterpret_as_uint64() -
        min_delta.reinterpret_as_uint64()
      widths[block_index] = @primitives.bit_width_for(range)
    }
    for block_index in 0..<DELTA_MINIBLOCKS {
      out.write_byte(widths[block_index].to_byte())
    }
    for block_index in 0..<used_miniblocks {
      let width = widths[block_index]
      let packed = Array::make(miniblock_size, 0L)
      let from = block_index * miniblock_size
      let to = if from + miniblock_size < block.length() {
        from + miniblock_size
      } else {
        block.length()
      }
      for index in from..<to {
        packed[index - from] = (block[index].reinterpret_as_uint64() -
        min_delta.reinterpret_as_uint64()).reinterpret_as_int64()
      }
      pack_miniblock(packed[:], width, out)
    }
    start = end
  }
}

///|
/// Encode INT32 values with DELTA_BINARY_PACKED (block 128, miniblocks of 32).
pub fn encode_delta_int32(
  values : ArrayView[Int32],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let count = values.length()
  let first = if count > 0 { values[0].to_int64() } else { 0L }
  put_delta_header(out, DELTA_BLOCK_INT32, count, first)
  if count <= 1 {
    return
  }
  let miniblock_size = DELTA_BLOCK_INT32 / DELTA_MINIBLOCKS
  let deltas = Array::make(count - 1, 0)
  for index in 1..<count {
    deltas[index - 1] = values[index] - values[index - 1]
  }

  let mut start = 0
  while start < deltas.length() {
    let end = if start + DELTA_BLOCK_INT32 < deltas.length() {
      start + DELTA_BLOCK_INT32
    } else {
      deltas.length()
    }
    let block = deltas[start:end]
    let mut min_delta = block[0]
    for delta in block {
      if delta < min_delta {
        min_delta = delta
      }
    }
    @primitives.put_zigzag(out, min_delta.to_int64())

    let used_miniblocks = (block.length() + miniblock_size - 1) / miniblock_size
    let widths = FixedArray::make(DELTA_MINIBLOCKS, 0)
    for block_index in 0..<used_miniblocks {
      let from = block_index * miniblock_size
      let to = if from + miniblock_size < block.length() {
        from + miniblock_size
      } else {
        block.length()
      }
      let mut max_delta = block[from]
      for index in from..<to {
        if block[index] > max_delta {
          max_delta = block[index]
        }
      }
      let range = (max_delta.to_int64() - min_delta.to_int64()) & 0xFFFF_FFFFL
      widths[block_index] = @primitives.bit_width_for(
        range.reinterpret_as_uint64(),
      )
    }
    for block_index in 0..<DELTA_MINIBLOCKS {
      out.write_byte(widths[block_index].to_byte())
    }
    for block_index in 0..<used_miniblocks {
      let width = widths[block_index]
      let packed = Array::make(miniblock_size, 0L)
      let from = block_index * miniblock_size
      let to = if from + miniblock_size < block.length() {
        from + miniblock_size
      } else {
        block.length()
      }
      for index in from..<to {
        packed[index - from] = (block[index] - min_delta).to_int64()
      }
      pack_miniblock(packed[:], width, out)
    }
    start = end
  }
}

///|
priv struct DeltaHeader {
  block_size : Int32
  miniblocks : Int32
  count : Int32
  first : Int64
}

///|
fn read_delta_header(
  data : BytesView,
  offset : Int32,
) -> (DeltaHeader, Int32) raise @types.EncodingError {
  let (block_size, a) = read_uleb(data, offset)
  let (miniblocks, b) = read_uleb(data, offset + a)
  let (count, c) = read_uleb(data, offset + a + b)
  let (first, d) = read_zigzag(data, offset + a + b + c)
  // Each field is an unsigned 64-bit varint in the format, and `to_int`
  // truncates: a header declaring 2^32 + 3 values read back as 3, so the
  // decoder reported a short stream (`have 3`) instead of refusing a header no
  // page can describe. Reject before the narrowing conversion.
  if block_size > 2147483647UL ||
    miniblocks > 2147483647UL ||
    count > 2147483647UL {
    raise @types.EncodingError::Corrupt(offset)
  }
  let header = {
    block_size: block_size.to_int(),
    miniblocks: miniblocks.to_int(),
    count: count.to_int(),
    first,
  }
  if header.block_size <= 0 ||
    header.miniblocks <= 0 ||
    header.block_size % header.miniblocks != 0 {
    raise @types.EncodingError::InvalidCount(header.block_size)
  }
  (header, a + b + c + d)
}

///|
/// Counts the miniblocks that have bodies in the block starting at `produced`.
/// The whole width table is present, but the unused entries can be arbitrary.
#inline
fn DeltaHeader::used_miniblocks(
  self : DeltaHeader,
  produced : Int32,
  miniblock_size : Int32,
) -> Int32 {
  let remaining = self.count - produced
  if remaining >= self.block_size {
    self.miniblocks
  } else {
    (remaining - 1) / miniblock_size + 1
  }
}

///|
/// Walks the blocks of a DELTA_BINARY_PACKED stream without unpacking, raising
/// the same errors the decoder would, and returns where the stream ends. A
/// second copy of the block arithmetic for the same reason `hybrid_produced` is
/// one: sharing it with the decode loop cost 4% to 7% of decode time even when
/// this pass never ran, because every miniblock then went through a call and a
/// returned struct. Only reached above `PREVALIDATE_ABOVE`, and a test decodes a
/// stream just above the threshold so the two copies cannot drift apart
/// unnoticed.
///
/// The returned position is also what the two-stream byte-array decoders use to
/// find where their second stream starts when the caller asks for fewer values
/// than the stream declares: decoding `count` values stops at the end of the
/// block that produced them, which is the end of the stream only when `count`
/// is the header's count.
fn delta_probe(
  data : BytesView,
  count : Int32,
  start : Int32,
  header : DeltaHeader,
  max_width : Int32,
) -> Int32 raise @types.EncodingError {
  let miniblock_size = header.block_size / header.miniblocks
  let miniblock_remainder = miniblock_size % 8
  let mut pos = start
  let mut produced = 1
  while produced < count {
    let (_, consumed) = read_zigzag(data, pos)
    pos += consumed
    // `pos + miniblocks` wraps for a header that declares more miniblocks than
    // the input can hold, and the width table is indexed from it.
    if header.miniblocks > data.length() - pos {
      raise @types.EncodingError::Truncated(
        pos,
        header.miniblocks,
        data.length() - pos,
      )
    }
    let widths_at = pos
    pos += header.miniblocks
    let used_miniblocks = header.used_miniblocks(produced, miniblock_size)
    for block_index in 0..<used_miniblocks {
      let width = data[widths_at + block_index].to_int()
      if width > max_width {
        raise @types.EncodingError::InvalidBitWidth(width)
      }
      // A miniblock's payload has to be a whole number of bytes: the probe
      // below charges `floor(miniblock_size * width / 8)` for it while the
      // decode loops hand that same slice to `bit_unpack`, which needs
      // `ceil(take * width / 8)`, so the two readers agree only when the
      // product is a multiple of eight. The writer pads every miniblock to its
      // full size, so a stream it produces always satisfies this; a header that
      // does not would let the probe accept a stream the decode loop then
      // refuses, and by then `Array::unsafe_make_uninit(count)` has run.
      // Checked here rather than in the header so a header the input cannot
      // hold is still diagnosed by the miniblock-count check.
      if miniblock_remainder != 0 && miniblock_remainder * width % 8 != 0 {
        raise @types.EncodingError::Corrupt(pos)
      }
      // `miniblock_size * width` wraps in `Int32` for a block size the input
      // cannot hold, so the requirement is derived in 64 bits.
      let byte_count = miniblock_size.to_int64() * width.to_int64() / 8L
      if byte_count > (data.length() - pos).to_int64() {
        let need = if byte_count > 2147483647L {
          2147483647
        } else {
          byte_count.to_int()
        }
        raise @types.EncodingError::Truncated(pos, need, data.length() - pos)
      }
      let take = if count - produced < miniblock_size {
        count - produced
      } else {
        miniblock_size
      }
      pos += byte_count.to_int()
      produced += take
    }
  }
  pos
}

///|
/// Decode DELTA_BINARY_PACKED int64 values. Returns the values and the bytes
/// consumed; the stream is read block by block, and unused miniblocks of the
/// last block carry a width byte but no data.
pub fn decode_delta_int64(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> (Array[Int64], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  let (header, header_len) = read_delta_header(data, offset)
  if count > header.count {
    raise @types.EncodingError::Incomplete(header.count, count)
  }
  if count == 0 {
    return ([], header_len)
  }
  // The output count is known before the first block is read, so the array is
  // allocated once at its final size: pushing would copy it about twice over
  // as it grew. `unsafe_make_uninit` is safe here because every slot is
  // written below (slot 0 with the header value, the rest by the block walk)
  // and a raise drops the array instead of handing it back half-filled.
  // Above the threshold the output is big enough to be worth walking the blocks
  // twice, so a stream that ends short is refused before the output exists.
  if count > @types.PREVALIDATE_ABOVE {
    ignore(delta_probe(data, count, offset + header_len, header, 64))
  }
  let values : Array[Int64] = Array::unsafe_make_uninit(count)
  values[0] = header.first
  let mut produced = 1
  let mut current = header.first
  let mut pos = offset + header_len
  let miniblock_size = header.block_size / header.miniblocks
  let miniblock_remainder = miniblock_size % 8
  while produced < count {
    let (min_delta, consumed) = read_zigzag(data, pos)
    pos += consumed
    // `pos + miniblocks` wraps for a header that declares more miniblocks than
    // the input can hold, and the width table below is sized from it.
    if header.miniblocks > data.length() - pos {
      raise @types.EncodingError::Truncated(
        pos,
        header.miniblocks,
        data.length() - pos,
      )
    }
    let used_miniblocks = header.used_miniblocks(produced, miniblock_size)
    let widths = FixedArray::make(used_miniblocks, 0)
    for index in 0..<used_miniblocks {
      widths[index] = data[pos + index].to_int()
    }
    pos += header.miniblocks
    for block_index in 0..<used_miniblocks {
      let width = widths[block_index]
      if width > 64 {
        raise @types.EncodingError::InvalidBitWidth(width)
      }
      // Same whole-byte invariant as `delta_probe`.
      if miniblock_remainder != 0 && miniblock_remainder * width % 8 != 0 {
        raise @types.EncodingError::Corrupt(pos)
      }
      // `miniblock_size * width` wraps in `Int32` for a block size the input
      // cannot hold, so the requirement is derived in 64 bits.
      let byte_count = miniblock_size.to_int64() * width.to_int64() / 8L
      if byte_count > (data.length() - pos).to_int64() {
        let need = if byte_count > 2147483647L {
          2147483647
        } else {
          byte_count.to_int()
        }
        raise @types.EncodingError::Truncated(pos, need, data.length() - pos)
      }
      // A miniblock is unpacked only as far as the caller asked for: its size
      // comes from the header, so an unclamped unpack would size an array from
      // the declared block size rather than from the value count.
      let take = if count - produced < miniblock_size {
        count - produced
      } else {
        miniblock_size
      }
      let unpacked = @primitives.bit_unpack(
        data[pos:pos + byte_count.to_int()],
        width,
        take,
        max_values~,
      ) catch {
        @primitives.PrimitivesError::Truncated(at, need, available) =>
          raise @types.EncodingError::Truncated(at, need, available)
        _ => raise @types.EncodingError::Truncated(pos, byte_count.to_int(), 0)
      }
      pos += byte_count.to_int()
      for value in unpacked {
        current = current + (min_delta + value)
        values[produced] = current
        produced += 1
      }
    }
  }
  (values, pos - offset)
}

///|
/// Decode DELTA_BINARY_PACKED int32 values.
pub fn decode_delta_int32(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> (Array[Int32], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  let (header, header_len) = read_delta_header(data, offset)
  if count > header.count {
    raise @types.EncodingError::Incomplete(header.count, count)
  }
  if count == 0 {
    return ([], header_len)
  }
  // Same as the 64-bit path: the count is known up front, so the output is
  // allocated once instead of grown by pushes.
  if count > @types.PREVALIDATE_ABOVE {
    ignore(delta_probe(data, count, offset + header_len, header, 32))
  }
  let values : Array[Int32] = Array::unsafe_make_uninit(count)
  values[0] = header.first.to_int()
  let mut produced = 1
  let mut current = header.first.to_int()
  let mut pos = offset + header_len
  let miniblock_size = header.block_size / header.miniblocks
  let miniblock_remainder = miniblock_size % 8
  while produced < count {
    let (min_delta, consumed) = read_zigzag(data, pos)
    pos += consumed
    // `pos + miniblocks` wraps for a header that declares more miniblocks than
    // the input can hold, and the width table below is sized from it.
    if header.miniblocks > data.length() - pos {
      raise @types.EncodingError::Truncated(
        pos,
        header.miniblocks,
        data.length() - pos,
      )
    }
    let used_miniblocks = header.used_miniblocks(produced, miniblock_size)
    let widths = FixedArray::make(used_miniblocks, 0)
    for index in 0..<used_miniblocks {
      widths[index] = data[pos + index].to_int()
    }
    pos += header.miniblocks
    for block_index in 0..<used_miniblocks {
      let width = widths[block_index]
      if width > 32 {
        raise @types.EncodingError::InvalidBitWidth(width)
      }
      // Same whole-byte invariant as `delta_probe`.
      if miniblock_remainder != 0 && miniblock_remainder * width % 8 != 0 {
        raise @types.EncodingError::Corrupt(pos)
      }
      // `miniblock_size * width` wraps in `Int32` for a block size the input
      // cannot hold, so the requirement is derived in 64 bits.
      let byte_count = miniblock_size.to_int64() * width.to_int64() / 8L
      if byte_count > (data.length() - pos).to_int64() {
        let need = if byte_count > 2147483647L {
          2147483647
        } else {
          byte_count.to_int()
        }
        raise @types.EncodingError::Truncated(pos, need, data.length() - pos)
      }
      // A miniblock is unpacked only as far as the caller asked for: its size
      // comes from the header, so an unclamped unpack would size an array from
      // the declared block size rather than from the value count.
      let take = if count - produced < miniblock_size {
        count - produced
      } else {
        miniblock_size
      }
      let unpacked = @primitives.bit_unpack(
        data[pos:pos + byte_count.to_int()],
        width,
        take,
        max_values~,
      ) catch {
        @primitives.PrimitivesError::Truncated(at, need, available) =>
          raise @types.EncodingError::Truncated(at, need, available)
        _ => raise @types.EncodingError::Truncated(pos, byte_count.to_int(), 0)
      }
      pos += byte_count.to_int()
      for value in unpacked {
        current = current + (min_delta.to_int() + value.to_int())
        values[produced] = current
        produced += 1
      }
    }
  }
  (values, pos - offset)
}

///|
/// DELTA_LENGTH_BYTE_ARRAY: the lengths as a delta-packed int32 stream, then
/// the concatenated value bytes.
pub fn encode_delta_length_byte_array(
  values : Array[Bytes],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let lengths = Array::makei(values.length(), fn(index) {
    values[index].length()
  })
  encode_delta_int32(lengths[:], out)
  for value in values {
    out.write_bytes(value)
  }
}

///|
/// Decode the first `count` values. The second result is the number of bytes
/// consumed from `offset`. To advance to the next page, decode all its values.
pub fn decode_delta_length_byte_array(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> (Array[Bytes], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  // The two streams are laid out end to end, so the raw bytes start where the
  // *whole* length stream ends. Decoding `count` lengths stops at the end of the
  // block that produced them, which is the end of the stream only when `count`
  // is the header's count: asking for a prefix used to read the raw bytes from
  // inside the length stream and return wrong values with no error at all.
  let (header, header_len) = read_delta_header(data, offset)
  if count > header.count {
    raise @types.EncodingError::Incomplete(header.count, count)
  }
  if count == 0 {
    return ([], header_len)
  }
  let (lengths, lengths_len) = decode_delta_int32(
    data,
    count,
    offset~,
    max_values~,
  )
  let mut values_at = if count == header.count {
    offset + lengths_len
  } else {
    delta_probe(data, header.count, offset + header_len, header, 32)
  }
  // The whole suffix stream is validated before the value array is allocated:
  // `out` is sized from the count, and with the check below inside the build
  // loop a 12-byte body that claimed the ceiling reached 200 MB before the
  // first short suffix was reported. `decode_delta_byte_array` has the same
  // shape for the same reason.
  let mut end = values_at
  for length in lengths {
    if length < 0 {
      raise @types.EncodingError::InvalidCount(length)
    }
    // `end + length` wraps for a decoded length near `Int32::max_value`, which
    // used to pass this check and hand a negative end to the slice below.
    if length > data.length() - end {
      raise @types.EncodingError::Truncated(end, length, data.length() - end)
    }
    end += length
  }
  let out : Array[Bytes] = Array::make(lengths.length(), b"")
  let mut index = 0
  for length in lengths {
    out[index] = data[values_at:values_at + length].to_owned()
    index += 1
    values_at += length
  }
  (out, end - offset)
}

///|
fn common_prefix(previous : Bytes, value : Bytes) -> Int32 {
  let limit = if previous.length() < value.length() {
    previous.length()
  } else {
    value.length()
  }
  let mut index = 0
  while index < limit && previous[index] == value[index] {
    index += 1
  }
  index
}

///|
/// DELTA_BYTE_ARRAY: prefix lengths as delta-packed int32, then the suffixes
/// as a DELTA_LENGTH_BYTE_ARRAY stream.
pub fn encode_delta_byte_array(
  values : Array[Bytes],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let prefixes = Array::make(values.length(), 0)
  let suffixes : Array[Bytes] = []
  let mut previous : Bytes = b""
  for index in 0..<values.length() {
    let value = values[index]
    let prefix = common_prefix(previous, value)
    prefixes[index] = prefix
    suffixes.push(value[prefix:value.length()].to_owned())
    previous = value
  }
  encode_delta_int32(prefixes[:], out)
  encode_delta_length_byte_array(suffixes, out)
}

///|
/// DELTA_BYTE_ARRAY: prefix lengths as delta-packed int32, then the suffixes as
/// a DELTA_LENGTH_BYTE_ARRAY stream.
///
/// The consumed byte count is relative to `offset`. To advance to the next
/// page, decode all the values in the current one.
///
/// The suffix bytes stay views into `data`: each value is allocated once at its
/// exact size and the prefix and suffix are copied straight into it. Decoding
/// the suffix stream through `decode_delta_length_byte_array` first would
/// allocate and copy every suffix only to copy it again into the value.
pub fn decode_delta_byte_array(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> (Array[Bytes], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  // Both streams are sized by the header's count, not by the caller's, so the
  // starts are computed from the declared count when the caller asks for a
  // prefix: decoding `count` values stops inside the last block it needed, and
  // that is not where the next stream begins.
  let (prefix_header, prefix_header_len) = read_delta_header(data, offset)
  if count > prefix_header.count {
    raise @types.EncodingError::Incomplete(prefix_header.count, count)
  }
  // Empty and single-value pages have no prefix blocks. Preserve the
  // consumed length of both headers for a zero-value read of either page.
  if count == 0 && prefix_header.count > 1 {
    return ([], prefix_header_len)
  }
  let (prefixes, prefix_len) = decode_delta_int32(
    data,
    count,
    offset~,
    max_values~,
  )
  let suffix_offset = if count == prefix_header.count {
    offset + prefix_len
  } else {
    delta_probe(
      data,
      prefix_header.count,
      offset + prefix_header_len,
      prefix_header,
      32,
    )
  }
  let (length_header, length_header_len) = read_delta_header(
    data, suffix_offset,
  )
  if count > length_header.count {
    raise @types.EncodingError::Incomplete(length_header.count, count)
  }
  if length_header.count != prefix_header.count {
    raise @types.EncodingError::Corrupt(suffix_offset)
  }
  let (lengths, lengths_len) = decode_delta_int32(
    data,
    count,
    offset=suffix_offset,
    max_values~,
  )
  let mut values_at = if count == length_header.count {
    suffix_offset + lengths_len
  } else {
    delta_probe(
      data,
      length_header.count,
      suffix_offset + length_header_len,
      length_header,
      32,
    )
  }
  // The whole suffix stream is validated before any value is built, so a
  // malformed length still reports the error the two-stream decoder reported
  // rather than the first prefix error the value walk would reach.
  let mut end = values_at
  for length in lengths {
    if length < 0 {
      raise @types.EncodingError::InvalidCount(length)
    }
    // `end + length` wraps for a decoded length near `Int32::max_value`.
    if length > data.length() - end {
      raise @types.EncodingError::Truncated(end, length, data.length() - end)
    }
    end += length
  }
  let values : Array[Bytes] = Array::make(count, b"")
  let mut previous : Bytes = b""
  for index in 0..<count {
    let prefix = prefixes[index]
    if prefix < 0 || prefix > previous.length() {
      raise @types.EncodingError::InvalidIndex(prefix, previous.length())
    }
    let length = lengths[index]
    let body : FixedArray[Byte] = FixedArray::make(prefix + length, b'\x00')
    body.blit_from_bytesview(0, previous[0:prefix])
    body.blit_from_bytesview(prefix, data[values_at:values_at + length])
    let value = body.unsafe_reinterpret_as_bytes()
    values[index] = value
    previous = value
    values_at += length
  }
  (values, end - offset)
}
