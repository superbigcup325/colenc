/// A t-digest: a centroid summary of a numeric distribution that answers
/// quantile queries with bounded memory. The contract — k1 scaling, the
/// quantile convention, serialization and the three acceptance layers — is
/// `docs/SKETCHES.md`; this file implements it and nothing else.

///|
/// The compression parameter bounds: below 10 the summary is one centroid away
/// from useless, above 1000 the state stops being smaller than a sorted sample.
const TDIGEST_MIN_COMPRESSION : Int32 = 10

///|
const TDIGEST_MAX_COMPRESSION : Int32 = 1000

///|
const TDIGEST_DEFAULT_COMPRESSION : Int32 = 100

///|
/// The centroid bound after compression is `2k`; the reader accepts one more so
/// an off-by-one at the boundary is caught as a wrong count, not as a crash.
const TDIGEST_CENTROID_FACTOR : Int32 = 2

///|
/// The buffer that holds raw values before a compression pass, in units of k.
const TDIGEST_BUFFER_FACTOR : Int32 = 8

///|
const TDIGEST_VERSION : Int32 = 1

///|
const TDIGEST_PI : Double = 3.141592653589793

///|
/// Version, compression, count, minimum and maximum.
const TDIGEST_HEADER_BYTES : Int32 = 23

///|
fn tdigest_is_finite(value : Double) -> Bool {
  // NaN fails the first comparison and an infinity fails the second.
  value == value && value - value == 0.0
}

///|
/// The k1 scale function: monotone in q, so "this centroid spans one unit of
/// k-space at most" is a checkable statement.
fn tdigest_scale(compression : Int32, q : Double) -> Double {
  compression.to_double() / (2.0 * TDIGEST_PI) * @math.asin(2.0 * q - 1.0)
}

///|
/// One compression pass over a sorted centroid list. Shared by `compress` (which
/// first folds the raw buffer in) and `merge`, so both end up with the same
/// shape and neither can drift from the other.
fn tdigest_compress_centroids(
  compression : Int32,
  means : Array[Double],
  weights : Array[Double],
  total : Double,
  reverse : Bool,
) -> (Array[Double], Array[Double]) {
  let out_means : Array[Double] = []
  let out_weights : Array[Double] = []
  if means.length() == 0 || total <= 0.0 {
    return (out_means, out_weights)
  }
  // Alternating the sweep direction keeps the error uniform: a pass that always
  // starts at the minimum leaves the centroids near the maximum coarser than
  // they need to be, which is exactly where the tail quantiles live.
  if reverse {
    let flipped_means : Array[Double] = []
    let flipped_weights : Array[Double] = []
    let mut cursor = means.length() - 1
    while cursor >= 0 {
      flipped_means.push(means[cursor])
      flipped_weights.push(weights[cursor])
      cursor -= 1
    }
    let (reversed_means, reversed_weights) = tdigest_compress_centroids(
      compression, flipped_means, flipped_weights, total, false,
    )
    let final_means : Array[Double] = []
    let final_weights : Array[Double] = []
    let mut index = reversed_means.length() - 1
    while index >= 0 {
      final_means.push(reversed_means[index])
      final_weights.push(reversed_weights[index])
      index -= 1
    }
    return (final_means, final_weights)
  }
  let mut before = 0.0
  let mut index = 0
  while index < means.length() {
    let q_low = before / total
    let mut weight = 0.0
    let mut weighted = 0.0
    let mut next = index
    while next < means.length() {
      let candidate = weight + weights[next]
      let q_high = (before + candidate) / total
      if next > index &&
        tdigest_scale(compression, q_high) - tdigest_scale(compression, q_low) >
        1.0 {
        break
      }
      weight = candidate
      weighted = weighted + means[next] * weights[next]
      next += 1
    }
    out_means.push(weighted / weight)
    out_weights.push(weight)
    before = before + weight
    index = next
  }
  (out_means, out_weights)
}

///|
/// The digest's centroids plus its raw buffer, as one sorted list of
/// `(mean, weight)` pairs. Reading it never touches the digest, which is what
/// lets `merge` leave both operands exactly as they were.
fn tdigest_pairs(digest : TDigest) -> Array[(Double, Double)] {
  let pairs : Array[(Double, Double)] = []
  for index in 0..<digest.means.length() {
    pairs.push((digest.means[index], digest.weights[index]))
  }
  for value in digest.buffer {
    pairs.push((value, 1.0))
  }
  pairs.sort()
  pairs
}

