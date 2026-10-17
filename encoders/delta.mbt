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
/// Decode DELTA_BINARY_PACKED int64 values. Returns the values and the bytes
/// consumed; the stream is read block by block, and unused miniblocks of the
/// last block carry a width byte but no data.
pub fn decode_delta_int64(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
) -> (Array[Int64], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let (header, header_len) = read_delta_header(data, offset)
  if count > header.count {
    raise @types.EncodingError::Incomplete(header.count, count)
  }
  let values : Array[Int64] = []
  if count == 0 {
    return (values, header_len)
  }
  values.push(header.first)
  let mut produced = 1
  let mut current = header.first
  let mut pos = offset + header_len
  let miniblock_size = header.block_size / header.miniblocks
  while produced < count {
    let (min_delta, consumed) = read_zigzag(data, pos)
    pos += consumed
    if pos + header.miniblocks > data.length() {
      raise @types.EncodingError::Truncated(
        pos,
        header.miniblocks,
        data.length() - pos,
      )
    }
    let widths = FixedArray::make(header.miniblocks, 0)
    for index in 0..<header.miniblocks {
      widths[index] = data[pos + index].to_int()
    }
    pos += header.miniblocks
    for block_index in 0..<header.miniblocks {
      let width = widths[block_index]
      if width > 64 {
        raise @types.EncodingError::InvalidBitWidth(width)
      }
      let byte_count = miniblock_size * width / 8
      if pos + byte_count > data.length() {
        raise @types.EncodingError::Truncated(
          pos,
          byte_count,
          data.length() - pos,
        )
      }
      let unpacked = @primitives.bit_unpack(
        data[pos:pos + byte_count],
        width,
        miniblock_size,
      ) catch {
        @primitives.PrimitivesError::Truncated(at, need, available) =>
          raise @types.EncodingError::Truncated(at, need, available)
        _ => raise @types.EncodingError::Truncated(pos, byte_count, 0)
      }
      pos += byte_count
      for value in unpacked {
        if produced < count {
          current = current + (min_delta + value)
          values.push(current)
          produced += 1
        }
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
) -> (Array[Int32], Int32) raise @types.EncodingError {
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  let (header, header_len) = read_delta_header(data, offset)
  if count > header.count {
    raise @types.EncodingError::Incomplete(header.count, count)
  }
  let values : Array[Int32] = []
  if count == 0 {
    return (values, header_len)
  }
  values.push(header.first.to_int())
  let mut produced = 1
  let mut current = header.first.to_int()
  let mut pos = offset + header_len
  let miniblock_size = header.block_size / header.miniblocks
  while produced < count {
    let (min_delta, consumed) = read_zigzag(data, pos)
    pos += consumed
    if pos + header.miniblocks > data.length() {
      raise @types.EncodingError::Truncated(
        pos,
        header.miniblocks,
        data.length() - pos,
      )
    }
    let widths = FixedArray::make(header.miniblocks, 0)
    for index in 0..<header.miniblocks {
      widths[index] = data[pos + index].to_int()
    }
    pos += header.miniblocks
    for block_index in 0..<header.miniblocks {
      let width = widths[block_index]
      if width > 32 {
        raise @types.EncodingError::InvalidBitWidth(width)
      }
      let byte_count = miniblock_size * width / 8
      if pos + byte_count > data.length() {
        raise @types.EncodingError::Truncated(
          pos,
          byte_count,
          data.length() - pos,
        )
      }
      let unpacked = @primitives.bit_unpack(
        data[pos:pos + byte_count],
        width,
        miniblock_size,
      ) catch {
        @primitives.PrimitivesError::Truncated(at, need, available) =>
          raise @types.EncodingError::Truncated(at, need, available)
        _ => raise @types.EncodingError::Truncated(pos, byte_count, 0)
      }
      pos += byte_count
      for value in unpacked {
        if produced < count {
          current = current + (min_delta.to_int() + value.to_int())
          values.push(current)
          produced += 1
        }
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
pub fn decode_delta_length_byte_array(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
) -> (Array[Bytes], Int32) raise @types.EncodingError {
  let (lengths, lengths_len) = decode_delta_int32(data, count, offset~)
  let out : Array[Bytes] = []
  let mut pos = offset + lengths_len
  for length in lengths {
    if length < 0 {
      raise @types.EncodingError::InvalidCount(length)
    }
    if pos + length > data.length() {
      raise @types.EncodingError::Truncated(pos, length, data.length() - pos)
    }
    out.push(data[pos:pos + length].to_owned())
    pos += length
  }
  (out, pos - offset)
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
pub fn decode_delta_byte_array(
  data : BytesView,
  count : Int32,
  offset~ : Int32 = 0,
) -> (Array[Bytes], Int32) raise @types.EncodingError {
  let (prefixes, prefix_len) = decode_delta_int32(data, count, offset~)
  let (suffixes, suffix_len) = decode_delta_length_byte_array(
    data,
    count,
    offset=offset + prefix_len,
  )
  let values : Array[Bytes] = []
  let mut previous : Bytes = b""
  for index in 0..<count {
    let prefix = prefixes[index]
    if prefix < 0 || prefix > previous.length() {
      raise @types.EncodingError::InvalidIndex(prefix, previous.length())
    }
    let buffer = Buffer()
    buffer.write_bytes(previous[0:prefix])
    buffer.write_bytes(suffixes[index])
    let value = buffer.to_bytes()
    values.push(value)
    previous = value
  }
  (values, prefix_len + suffix_len)
}
