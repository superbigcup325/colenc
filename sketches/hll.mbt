/// A HyperLogLog sketch. The contract — parameters, hashing, estimator,
/// serialization and the acceptance groups — is `docs/SKETCHES.md`; this file
/// implements it and nothing else.

///|
/// The smallest and largest register-count exponents `HllSketch::new` accepts.
const HLL_MIN_PRECISION : Int32 = 4

///|
const HLL_MAX_PRECISION : Int32 = 16

///|
/// The precision `HllSketch::new_default` uses: 16384 registers, about 0.81%.
const HLL_DEFAULT_PRECISION : Int32 = 14

///|
/// The serialization version. It covers the hash function and the seed too: a
/// sketch written by another hash can never be read back as this one.
const HLL_VERSION : Int32 = 1

///|
const HLL_MURMUR_C1 : UInt64 = 0x87c37b91114253d5UL

///|
const HLL_MURMUR_C2 : UInt64 = 0x4cf5ad432745937fUL

///|
/// 2^64 as a double, the ceiling the large-range correction is written against.
const HLL_TWO_TO_64 : Double = 18446744073709551616.0

///|
fn hll_rotl64(value : UInt64, bits : Int32) -> UInt64 {
  (value << bits) | (value >> (64 - bits))
}

///|
fn hll_fmix64(value : UInt64) -> UInt64 {
  let mut hash = value
  hash = hash ^ (hash >> 33)
  hash = hash * 0xff51afd7ed558ccdUL
  hash = hash ^ (hash >> 33)
  hash = hash * 0xc4ceb9fe1a85ec53UL
  hash = hash ^ (hash >> 33)
  hash
}

///|
fn hll_read_le64(view : BytesView, offset : Int32) -> UInt64 {
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (view[offset + index].to_uint64() << (8 * index))
  }
  value
}

///|
fn hll_read_le64_tail(
  view : BytesView,
  offset : Int32,
  count : Int32,
) -> UInt64 {
  let mut value = 0UL
  for index in 0..<count {
    value = value | (view[offset + index].to_uint64() << (8 * index))
  }
  value
}

///|
/// MurmurHash3 x64 128, lower 64 bits, seed 0. Pure 64-bit integer arithmetic:
/// the same bytes hash to the same value on native, wasm-gc and JS, which is
/// what the serialization identity across backends rests on.
fn hll_hash(view : BytesView) -> UInt64 {
  let length = view.length()
  let blocks = length / 16
  let mut h1 = 0UL
  let mut h2 = 0UL
  for block in 0..<blocks {
    let base = block * 16
    let k1 = hll_read_le64(view, base)
    let k2 = hll_read_le64(view, base + 8)
    h1 = h1 ^ (hll_rotl64(k1 * HLL_MURMUR_C1, 31) * HLL_MURMUR_C2)
    h1 = hll_rotl64(h1, 27) + h2
    h1 = h1 * 5UL + 0x52dce729UL
    h2 = h2 ^ (hll_rotl64(k2 * HLL_MURMUR_C2, 33) * HLL_MURMUR_C1)
    h2 = hll_rotl64(h2, 31) + h1
    h2 = h2 * 5UL + 0x38495ab5UL
  }
  let base = blocks * 16
  let tail = length & 15
  if tail > 8 {
    let k2 = hll_rotl64(
        hll_read_le64_tail(view, base + 8, tail - 8) * HLL_MURMUR_C2,
        33,
      ) *
      HLL_MURMUR_C1
    h2 = h2 ^ k2
  }
  if tail > 0 {
    let count = if tail < 8 { tail } else { 8 }
    let k1 = hll_rotl64(
        hll_read_le64_tail(view, base, count) * HLL_MURMUR_C1,
        31,
      ) *
      HLL_MURMUR_C2
    h1 = h1 ^ k1
  }
  let wide = length.to_uint64()
  h1 = h1 ^ wide
  h2 = h2 ^ wide
  h1 = h1 + h2
  h2 = h2 + h1
  h1 = hll_fmix64(h1)
  h2 = hll_fmix64(h2)
  h1 = h1 + h2
  h2 = h2 + h1
  h1
}

///|
fn hll_leading_zeros(value : UInt64) -> Int32 {
  if value == 0UL {
    return 64
  }
  let mut rest = value
  let mut count = 0
  if rest >> 32 == 0UL {
    count += 32
    rest = rest << 32
  }
  if rest >> 48 == 0UL {
    count += 16
    rest = rest << 16
  }
  if rest >> 56 == 0UL {
    count += 8
    rest = rest << 8
  }
  if rest >> 60 == 0UL {
    count += 4
    rest = rest << 4
  }
  if rest >> 62 == 0UL {
    count += 2
    rest = rest << 2
  }
  if rest >> 63 == 0UL {
    count += 1
  }
  count
}

