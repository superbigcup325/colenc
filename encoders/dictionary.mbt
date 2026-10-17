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
fn plan_int32(values : Array[Int32]) -> (Array[Int32], Array[Int64]) {
  let seen : Map[Int32, Int32] = Map([])
  let distinct : Array[Int32] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  (distinct, indices)
}

///|
fn plan_int64(values : Array[Int64]) -> (Array[Int64], Array[Int64]) {
  let seen : Map[Int64, Int32] = Map([])
  let distinct : Array[Int64] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  (distinct, indices)
}

///|
/// Floats are deduplicated by bit pattern, so `0.0` and `-0.0` are distinct
/// dictionary entries and NaN values deduplicate to one entry per pattern.
fn plan_float(values : Array[Float]) -> (Array[Float], Array[Int64]) {
  let seen : Map[Int32, Int32] = Map([])
  let distinct : Array[Float] = []
  let indices : Array[Int64] = []
  for value in values {
    let key = value.reinterpret_as_int()
    match seen.get(key) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        seen.set(key, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  (distinct, indices)
}

///|
fn plan_double(values : Array[Double]) -> (Array[Double], Array[Int64]) {
  let seen : Map[Int64, Int32] = Map([])
  let distinct : Array[Double] = []
  let indices : Array[Int64] = []
  for value in values {
    let key = value.reinterpret_as_int64()
    match seen.get(key) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        seen.set(key, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  (distinct, indices)
}

///|
fn plan_byte_arrays(values : Array[Bytes]) -> (Array[Bytes], Array[Int64]) {
  let seen : Map[Bytes, Int32] = Map([])
  let distinct : Array[Bytes] = []
  let indices : Array[Int64] = []
  for value in values {
    match seen.get(value) {
      Some(index) => indices.push(index.to_int64())
      None => {
        let index = distinct.length()
        seen.set(value, index)
        distinct.push(value)
        indices.push(index.to_int64())
      }
    }
  }
  (distinct, indices)
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
    Int32s(values) => {
      let (distinct, indices) = plan_int32(values)
      (@types.ColBuf::Int32s(distinct), indices)
    }
    Int64s(values) => {
      let (distinct, indices) = plan_int64(values)
      (@types.ColBuf::Int64s(distinct), indices)
    }
    Floats(values) => {
      let (distinct, indices) = plan_float(values)
      (@types.ColBuf::Floats(distinct), indices)
    }
    Doubles(values) => {
      let (distinct, indices) = plan_double(values)
      (@types.ColBuf::Doubles(distinct), indices)
    }
    ByteArrays(values) => {
      let (distinct, indices) = plan_byte_arrays(values)
      (@types.ColBuf::ByteArrays(distinct), indices)
    }
    Bools(_) => raise @types.EncodingError::TypeMismatch(Bool, Dictionary)
  }
  let width = dictionary_bit_width(distinct.value_count())

  let dictionary = Buffer()
  write_plain_values(distinct, dictionary)
  let dictionary_bytes = dictionary.to_bytes()
  if dictionary_bytes.length() > max_dictionary_bytes {
    return None
  }

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
fn lookup_int32(
  dictionary : Array[Int32],
  positions : Array[Int64],
) -> Array[Int32] raise @types.EncodingError {
  let out = Array::make(positions.length(), 0)
  for index in 0..<positions.length() {
    let position = positions[index].to_int()
    if position < 0 || position >= dictionary.length() {
      raise @types.EncodingError::InvalidIndex(position, dictionary.length())
    }
    out[index] = dictionary[position]
  }
  out
}

///|
fn lookup_int64(
  dictionary : Array[Int64],
  positions : Array[Int64],
) -> Array[Int64] raise @types.EncodingError {
  let out = Array::make(positions.length(), 0L)
  for index in 0..<positions.length() {
    let position = positions[index].to_int()
    if position < 0 || position >= dictionary.length() {
      raise @types.EncodingError::InvalidIndex(position, dictionary.length())
    }
    out[index] = dictionary[position]
  }
  out
}

///|
fn lookup_float(
  dictionary : Array[Float],
  positions : Array[Int64],
) -> Array[Float] raise @types.EncodingError {
  let out = Array::make(positions.length(), Float(0.0))
  for index in 0..<positions.length() {
    let position = positions[index].to_int()
    if position < 0 || position >= dictionary.length() {
      raise @types.EncodingError::InvalidIndex(position, dictionary.length())
    }
    out[index] = dictionary[position]
  }
  out
}

///|
fn lookup_double(
  dictionary : Array[Double],
  positions : Array[Int64],
) -> Array[Double] raise @types.EncodingError {
  let out = Array::make(positions.length(), 0.0)
  for index in 0..<positions.length() {
    let position = positions[index].to_int()
    if position < 0 || position >= dictionary.length() {
      raise @types.EncodingError::InvalidIndex(position, dictionary.length())
    }
    out[index] = dictionary[position]
  }
  out
}

///|
fn lookup_byte_arrays(
  dictionary : Array[Bytes],
  positions : Array[Int64],
) -> Array[Bytes] raise @types.EncodingError {
  let out : Array[Bytes] = []
  for index in 0..<positions.length() {
    let position = positions[index].to_int()
    if position < 0 || position >= dictionary.length() {
      raise @types.EncodingError::InvalidIndex(position, dictionary.length())
    }
    out.push(dictionary[position])
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
  let (positions, _) = decode_rle_hybrid(indices[1:], width, count)
  match ty {
    Int32 => {
      let values = decode_int32(dictionary, dictionary_size)
      @types.ColBuf::Int32s(lookup_int32(values, positions))
    }
    Int64 => {
      let values = decode_int64(dictionary, dictionary_size)
      @types.ColBuf::Int64s(lookup_int64(values, positions))
    }
    Float => {
      let values = decode_float(dictionary, dictionary_size)
      @types.ColBuf::Floats(lookup_float(values, positions))
    }
    Double => {
      let values = decode_double(dictionary, dictionary_size)
      @types.ColBuf::Doubles(lookup_double(values, positions))
    }
    ByteArray => {
      let values = decode_byte_arrays(dictionary, dictionary_size)
      @types.ColBuf::ByteArrays(lookup_byte_arrays(values, positions))
    }
    Bool => raise @types.EncodingError::TypeMismatch(Bool, Dictionary)
  }
}