///|
fn tdigest_split(
  pairs : Array[(Double, Double)],
) -> (Array[Double], Array[Double]) {
  let means : Array[Double] = []
  let weights : Array[Double] = []
  for pair in pairs {
    means.push(pair.0)
    weights.push(pair.1)
  }
  (means, weights)
}

///|
/// A t-digest over `Double` values: `2k` centroids at rest, a raw buffer of `8k`
/// values while filling, and a query path that interpolates between centroids.
pub struct TDigest {
  priv compression : Int32
  priv mut means : Array[Double]
  priv mut weights : Array[Double]
  priv mut buffer : Array[Double]
  priv mut total : Double
  priv mut minimum : Double
  priv mut maximum : Double
  priv mut has_values : Bool
  /// Which end the next compression pass starts from.
  priv mut reverse : Bool
}

///|
/// `compression` is `k`: the summary keeps at most `2k` centroids, so a larger
/// value buys accuracy and costs memory in the same step.
pub fn TDigest::new(compression : Int32) -> TDigest raise @types.EncodingError {
  if compression < TDIGEST_MIN_COMPRESSION ||
    compression > TDIGEST_MAX_COMPRESSION {
    raise @types.EncodingError::InvalidArgument(
      "compression \{compression} outside \{TDIGEST_MIN_COMPRESSION}..\{TDIGEST_MAX_COMPRESSION}",
    )
  }
  {
    compression,
    means: [],
    weights: [],
    buffer: [],
    total: 0.0,
    minimum: 0.0,
    maximum: 0.0,
    has_values: false,
    reverse: false,
  }
}

///|
pub fn TDigest::new_default() -> TDigest {
  {
    compression: TDIGEST_DEFAULT_COMPRESSION,
    means: [],
    weights: [],
    buffer: [],
    total: 0.0,
    minimum: 0.0,
    maximum: 0.0,
    has_values: false,
    reverse: false,
  }
}

///|
pub fn TDigest::compression(self : TDigest) -> Int32 {
  self.compression
}

///|
/// The number of values the digest has seen, as a double so a caller with more
/// than 2^31 of them still gets the right answer.
pub fn TDigest::count(self : TDigest) -> Double {
  self.total
}

///|
pub fn TDigest::centroid_count(self : TDigest) -> Int32 {
  self.means.length()
}

///|
/// The smallest and largest value seen, exactly: a centroid mean would round
/// them, and a caller reading a tail quantile usually wants the extremes.
pub fn TDigest::minimum(self : TDigest) -> Double raise @types.EncodingError {
  if !self.has_values {
    raise @types.EncodingError::Incomplete(0, 1)
  }
  self.minimum
}

///|
pub fn TDigest::maximum(self : TDigest) -> Double raise @types.EncodingError {
  if !self.has_values {
    raise @types.EncodingError::Incomplete(0, 1)
  }
  self.maximum
}

///|
/// A value with no rank cannot be summarised, so it is rejected instead of being
/// folded in: one NaN would spread through every centroid it touches.
pub fn TDigest::update(
  self : TDigest,
  value : Double,
) -> Unit raise @types.EncodingError {
  if !tdigest_is_finite(value) {
    raise @types.EncodingError::InvalidArgument(
      "a NaN or infinite value has no rank",
    )
  }
  self.buffer.push(value)
  self.total = self.total + 1.0
  if self.has_values {
    if value < self.minimum {
      self.minimum = value
    }
    if value > self.maximum {
      self.maximum = value
    }
  } else {
    self.minimum = value
    self.maximum = value
    self.has_values = true
  }
  if self.buffer.length() >= self.compression * TDIGEST_BUFFER_FACTOR {
    self.compress()
  }
}

///|
/// Fold the raw buffer into the centroids and run one compression pass. Called
/// when the buffer fills and before any query, so no query sees a half-sorted
/// state.
pub fn TDigest::compress(self : TDigest) -> Unit {
  if self.buffer.length() == 0 {
    return
  }
  let (means, weights) = tdigest_split(tdigest_pairs(self))
  let (folded_means, folded_weights) = tdigest_compress_centroids(
    self.compression,
    means,
    weights,
    self.total,
    self.reverse,
  )
  self.means = folded_means
  self.weights = folded_weights
  self.buffer = []
  self.reverse = !self.reverse
}