///|
/// The bias constant of the raw estimator, which depends on the register count.
fn hll_alpha(precision : Int32) -> Double {
  let m = 1 << precision
  if m == 16 {
    0.673
  } else if m == 32 {
    0.697
  } else if m == 64 {
    0.709
  } else {
    0.7213 / (1.0 + 1.079 / m.to_double())
  }
}

///|
/// A dense HyperLogLog sketch: `m = 2^precision` registers of six bits, each
/// holding the largest rank its bucket has seen. A register lives in memory as
/// one byte, the width the serialized form uses, so the state is `m` bytes
/// rather than `m` machine words.
pub struct HllSketch {
  priv precision : Int32
  priv registers : FixedArray[Byte]
}

///|
/// A sketch of the given precision. The precision fixes the register count and
/// therefore the memory (one register per id bucket) and the standard error.
pub fn HllSketch::new(
  precision : Int32,
) -> HllSketch raise @types.EncodingError {
  if precision < HLL_MIN_PRECISION || precision > HLL_MAX_PRECISION {
    raise @types.EncodingError::OutOfRange(precision.to_int64(), -1)
  }
  let count = 1 << precision
  { precision, registers: FixedArray::make(count, b'\x00'), }
}

///|
pub fn HllSketch::new_default() -> HllSketch {
  let count = 1 << HLL_DEFAULT_PRECISION
  {
    precision: HLL_DEFAULT_PRECISION,
    registers: FixedArray::make(count, b'\x00'),
  }
}

///|
pub fn HllSketch::precision(self : HllSketch) -> Int32 {
  self.precision
}

///|
pub fn HllSketch::register_count(self : HllSketch) -> Int32 {
  self.registers.length()
}

///|
/// One register's rank, for a rig that wants to look at the state rather than
/// only at the estimate. Reading it does not copy. An index outside
/// `0 <= index < register_count()` is an error, not a panic.
pub fn HllSketch::register(
  self : HllSketch,
  index : Int32,
) -> Int32 raise @types.EncodingError {
  if index < 0 || index >= self.registers.length() {
    raise @types.EncodingError::OutOfRange(
      index.to_int64(),
      self.registers.length().to_int64().to_int(),
    )
  }
  self.registers[index].to_int()
}

///|
/// Every register's rank as a fresh `Int32` array. Until 0.1.1 this was a
/// non-copying view of the state; registers are bytes now, so the accessor
/// builds an array of the old element type (O(register_count) time and space
/// per call) and its result no longer tracks later updates. Use `register` to
/// read single ranks without that cost.
pub fn HllSketch::registers(self : HllSketch) -> ArrayView[Int32] {
  let count = self.registers.length()
  let ranks : Array[Int32] = Array::make(count, 0)
  for index in 0..<count {
    ranks[index] = self.registers[index].to_int()
  }
  ranks.exact_view()
}

///|
/// The register update: the top `precision` bits choose the bucket, the rest
/// carry the rank. Written once so every typed entry point shares it.
fn HllSketch::absorb_hash(self : HllSketch, hash : UInt64) -> Unit {
  let precision = self.precision
  let index = (hash >> (64 - precision)).reinterpret_as_int64().to_int()
  let rest = hash << precision
  // `rest` already has the index bits shifted out, so its leading zeros are the
  // rank minus one: subtracting the precision again here charged the shift
  // twice and pinned every register at the floor of 1.
  let zeros = hll_leading_zeros(rest)
  let mut rank = zeros + 1
  if rank < 1 {
    rank = 1
  }
  let ceiling = 64 - precision + 1
  if rank > ceiling {
    rank = ceiling
  }
  if rank > self.registers[index].to_int() {
    self.registers[index] = rank.to_byte()
  }
}

///|
fn hll_scratch() -> FixedArray[Byte] {
  FixedArray::make(8, b'\x00')
}

///|
pub fn HllSketch::add_int32(self : HllSketch, value : Int32) -> Unit {
  let scratch = hll_scratch()
  let bits = value.to_int64()
  for index in 0..<4 {
    scratch[index] = (bits >> (8 * index)).to_byte()
  }
  let view = scratch.unsafe_reinterpret_as_bytes().exact_view(start=0, end=4)
  self.absorb_hash(hll_hash(view))
}

///|
pub fn HllSketch::add_int64(self : HllSketch, value : Int64) -> Unit {
  let scratch = hll_scratch()
  for index in 0..<8 {
    scratch[index] = (value >> (8 * index)).to_byte()
  }
  self.absorb_hash(hll_hash(scratch.unsafe_reinterpret_as_bytes()))
}

///|
pub fn HllSketch::add_float(self : HllSketch, value : Float) -> Unit {
  let scratch = hll_scratch()
  let bits = value.reinterpret_as_uint().reinterpret_as_int()
  for index in 0..<4 {
    scratch[index] = ((bits >> (8 * index)) & 0xFF).to_byte()
  }
  let view = scratch.unsafe_reinterpret_as_bytes().exact_view(start=0, end=4)
  self.absorb_hash(hll_hash(view))
}

