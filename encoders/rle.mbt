/// The RLE / bit-packed hybrid: runs of equal values become repeated runs,
/// everything else accumulates into literal runs of eight-value groups.
///
/// The run-selection heuristic follows parquet-cpp's `RleBitPackedEncoder`
/// exactly, because byte-identical output is the acceptance criterion. The
/// rules that matter:
///
/// - values are buffered eight at a time; a buffer flush decides the run type
/// - a run of eight identical values switches to repeated-run mode; further
///   values join it without buffering
/// - a literal run holds at most 63 groups (504 values); the 64th group forces
///   the current literal run out
/// - at the end, if nothing but a single repeat is pending it becomes a
///   repeated run, otherwise the last group is zero-padded to eight
///
/// A literal run is `varint(groups << 1 | 1)` followed by groups of eight
/// values packed LSB first. A repeated run is `varint(count << 1)` followed by
/// the value in `ceil(bit_width / 8)` little-endian bytes.

///|
/// Encoder state, mirroring the reference implementation field for field.
priv struct RleEncoderState {
  bit_width : Int32
  out : @buffer.Buffer
  /// Pending literal values, preallocated: a literal run is capped at 63 groups
  /// (504 values) by the one-byte indicator, so the buffer never needs to grow.
  literal : Array[Int64]
  mut literal_count : Int32
  buffered : FixedArray[Int64]
  mut buffered_count : Int32
  mut current : Int64
  mut repeat_count : Int32
}

///|
fn RleEncoderState::new(bit_width : Int32, out : @buffer.Buffer) -> Self {
  {
    bit_width,
    out,
    literal: Array::make(512, 0L),
    literal_count: 0,
    buffered: FixedArray::make(8, 0L),
    buffered_count: 0,
    current: 0L,
    repeat_count: 0,
  }
}

///|
fn RleEncoderState::put(
  self : RleEncoderState,
  value : Int64,
) -> Unit raise @types.EncodingError {
  if self.current == value {
    self.repeat_count += 1
    if self.repeat_count > 8 {
      // continuation of a repeated run: nothing to buffer
      return
    }
  } else {
    if self.repeat_count >= 8 {
      self.flush_repeated()
    }
    self.repeat_count = 1
    self.current = value
  }
  self.buffered[self.buffered_count] = value
  self.buffered_count += 1
  if self.buffered_count == 8 {
    self.flush_buffered()
  }
}

///|
fn RleEncoderState::flush_literal(
  self : RleEncoderState,
) -> Unit raise @types.EncodingError {
  let groups = self.literal_count / 8
  self.out.write_byte(((groups << 1) | 1).to_byte())
  @primitives.bit_pack(
    self.literal[:self.literal_count],
    self.bit_width,
    self.out,
  ) catch {
    _ => raise @types.EncodingError::InvalidBitWidth(self.bit_width)
  }
  self.literal_count = 0
}

///|
fn RleEncoderState::flush_repeated(self : RleEncoderState) -> Unit {
  @primitives.put_uleb128(self.out, (self.repeat_count << 1).to_uint64())
  let value_bytes = (self.bit_width + 7) / 8
  let value = self.current.reinterpret_as_uint64()
  for index in 0..<value_bytes {
    self.out.write_byte((value >> (index * 8)).to_int().to_byte())
  }
  self.buffered_count = 0
  self.repeat_count = 0
}

///|
fn RleEncoderState::flush_buffered(
  self : RleEncoderState,
) -> Unit raise @types.EncodingError {
  if self.repeat_count >= 8 {
    // the buffered values are the first eight of a repeated run
    self.buffered_count = 0
    if self.literal_count > 0 {
      self.flush_literal()
    }
    return
  }
  for index in 0..<self.buffered_count {
    self.literal[self.literal_count] = self.buffered[index]
    self.literal_count += 1
  }
  self.buffered_count = 0
  let groups = self.literal_count / 8
  if groups + 1 >= 64 {
    // the one-byte indicator cannot describe another group
    self.flush_literal()
  }
  self.repeat_count = 0
}

///|
fn RleEncoderState::finish(
  self : RleEncoderState,
) -> Unit raise @types.EncodingError {
  if self.literal_count > 0 || self.repeat_count > 0 || self.buffered_count > 0 {
    let all_repeat = self.literal_count == 0 &&
      (self.repeat_count == self.buffered_count || self.buffered_count == 0)
    if self.repeat_count > 0 && all_repeat {
      self.flush_repeated()
    } else {
      while self.buffered_count > 0 && self.buffered_count < 8 {
        self.buffered[self.buffered_count] = 0L
        self.buffered_count += 1
      }
      for index in 0..<self.buffered_count {
        self.literal[self.literal_count] = self.buffered[index]
        self.literal_count += 1
      }
      self.buffered_count = 0
      self.flush_literal()
      self.repeat_count = 0
    }
  }
}

