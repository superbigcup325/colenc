/// Dictionary encoding: build the distinct values in first-appearance order,
/// write them as a PLAIN dictionary page, and write one hybrid RLE stream of
/// indices behind a one-byte bit width.
///
/// The choices that decide byte identity, all matching parquet-cpp:
///
/// - the dictionary keeps first-appearance order; duplicates map to the first
///   index that produced them
/// - bit width is zero for an empty dictionary, one for a single entry, and
///   `bit_width_for(size - 1)` otherwise (so five entries need three bits)
/// - the data page is one width byte followed by the same hybrid stream the RLE
///   encoder produces, so run selection is shared
/// - BOOLEAN has no dictionary encoding in Parquet
///
/// Threshold fallback: parquet-cpp falls back to PLAIN mid-column once the
/// dictionary's encoded size passes its page limit, which needs a page-splitting
/// writer. colenc decides per column instead: if the PLAIN dictionary payload
/// exceeds the limit, the whole column falls back (returns None). The limits
/// differ in scope, so byte diffs only cover columns that stay under it.

///|
pub const DEFAULT_DICTIONARY_BYTE_LIMIT : Int32 = 1048576

///|
fn dictionary_bit_width(size : Int32) -> Int32 {
  if size <= 0 {
    0
  } else if size == 1 {
    // parquet-cpp uses one bit even for a single entry
    1
  } else {
    @primitives.bit_width_for((size - 1).to_uint64())
  }
}

///|
///
/// Every planner takes the dictionary byte limit and returns `None` the moment
/// the PLAIN dictionary payload would pass it. The payload only grows, so the
/// early exit decides exactly what the full build followed by a size check
/// decided, without building the rest of the dictionary and the indices.
fn plan_int32(
  values : Array[Int32],
  limit : Int32,
) -> (Array[Int32], Array[Int64])? {
  let max_entries = limit.to_int64() / 4L
  let seen : Map[Int32, Int32] = Map([])
  let distinct : Array[Int32] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        if index.to_int64() >= max_entries {
          return None
        }
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  Some((distinct, indices))
}

///|
fn plan_int64(
  values : Array[Int64],
  limit : Int32,
) -> (Array[Int64], Array[Int64])? {
  let max_entries = limit.to_int64() / 8L
  let seen : Map[Int64, Int32] = Map([])
  let distinct : Array[Int64] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        if index.to_int64() >= max_entries {
          return None
        }
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  Some((distinct, indices))
}