///|
/// The union of two digests of the same compression parameter: concatenate the
/// centroids, compress once. Both operands are left untouched.
pub fn TDigest::merge(
  self : TDigest,
  other : TDigest,
) -> TDigest raise @types.EncodingError {
  if self.compression != other.compression {
    raise @types.EncodingError::InvalidArgument(
      "compression \{self.compression} does not match \{other.compression}",
    )
  }
  // Both operands are read through `tdigest_pairs`, which folds a raw buffer into
  // a temporary list: neither digest is compressed in place, so a caller's sketch
  // answers the same before and after the merge.
  let left_pairs = tdigest_pairs(self)
  let right_pairs = tdigest_pairs(other)
  let merged_pairs : Array[(Double, Double)] = []
  let mut left = 0
  let mut right = 0
  while left < left_pairs.length() && right < right_pairs.length() {
    if left_pairs[left].0 <= right_pairs[right].0 {
      merged_pairs.push(left_pairs[left])
      left += 1
    } else {
      merged_pairs.push(right_pairs[right])
      right += 1
    }
  }
  while left < left_pairs.length() {
    merged_pairs.push(left_pairs[left])
    left += 1
  }
  while right < right_pairs.length() {
    merged_pairs.push(right_pairs[right])
    right += 1
  }
  let (means, weights) = tdigest_split(merged_pairs)
  let total = self.total + other.total
  let (folded_means, folded_weights) = tdigest_compress_centroids(
    self.compression,
    means,
    weights,
    total,
    self.reverse,
  )
  let has_values = self.has_values || other.has_values
  let mut minimum = self.minimum
  let mut maximum = self.maximum
  if other.has_values {
    if !self.has_values || other.minimum < minimum {
      minimum = other.minimum
    }
    if !self.has_values || other.maximum > maximum {
      maximum = other.maximum
    }
  }
  {
    compression: self.compression,
    means: folded_means,
    weights: folded_weights,
    buffer: [],
    total,
    minimum,
    maximum,
    has_values,
    reverse: !self.reverse,
  }
}

///|
/// The value at quantile `q`: exact at the extremes, interpolated between the two
/// centroids whose positions bracket it in between. `q` is a fraction, `0` the
/// minimum and `1` the maximum.
pub fn TDigest::quantile(
  self : TDigest,
  q : Double,
) -> Double raise @types.EncodingError {
  if !tdigest_is_finite(q) || q < 0.0 || q > 1.0 {
    raise @types.EncodingError::InvalidArgument("quantile outside 0..1")
  }
  if !self.has_values {
    raise @types.EncodingError::Incomplete(0, 1)
  }
  self.compress()
  if q <= 0.0 {
    return self.minimum
  }
  if q >= 1.0 {
    return self.maximum
  }
  let count = self.means.length()
  if count == 1 {
    return self.means[0]
  }
  let target = q * self.total
  let mut before = 0.0
  let mut index = 0
  while index < count {
    let weight = self.weights[index]
    let center = before + weight / 2.0
    if target <= center {
      if index == 0 {
        let span = center
        let t = if span == 0.0 { 0.0 } else { target / span }
        return self.minimum + (self.means[0] - self.minimum) * t
      }
      let previous_center = before - self.weights[index - 1] / 2.0
      let span = center - previous_center
      let t = if span == 0.0 { 0.0 } else { (target - previous_center) / span }
      return self.means[index - 1] +
        (self.means[index] - self.means[index - 1]) * t
    }
    before = before + weight
    index += 1
  }
  let last_center = before - self.weights[count - 1] / 2.0
  let span = self.total - last_center
  let t = if span == 0.0 { 0.0 } else { (target - last_center) / span }
  self.means[count - 1] + (self.maximum - self.means[count - 1]) * t
}

///|
/// The serialized form: version byte, compression as u16le, centroid count as
/// u32le, the minimum and maximum as f64le, then one (mean f64le, weight f64le)
/// pair per centroid. The extremes travel with the stream because a centroid
/// mean is an average and cannot reproduce them.
pub fn TDigest::to_bytes(self : TDigest) -> Bytes {
  self.compress()
  let count = self.means.length()
  let out = FixedArray::make(TDIGEST_HEADER_BYTES + count * 16, b'\x00')
  out[0] = TDIGEST_VERSION.to_byte()
  let compression = self.compression
  out[1] = (compression & 0xFF).to_byte()
  out[2] = ((compression >> 8) & 0xFF).to_byte()
  for index in 0..<4 {
    out[3 + index] = ((count >> (8 * index)) & 0xFF).to_byte()
  }
  let minimum = self.minimum.reinterpret_as_int64()
  let maximum = self.maximum.reinterpret_as_int64()
  for byte in 0..<8 {
    out[7 + byte] = ((minimum >> (8 * byte)) & 0xFF).to_byte()
    out[15 + byte] = ((maximum >> (8 * byte)) & 0xFF).to_byte()
  }
  for index in 0..<count {
    let mean = self.means[index].reinterpret_as_int64()
    let weight = self.weights[index].reinterpret_as_int64()
    for byte in 0..<8 {
      out[TDIGEST_HEADER_BYTES + index * 16 + byte] = ((mean >> (8 * byte)) &
      0xFF).to_byte()
      out[TDIGEST_HEADER_BYTES + index * 16 + 8 + byte] = ((
        weight >> (8 * byte)
      ) &
      0xFF).to_byte()
    }
  }
  Bytes::from_array(out.exact_view())
}