///|
/// Append the hybrid stream for `values` at `bit_width` bits each.
pub fn encode_rle_hybrid(
  values : ArrayView[Int64],
  bit_width : Int32,
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  if bit_width < 0 || bit_width > 64 {
    raise @types.EncodingError::InvalidBitWidth(bit_width)
  }
  let state = RleEncoderState::new(bit_width, out)
  for value in values {
    state.put(value)
  }
  state.finish()
}

///|
/// Read a hybrid stream until `count` values are produced or the input ends.
/// Returns the values and how many bytes the runs occupied.
pub fn decode_rle_hybrid(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
  offset~ : Int32 = 0,
) -> (Array[Int64], Int32) raise @types.EncodingError {
  if bit_width < 0 || bit_width > 64 {
    raise @types.EncodingError::InvalidBitWidth(bit_width)
  }
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if offset < 0 || offset > data.length() {
    raise @types.EncodingError::Truncated(offset, 1, 0)
  }
  let out : Array[Int64] = []
  let mut pos = offset
  while out.length() < count && pos < data.length() {
    let (header, consumed) = @primitives.read_uleb128(data, offset=pos) catch {
      @primitives.PrimitivesError::Truncated(at, need, available) =>
        raise @types.EncodingError::Truncated(at, need, available)
      _ => raise @types.EncodingError::Truncated(pos, 1, data.length() - pos)
    }
    pos += consumed
    if (header & 1UL) == 1UL {
      let groups = (header >> 1).to_int()
      let produced = groups * 8
      let byte_count = groups * bit_width
      if pos + byte_count > data.length() {
        raise @types.EncodingError::Truncated(
          pos,
          byte_count,
          data.length() - pos,
        )
      }
      let values = @primitives.bit_unpack(
        data[pos:pos + byte_count],
        bit_width,
        produced,
      ) catch {
        @primitives.PrimitivesError::Truncated(at, need, available) =>
          raise @types.EncodingError::Truncated(at, need, available)
        _ => raise @types.EncodingError::Truncated(pos, byte_count, 0)
      }
      pos += byte_count
      let take = if count - out.length() < produced {
        count - out.length()
      } else {
        produced
      }
      for index in 0..<take {
        out.push(values[index])
      }
    } else {
      let repeats = (header >> 1).to_int()
      let byte_count = (bit_width + 7) / 8
      if pos + byte_count > data.length() {
        raise @types.EncodingError::Truncated(
          pos,
          byte_count,
          data.length() - pos,
        )
      }
      let mut value = 0UL
      for index in 0..<byte_count {
        value = value | (data[pos + index].to_int().to_uint64() << (index * 8))
      }
      pos += byte_count
      let take = if count - out.length() < repeats {
        count - out.length()
      } else {
        repeats
      }
      for _ in 0..<take {
        out.push(value.reinterpret_as_int64())
      }
    }
  }
  if out.length() < count {
    raise @types.EncodingError::Incomplete(out.length(), count)
  }
  (out, pos - offset)
}

///|
/// Boolean values use the same hybrid stream at bit width 1, prefixed by the
/// encoded length as a 4-byte little-endian integer, per the Parquet spec for
/// RLE-encoded boolean data pages.
pub fn encode_bool_rle(
  values : Array[Bool],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let stream = Buffer()
  let state = RleEncoderState::new(1, stream)
  for value in values {
    state.put(if value { 1L } else { 0L })
  }
  state.finish()
  let bytes = stream.to_bytes()
  out.write_int_le(bytes.length())
  out.write_bytes(bytes)
}

///|
pub fn decode_bool_rle(
  data : BytesView,
  count : Int32,
) -> Array[Bool] raise @types.EncodingError {
  if data.length() < 4 {
    raise @types.EncodingError::Truncated(0, 4, data.length())
  }
  let length = read_u32_le(data, 0)
  if length < 0 {
    raise @types.EncodingError::InvalidCount(length)
  }
  if 4 + length > data.length() {
    raise @types.EncodingError::Truncated(4, length, data.length() - 4)
  }
  let (values, _) = decode_rle_hybrid(data[4:4 + length], 1, count)
  Array::makei(count, fn(index) { values[index] != 0L })
}