///|
/// Floats are deduplicated by bit pattern, so `0.0` and `-0.0` are distinct
/// dictionary entries and NaN values deduplicate to one entry per pattern.
fn plan_float(
  values : Array[Float],
  limit : Int32,
) -> (Array[Float], Array[Int64])? {
  let max_entries = limit.to_int64() / 4L
  let seen : Map[Int32, Int32] = Map([])
  let distinct : Array[Float] = []
  let indices : Array[Int64] = []
  for value in values {
    let key = value.reinterpret_as_int()
    match seen.get(key) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        if index.to_int64() >= max_entries {
          return None
        }
        seen.set(key, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  Some((distinct, indices))
}

///|
fn plan_double(
  values : Array[Double],
  limit : Int32,
) -> (Array[Double], Array[Int64])? {
  let max_entries = limit.to_int64() / 8L
  let seen : Map[Int64, Int32] = Map([])
  let distinct : Array[Double] = []
  let indices : Array[Int64] = []
  for value in values {
    let key = value.reinterpret_as_int64()
    match seen.get(key) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        if index.to_int64() >= max_entries {
          return None
        }
        seen.set(key, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  Some((distinct, indices))
}

///|
/// A byte array costs its four-byte length plus its bytes; the running total is
/// kept in 64 bits so a large dictionary cannot wrap before the comparison.
fn plan_byte_arrays(
  values : Array[Bytes],
  limit : Int32,
) -> (Array[Bytes], Array[Int64])? {
  let max_bytes = limit.to_int64()
  let mut used = 0L
  let seen : Map[Bytes, Int32] = Map([])
  let distinct : Array[Bytes] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        used = used + 4L + value.length().to_int64()
        if used > max_bytes {
          return None
        }
        let index = distinct.length()
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  Some((distinct, indices))
}

///|
fn write_plain_values(values : @types.ColBuf, out : @buffer.Buffer) -> Unit {
  match values {
    Int32s(items) => encode_int32(items, out)
    Int64s(items) => encode_int64(items, out)
    Floats(items) => encode_float(items, out)
    Doubles(items) => encode_double(items, out)
    ByteArrays(items) => encode_byte_arrays(items, out)
    Bools(_) => ()
  }
}

///|
/// Build the dictionary and both payloads. Returns `None` when the PLAIN
/// dictionary payload exceeds `max_dictionary_bytes`, which means the caller
/// should fall back to PLAIN.
pub fn encode_dictionary(
  column : @types.ColBuf,
  max_dictionary_bytes~ : Int32 = DEFAULT_DICTIONARY_BYTE_LIMIT,
) -> @types.DictionaryEncoding? raise @types.EncodingError {
  if max_dictionary_bytes < 0 {
    raise @types.EncodingError::InvalidCount(max_dictionary_bytes)
  }
  let (distinct, indices) = match column {
    Int32s(values) =>
      match plan_int32(values, max_dictionary_bytes) {
        Some((distinct, indices)) => (@types.ColBuf::Int32s(distinct), indices)
        None => return None
      }
    Int64s(values) =>
      match plan_int64(values, max_dictionary_bytes) {
        Some((distinct, indices)) => (@types.ColBuf::Int64s(distinct), indices)
        None => return None
      }
    Floats(values) =>
      match plan_float(values, max_dictionary_bytes) {
        Some((distinct, indices)) => (@types.ColBuf::Floats(distinct), indices)
        None => return None
      }
    Doubles(values) =>
      match plan_double(values, max_dictionary_bytes) {
        Some((distinct, indices)) => (@types.ColBuf::Doubles(distinct), indices)
        None => return None
      }
    ByteArrays(values) =>
      match plan_byte_arrays(values, max_dictionary_bytes) {
        Some((distinct, indices)) =>
          (@types.ColBuf::ByteArrays(distinct), indices)
        None => return None
      }
    Bools(_) => raise @types.EncodingError::TypeMismatch(Bool, Dictionary)
  }
  let width = dictionary_bit_width(distinct.value_count())

  // The planners already refused any dictionary over the limit.
  let dictionary = Buffer()
  write_plain_values(distinct, dictionary)
  let dictionary_bytes = dictionary.to_bytes()

  let indices_buffer = Buffer()
  indices_buffer.write_byte(width.to_byte())
  encode_rle_hybrid(indices[:], width, indices_buffer)
  Some({
    dictionary: dictionary_bytes,
    indices: indices_buffer.to_bytes(),
    dictionary_size: distinct.value_count(),
    bit_width: width,
  })
}

///|
/// The five functions below walk the index stream and write the looked-up value
/// straight into the output, so a dictionary decode no longer builds the
/// `count`-sized index array the two-step version needed. Each one reports the
/// errors `decode_rle_hybrid` reported, in the same order: the walk validates
/// its arguments first, then the runs are read, then an index is rejected.
fn pick_int32(
  dictionary : Array[Int32],
  position : Int64,
) -> Int32 raise @types.EncodingError {
  let index = position.to_int()
  if index < 0 || index >= dictionary.length() {
    raise @types.EncodingError::InvalidIndex(index, dictionary.length())
  }
  dictionary[index]
}

///|
fn pick_int64(
  dictionary : Array[Int64],
  position : Int64,
) -> Int64 raise @types.EncodingError {
  let index = position.to_int()
  if index < 0 || index >= dictionary.length() {
    raise @types.EncodingError::InvalidIndex(index, dictionary.length())
  }
  dictionary[index]
}

///|
fn pick_float(
  dictionary : Array[Float],
  position : Int64,
) -> Float raise @types.EncodingError {
  let index = position.to_int()
  if index < 0 || index >= dictionary.length() {
    raise @types.EncodingError::InvalidIndex(index, dictionary.length())
  }
  dictionary[index]
}

///|
fn pick_double(
  dictionary : Array[Double],
  position : Int64,
) -> Double raise @types.EncodingError {
  let index = position.to_int()
  if index < 0 || index >= dictionary.length() {
    raise @types.EncodingError::InvalidIndex(index, dictionary.length())
  }
  dictionary[index]
}

///|
fn pick_byte_array(
  dictionary : Array[Bytes],
  position : Int64,
) -> Bytes raise @types.EncodingError {
  let index = position.to_int()
  if index < 0 || index >= dictionary.length() {
    raise @types.EncodingError::InvalidIndex(index, dictionary.length())
  }
  dictionary[index]
}

///|
fn decode_indices_int32(
  dictionary : Array[Int32],
  walk : HybridWalk,
) -> Array[Int32] raise @types.EncodingError {
  let count = walk.count
  let out : Array[Int32] = Array::unsafe_make_uninit(count)
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(batch, take)) => {
        for index in 0..<take {
          out[filled + index] = pick_int32(dictionary, batch[index])
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) => {
        let picked = pick_int32(dictionary, value)
        for _ in 0..<take {
          out[filled] = picked
          filled += 1
        }
      }
    }
  }
  // `probe.produced()` established this; the check stays as the guard that
  // would catch the two passes diverging.
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  out
}

///|
fn decode_indices_int64(
  dictionary : Array[Int64],
  walk : HybridWalk,
) -> Array[Int64] raise @types.EncodingError {
  let count = walk.count
  let out : Array[Int64] = Array::unsafe_make_uninit(count)
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(batch, take)) => {
        for index in 0..<take {
          out[filled + index] = pick_int64(dictionary, batch[index])
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) => {
        let picked = pick_int64(dictionary, value)
        for _ in 0..<take {
          out[filled] = picked
          filled += 1
        }
      }
    }
  }
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  out
}

