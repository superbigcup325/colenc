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
/// One run of a hybrid stream: a literal run of at most 504 unpacked values, or
/// a value repeated some number of times. A caller that only needs the values
/// can ignore the split; the dictionary decoder uses it to write straight into
/// its own output instead of building a whole index array first.
priv enum HybridRun {
  Literals(Array[Int64], Int32)
  Repeat(Int64, Int32)
}

///|
/// Walks a hybrid stream run by run. `filled` counts the values handed out so
/// far, which is what stops the walk at the same point `decode_rle_hybrid`
/// stops and keeps its consumed length.
priv struct HybridWalk {
  data : BytesView
  bit_width : Int32
  count : Int32
  /// The ceiling the caller gave, carried through so the per-run unpack inside
  /// `next` judges its own count against the same limit. Without it the
  /// primitive's default would refuse a run a caller had explicitly raised the
  /// ceiling for, and the catch below would report that as a truncated stream.
  max_values : Int32
  mut pos : Int32
  mut filled : Int32
}

///|
/// Validates the arguments the same way `decode_rle_hybrid` does, so a caller
/// that walks the stream itself reports the same errors in the same order.
fn hybrid_walk(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
  offset : Int32,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> HybridWalk raise @types.EncodingError {
  if bit_width < 0 || bit_width > 64 {
    raise @types.EncodingError::InvalidBitWidth(bit_width)
  }
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  if offset < 0 || offset > data.length() {
    raise @types.EncodingError::Truncated(offset, 1, 0)
  }
  { data, bit_width, count, max_values, pos: offset, filled: 0, }
}

///|
/// The next run, or `None` when the walk has produced `count` values or reached
/// the end of the input.
fn HybridWalk::next(self : HybridWalk) -> HybridRun? raise @types.EncodingError {
  if self.filled >= self.count || self.pos >= self.data.length() {
    return None
  }
  let data = self.data
  let (header, consumed) = @primitives.read_uleb128(data, offset=self.pos) catch {
    @primitives.PrimitivesError::Truncated(at, need, available) =>
      raise @types.EncodingError::Truncated(at, need, available)
    _ =>
      raise @types.EncodingError::Truncated(
        self.pos,
        1,
        data.length() - self.pos,
      )
  }
  self.pos += consumed
  if (header & 1UL) == 1UL {
    // `groups * 8` and `groups * bit_width` wrap in `Int32`, and a wrapped
    // negative byte count used to pass the length check and reach the slice.
    // Both are derived in 64 bits and compared against what is left first.
    let groups = (header >> 1).reinterpret_as_int64()
    if groups > 268435455L {
      // 2^28 - 1 groups is already 2^31 - 8 values: no page can ask for it, so
      // no input can satisfy the run. That is a structural violation, not a
      // short stream, and it answers `Corrupt` like the repeat guard below --
      // reporting `Truncated(need = 2^31 - 1)` invited a caller to read it as
      // "fetch more bytes", and put a value count in a byte-count field.
      raise @types.EncodingError::Corrupt(self.pos)
    }
    let produced = (groups * 8L).to_int()
    let byte_count = groups * self.bit_width.to_int64()
    if byte_count > (data.length() - self.pos).to_int64() {
      let need = if byte_count > 2147483647L {
        2147483647
      } else {
        byte_count.to_int()
      }
      raise @types.EncodingError::Truncated(
        self.pos,
        need,
        data.length() - self.pos,
      )
    }
    let take = if self.count - self.filled < produced {
      self.count - self.filled
    } else {
      produced
    }
    // Only the values the caller asked for are unpacked. At bit width zero a
    // run carries no bytes at all, so its declared length is otherwise an
    // unbounded allocation for a stream of a few bytes.
    let values = @primitives.bit_unpack(
      data[self.pos:self.pos + byte_count.to_int()],
      self.bit_width,
      take,
      max_values=self.max_values,
    ) catch {
      @primitives.PrimitivesError::Truncated(at, need, available) =>
        raise @types.EncodingError::Truncated(at, need, available)
      _ =>
        raise @types.EncodingError::Truncated(self.pos, byte_count.to_int(), 0)
    }
    self.pos += byte_count.to_int()
    self.filled += take
    Some(HybridRun::Literals(values, take))
  } else {
    // A repeat count above `Int32` max cannot describe a page, and the
    // truncating conversion would silently decode a shorter run instead of
    // reporting the malformed header.
    let repeats = (header >> 1).reinterpret_as_int64()
    if repeats > 2147483647L {
      raise @types.EncodingError::Corrupt(self.pos)
    }
    let repeat_count = repeats.to_int()
    let byte_count = (self.bit_width + 7) / 8
    if self.pos + byte_count > data.length() {
      raise @types.EncodingError::Truncated(
        self.pos,
        byte_count,
        data.length() - self.pos,
      )
    }
    let mut value = 0UL
    for index in 0..<byte_count {
      value = value |
        (data[self.pos + index].to_int().to_uint64() << (index * 8))
    }
    self.pos += byte_count
    let take = if self.count - self.filled < repeat_count {
      self.count - self.filled
    } else {
      repeat_count
    }
    self.filled += take
    Some(HybridRun::Repeat(value.reinterpret_as_int64(), take))
  }
}

///|
/// Walks a hybrid stream without unpacking and returns how many values it can
/// produce, raising the same errors `HybridWalk::next` would.
///
/// This is a second copy of the run walk on purpose. Folding the two together
/// (a shared `step` returning the run's byte range, with the decode unpacking
/// from it) reads better and was measured: it cost 4% to 7% of
/// DELTA_BINARY_PACKED decode and about 1% of boolean RLE decode even when the
/// validation never ran, because the decode loop then paid an extra call and an
/// extra struct per run. The hot loop keeps its inlined form and this pass is
/// only reached above `PREVALIDATE_ABOVE`, where a second walk over a few
/// thousand headers is noise next to the values themselves. A test decodes a
/// stream just above the threshold and truncates it, so a divergence between
/// the two walks shows up as a failure rather than as a silent gap.
fn hybrid_produced(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
  offset : Int32,
) -> Int32 raise @types.EncodingError {
  let mut pos = offset
  let mut filled = 0
  while filled < count && pos < data.length() {
    let (header, consumed) = @primitives.read_uleb128(data, offset=pos) catch {
      @primitives.PrimitivesError::Truncated(at, need, available) =>
        raise @types.EncodingError::Truncated(at, need, available)
      _ => raise @types.EncodingError::Truncated(pos, 1, data.length() - pos)
    }
    pos += consumed
    if (header & 1UL) == 1UL {
      let groups = (header >> 1).reinterpret_as_int64()
      if groups > 268435455L {
        // Same rule as `HybridWalk::next`, and the same error class as the
        // repeat guard below it.
        raise @types.EncodingError::Corrupt(pos)
      }
      let produced = (groups * 8L).to_int()
      let byte_count = groups * bit_width.to_int64()
      if byte_count > (data.length() - pos).to_int64() {
        let need = if byte_count > 2147483647L {
          2147483647
        } else {
          byte_count.to_int()
        }
        raise @types.EncodingError::Truncated(pos, need, data.length() - pos)
      }
      let take = if count - filled < produced {
        count - filled
      } else {
        produced
      }
      pos += byte_count.to_int()
      filled += take
    } else {
      let repeats = (header >> 1).reinterpret_as_int64()
      if repeats > 2147483647L {
        raise @types.EncodingError::Corrupt(pos)
      }
      let repeat_count = repeats.to_int()
      let byte_count = (bit_width + 7) / 8
      if pos + byte_count > data.length() {
        raise @types.EncodingError::Truncated(
          pos,
          byte_count,
          data.length() - pos,
        )
      }
      pos += byte_count
      let take = if count - filled < repeat_count {
        count - filled
      } else {
        repeat_count
      }
      filled += take
    }
  }
  filled
}

///|
/// Read a hybrid stream until `count` values are produced or the input ends.
/// Returns the values and how many bytes the runs occupied.
pub fn decode_rle_hybrid(
  data : BytesView,
  bit_width : Int32,
  count : Int32,
  offset~ : Int32 = 0,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> (Array[Int64], Int32) raise @types.EncodingError {
  // The walk validates `bit_width`, `count`, `offset` and the ceiling before
  // anything is allocated: `unsafe_make_uninit(-1)` is a runtime abort, not a
  // typed error, and a page header supplies this count.
  let walk = hybrid_walk(data, bit_width, count, offset, max_values~)
  if count > @types.PREVALIDATE_ABOVE {
    // Above the threshold the output is big enough to be worth a second walk
    // over the runs, so a stream that ends short is refused before the output
    // exists instead of allocating the requested count first. The walk above
    // has already validated the arguments, which is why this comes after it.
    let produced = hybrid_produced(data, bit_width, count, offset)
    if produced < count {
      raise @types.EncodingError::Incomplete(produced, count)
    }
  }
  let out : Array[Int64] = Array::unsafe_make_uninit(count)
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(values, take)) => {
        for index in 0..<take {
          out[filled + index] = values[index]
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) =>
        for _ in 0..<take {
          out[filled] = value
          filled += 1
        }
    }
  }
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  (out, walk.pos - offset)
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
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> Array[Bool] raise @types.EncodingError {
  // The count is an argument and the length prefix is a stream byte, so the
  // count is judged first: with the prefix check ahead of the walk, a hostile
  // prefix reported `Truncated` while the same call with a benign prefix
  // reported `TooManyValues`, and which error a caller sees should not depend
  // on the bytes. `decode_rle_hybrid` validates the same two things again, for
  // the callers that reach it directly.
  if count < 0 {
    raise @types.EncodingError::InvalidCount(count)
  }
  if count > max_values {
    raise @types.EncodingError::TooManyValues(count, max_values)
  }
  if data.length() < 4 {
    raise @types.EncodingError::Truncated(0, 4, data.length())
  }
  let length = read_u32_le(data, 0)
  if length < 0 {
    raise @types.EncodingError::InvalidCount(length)
  }
  // `4 + length` wraps for a length near `Int32::max_value`, which used to
  // pass this check and hand a negative end to the slice.
  if length > data.length() - 4 {
    raise @types.EncodingError::Truncated(4, length, data.length() - 4)
  }
  let (values, _) = decode_rle_hybrid(data[4:4 + length], 1, count, max_values~)
  Array::makei(count, fn(index) { values[index] != 0L })
}