///|
pub fn HllSketch::add_double(self : HllSketch, value : Double) -> Unit {
  let scratch = hll_scratch()
  let bits = value.reinterpret_as_int64()
  for index in 0..<8 {
    scratch[index] = (bits >> (8 * index)).to_byte()
  }
  self.absorb_hash(hll_hash(scratch.unsafe_reinterpret_as_bytes()))
}

///|
pub fn HllSketch::add_bool(self : HllSketch, value : Bool) -> Unit {
  let one = FixedArray::make(1, if value { b'\x01' } else { b'\x00' })
  self.absorb_hash(hll_hash(one.unsafe_reinterpret_as_bytes()))
}

///|
/// A byte string is hashed by its raw bytes: the value boundary is the caller's
/// argument, not a delimiter, so no length prefix goes into the hash.
pub fn HllSketch::add_bytes(self : HllSketch, value : Bytes) -> Unit {
  self.absorb_hash(hll_hash(value.exact_view()))
}

///|
/// The union of two sketches of the same precision: registers take the larger
/// rank. Both operands are left untouched, so a result never aliases an input.
pub fn HllSketch::merge(
  self : HllSketch,
  other : HllSketch,
) -> HllSketch raise @types.EncodingError {
  if self.precision != other.precision {
    raise @types.EncodingError::InvalidTag(other.precision.to_int64().to_int())
  }
  let registers = self.registers.copy()
  let count = registers.length()
  for index in 0..<count {
    let theirs = other.registers[index]
    if theirs > registers[index] {
      registers[index] = theirs
    }
  }
  { precision: self.precision, registers, }
}

///|
/// The cardinality estimate, with linear counting over the empty registers at
/// the small end and the logarithmic correction at the large end.
pub fn HllSketch::estimate(self : HllSketch) -> Double {
  let count = self.registers.length()
  let m = count.to_double()
  let mut inverse_sum = 0.0
  let mut empty = 0
  for index in 0..<count {
    let rank = self.registers[index].to_int()
    inverse_sum = inverse_sum + hll_inverse_pow(rank)
    if rank == 0 {
      empty += 1
    }
  }
  let raw = hll_alpha(self.precision) * m * m / inverse_sum
  if raw <= 2.5 * m && empty > 0 {
    return m * @math.ln(m / empty.to_double())
  }
  if raw > HLL_TWO_TO_64 / 30.0 {
    let ratio = raw / HLL_TWO_TO_64
    if ratio < 1.0 {
      return -HLL_TWO_TO_64 * @math.ln(1.0 - ratio)
    }
  }
  raw
}

///|
/// 2^-rank, written as a lookup so the estimate does not call a transcendental
/// function once per register.
fn hll_inverse_pow(rank : Int32) -> Double {
  let mut value = 1.0
  let mut index = 0
  while index < rank {
    value = value * 0.5
    index += 1
  }
  value
}

///|
/// The serialized form: version byte, precision byte, then one byte per
/// register, little-endian throughout.
pub fn HllSketch::to_bytes(self : HllSketch) -> Bytes {
  let count = self.registers.length()
  let out = FixedArray::make(2 + count, b'\x00')
  out[0] = HLL_VERSION.to_byte()
  out[1] = self.precision.to_byte()
  for index in 0..<count {
    out[2 + index] = self.registers[index]
  }
  Bytes::from_array(out.exact_view())
}

///|
/// Read a sketch back, rejecting every state the writer cannot produce: an
/// unknown version, a precision outside the range, a length that does not match
/// the precision, and a register above the legal rank.
pub fn HllSketch::from_bytes(
  bytes : BytesView,
) -> HllSketch raise @types.EncodingError {
  if bytes.length() < 2 {
    raise @types.EncodingError::Truncated(0, 2, bytes.length())
  }
  let version = bytes[0].to_int()
  if version != HLL_VERSION {
    raise @types.EncodingError::InvalidTag(version)
  }
  let precision = bytes[1].to_int()
  if precision < HLL_MIN_PRECISION || precision > HLL_MAX_PRECISION {
    raise @types.EncodingError::OutOfRange(precision.to_int64(), 1)
  }
  let count = 1 << precision
  if bytes.length() != 2 + count {
    raise @types.EncodingError::Truncated(2, count, bytes.length() - 2)
  }
  let ceiling = 64 - precision + 1
  let registers = FixedArray::make(count, b'\x00')
  for index in 0..<count {
    let rank = bytes[2 + index]
    if rank.to_int() > ceiling {
      raise @types.EncodingError::Corrupt(2 + index)
    }
    registers[index] = rank
  }
  { precision, registers, }
}