///|
fn decode_indices_float(
  dictionary : Array[Float],
  walk : HybridWalk,
) -> Array[Float] raise @types.EncodingError {
  let count = walk.count
  let out : Array[Float] = Array::unsafe_make_uninit(count)
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(batch, take)) => {
        for index in 0..<take {
          out[filled + index] = pick_float(dictionary, batch[index])
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) => {
        let picked = pick_float(dictionary, value)
        for _ in 0..<take {
          out[filled] = picked
          filled += 1
        }
      }
    }
  }
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  out
}

///|
fn decode_indices_double(
  dictionary : Array[Double],
  walk : HybridWalk,
) -> Array[Double] raise @types.EncodingError {
  let count = walk.count
  let out : Array[Double] = Array::unsafe_make_uninit(count)
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(batch, take)) => {
        for index in 0..<take {
          out[filled + index] = pick_double(dictionary, batch[index])
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) => {
        let picked = pick_double(dictionary, value)
        for _ in 0..<take {
          out[filled] = picked
          filled += 1
        }
      }
    }
  }
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  out
}

///|
fn decode_indices_byte_array(
  dictionary : Array[Bytes],
  walk : HybridWalk,
) -> Array[Bytes] raise @types.EncodingError {
  let count = walk.count
  let out : Array[Bytes] = Array::make(count, b"")
  let mut filled = 0
  while true {
    match walk.next() {
      None => break
      Some(HybridRun::Literals(batch, take)) => {
        for index in 0..<take {
          out[filled + index] = pick_byte_array(dictionary, batch[index])
        }
        filled += take
      }
      Some(HybridRun::Repeat(value, take)) => {
        let picked = pick_byte_array(dictionary, value)
        for _ in 0..<take {
          out[filled] = picked
          filled += 1
        }
      }
    }
  }
  if filled < count {
    raise @types.EncodingError::Incomplete(filled, count)
  }
  out
}

///|
/// Decode a dictionary page and its index stream. `dictionary_size` is the
/// page's value count; `count` is how many indices the data page carries.
pub fn decode_dictionary(
  dictionary : BytesView,
  indices : BytesView,
  ty : @types.PhysicalType,
  count : Int32,
  dictionary_size : Int32,
  max_values~ : Int32 = @types.DEFAULT_MAX_VALUES,
) -> @types.ColBuf raise @types.EncodingError {
  if dictionary_size < 0 {
    raise @types.EncodingError::InvalidCount(dictionary_size)
  }
  if indices.length() < 1 {
    raise @types.EncodingError::Truncated(0, 1, indices.length())
  }
  let width = indices[0].to_int()
  if width < 0 || width > 32 {
    raise @types.EncodingError::InvalidBitWidth(width)
  }
  // The index stream is validated before the dictionary page is decoded and
  // before any lookup. Two reasons: the output the lookups write into is sized
  // from `count`, so the stream has to prove it can produce that many values
  // first, and a stream that ends short is a stream problem rather than an
  // index problem. The order is therefore arguments, index stream, dictionary
  // page, then the lookups.
  // Unconditional, unlike the RLE and delta paths: the index walk is what makes
  // the error order deterministic (stream, then dictionary page, then lookups),
  // and `harness/perf -- families` measured no change in dictionary decode time
  // because the per-value lookups dominate the extra pass.
  // `hybrid_walk` validates `count` and the ceiling here; it builds the walk
  // without allocating, so the order stays arguments, stream, page, lookups.
  let walk = hybrid_walk(indices[1:], width, count, 0, max_values~)
  let produced = hybrid_produced(indices[1:], width, count, 0)
  if produced < count {
    raise @types.EncodingError::Incomplete(produced, count)
  }
  match ty {
    Int32 => {
      let values = decode_int32(dictionary, dictionary_size)
      @types.ColBuf::Int32s(decode_indices_int32(values, walk))
    }
    Int64 => {
      let values = decode_int64(dictionary, dictionary_size)
      @types.ColBuf::Int64s(decode_indices_int64(values, walk))
    }
    Float => {
      let values = decode_float(dictionary, dictionary_size)
      @types.ColBuf::Floats(decode_indices_float(values, walk))
    }
    Double => {
      let values = decode_double(dictionary, dictionary_size)
      @types.ColBuf::Doubles(decode_indices_double(values, walk))
    }
    ByteArray => {
      let values = decode_byte_arrays(dictionary, dictionary_size)
      @types.ColBuf::ByteArrays(decode_indices_byte_array(values, walk))
    }
    Bool => raise @types.EncodingError::TypeMismatch(Bool, Dictionary)
  }
}