///|
fn tdigest_read_u32_le(bytes : BytesView, offset : Int32) -> Int32 {
  let mut value = 0
  for index in 0..<4 {
    value = value | (bytes[offset + index].to_int() << (8 * index))
  }
  value
}

///|
fn tdigest_read_f64_le(bytes : BytesView, offset : Int32) -> Double {
  let mut bits : Int64 = 0L
  for index in 0..<8 {
    bits = bits | (bytes[offset + index].to_int64() << (8 * index))
  }
  bits.reinterpret_as_double()
}

///|
/// Read a digest back, rejecting every state the writer cannot produce: an
/// unknown version, a compression outside the range, a count beyond `2k + 1`, a
/// weight that is not positive and finite, means that go backwards, and a mean
/// outside the recorded extremes.
pub fn TDigest::from_bytes(
  bytes : BytesView,
) -> TDigest raise @types.EncodingError {
  if bytes.length() < TDIGEST_HEADER_BYTES {
    raise @types.EncodingError::Truncated(
      0,
      TDIGEST_HEADER_BYTES,
      bytes.length(),
    )
  }
  let version = bytes[0].to_int()
  if version != TDIGEST_VERSION {
    raise @types.EncodingError::InvalidTag(version)
  }
  let compression = bytes[1].to_int() | (bytes[2].to_int() << 8)
  if compression < TDIGEST_MIN_COMPRESSION ||
    compression > TDIGEST_MAX_COMPRESSION {
    raise @types.EncodingError::InvalidArgument(
      "compression \{compression} outside \{TDIGEST_MIN_COMPRESSION}..\{TDIGEST_MAX_COMPRESSION}",
    )
  }
  let count = tdigest_read_u32_le(bytes, 3)
  if count > compression * TDIGEST_CENTROID_FACTOR + 1 {
    raise @types.EncodingError::Corrupt(3)
  }
  if bytes.length() != TDIGEST_HEADER_BYTES + count * 16 {
    raise @types.EncodingError::Truncated(
      TDIGEST_HEADER_BYTES,
      count * 16,
      bytes.length() - TDIGEST_HEADER_BYTES,
    )
  }
  let minimum = tdigest_read_f64_le(bytes, 7)
  let maximum = tdigest_read_f64_le(bytes, 15)
  if !tdigest_is_finite(minimum) || !tdigest_is_finite(maximum) {
    raise @types.EncodingError::Corrupt(7)
  }
  let means : Array[Double] = []
  let weights : Array[Double] = []
  let mut total = 0.0
  let mut previous = 0.0
  for index in 0..<count {
    let offset = TDIGEST_HEADER_BYTES + index * 16
    let mean = tdigest_read_f64_le(bytes, offset)
    let weight = tdigest_read_f64_le(bytes, offset + 8)
    if !tdigest_is_finite(mean) {
      raise @types.EncodingError::Corrupt(offset)
    }
    if !tdigest_is_finite(weight) || weight <= 0.0 {
      raise @types.EncodingError::Corrupt(offset + 8)
    }
    // Sorted, not strictly increasing: a duplicate-heavy column produces
    // adjacent centroids with the same mean, and the writer can emit them.
    if index > 0 && mean < previous {
      raise @types.EncodingError::Corrupt(offset)
    }
    if mean < minimum || mean > maximum {
      raise @types.EncodingError::Corrupt(offset)
    }
    means.push(mean)
    weights.push(weight)
    total = total + weight
    previous = mean
  }
  if count == 0 {
    return {
      compression,
      means,
      weights,
      buffer: [],
      total: 0.0,
      minimum: 0.0,
      maximum: 0.0,
      has_values: false,
      reverse: false,
    }
  }
  {
    compression,
    means,
    weights,
    buffer: [],
    total,
    minimum,
    maximum,
    has_values: true,
    reverse: false,
  }
}
