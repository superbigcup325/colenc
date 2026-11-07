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
  hll_finalize(h1, h2, length)
}

///|
/// The finalization shared by the byte path and the typed short path, so both
/// feed MurmurHash3 the same length and the same accumulated state.
fn hll_finalize(h1 : UInt64, h2 : UInt64, length : Int32) -> UInt64 {
  let wide = length.to_uint64()
  let mut h1 = h1 ^ wide
  let mut h2 = h2 ^ wide
  h1 = h1 + h2
  h2 = h2 + h1
  h1 = hll_fmix64(h1)
  h2 = hll_fmix64(h2)
  h1 = h1 + h2
  h2 = h2 + h1
  h1
}

///|
/// Hash up to eight canonical little-endian bytes already held in an integer.
/// The typed entry points use this instead of allocating a scratch array and
/// copying bytes into it; `length` keeps the Murmur tail and finalization
/// identical to hashing the same bytes.
fn hll_hash_short_le(value : UInt64, length : Int32) -> UInt64 {
  let mask = if length >= 8 {
    0xFFFFFFFFFFFFFFFFUL
  } else {
    (1UL << (length * 8)) - 1UL
  }
  let k1 = hll_rotl64((value & mask) * HLL_MURMUR_C1, 31) * HLL_MURMUR_C2
  hll_finalize(k1, 0UL, length)
}

///|
/// The toolchain's leading-zero count handles zero as 64 and lowers to the
/// target's own instruction or intrinsic on all three backends.
fn hll_leading_zeros(value : UInt64) -> Int32 {
  value.clz()
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
/// A HyperLogLog sketch of one precision, held in whichever of two
/// representations its current cardinality makes cheaper. Both hold the same
/// register vector: the dense form is `m = 2^precision` one-byte registers, and
/// the sparse form stores only the registers that are not zero, sorted by
/// register index. The estimator, the hash, the rank rule and the serialized
/// bytes do not depend on which one is in use; the choice is invisible to
/// everything outside this file.
pub struct HllSketch {
  priv precision : Int32
  priv mut registers : HllRegisters
}

///|
/// The register vector of a sketch. A sparse entry is one word: `index << 6 |
/// rank`, which fits in 22 bits because an index is at most 16 and a rank at most
/// six. One word rather than three packed bytes keeps sorted insertion a word move
/// and the binary search a word compare, and a live entry still costs four bytes
/// against the dense array's one per register — paid only for the registers that
/// are set. `count` is how many slots are live; the array grows by doubling below
/// `hll_sparse_limit`.
priv struct HllSparse {
  mut count : Int32
  mut entries : FixedArray[UInt32]
}

///|
priv enum HllRegisters {
  Sparse(HllSparse)
  Dense(FixedArray[Byte])
}

///|
/// The rank field's width at the bottom of a sparse entry.
const HLL_SPARSE_RANK_BITS : Int32 = 6

///|
/// The ceiling on live entries in a sparse state. The promotion is what bounds
/// the per-group cost from above, and the count is what bounds the update cost:
/// insertion is a sorted-array shift, so a larger cap buys memory for shifting
/// time. At the default precision the whole sparse state is at most 512 bytes
/// against the dense form's 16,384.
const HLL_SPARSE_MAX : Int32 = 128

///|
/// How many live entries a sparse state may hold before it promotes to dense.
/// The empty-register count of an HLL makes small groups overwhelmingly sparse,
/// so this is the switch that turns "one sketch per group" from 16 KiB of resident
/// registers into a few hundred bytes. It is capped at an eighth of the dense
/// array as well, so a sparse state can never be as large as the form it replaces
/// (precision 9 gets 64 entries, and everything from precision 10 up gets 128).
/// Below precision 9 the dense state is at most 512 bytes, so a second
/// representation would only add work and those sketches never leave it.
fn hll_sparse_limit(precision : Int32) -> Int32 {
  if precision < 9 {
    0
  } else {
    let eighth = (1 << precision) / 8
    if eighth < HLL_SPARSE_MAX {
      eighth
    } else {
      HLL_SPARSE_MAX
    }
  }
}

///|
/// The smallest sparse state: eight slots, one word each.
fn hll_sparse_new() -> HllSparse {
  { count: 0, entries: FixedArray::make(8, 0U), }
}

///|
fn HllSparse::capacity(self : HllSparse) -> Int32 {
  self.entries.length()
}

///|
fn HllSparse::index(self : HllSparse, slot : Int32) -> Int32 {
  (self.entries[slot] >> HLL_SPARSE_RANK_BITS).reinterpret_as_int()
}

///|
fn HllSparse::rank(self : HllSparse, slot : Int32) -> Int32 {
  (self.entries[slot] & 0x3FU).reinterpret_as_int()
}

///|
fn HllSparse::write(
  self : HllSparse,
  slot : Int32,
  index : Int32,
  rank : Int32,
) -> Unit {
  self.entries[slot] = (index.reinterpret_as_uint() << HLL_SPARSE_RANK_BITS) |
    rank.reinterpret_as_uint()
}

///|
/// The entry holding `index`, or the slot it would be inserted at. Entries are
/// kept sorted by index so a repeated value — the common case, since an HLL is
/// fed the same few values again and again — costs a binary search rather than a
/// scan of the whole sparse state.
fn HllSparse::find(self : HllSparse, index : Int32) -> (Bool, Int32) {
  let mut low = 0
  let mut high = self.count
  while low < high {
    let mid = (low + high) / 2
    let at = (self.entries[mid] >> HLL_SPARSE_RANK_BITS).reinterpret_as_int()
    if at == index {
      return (true, mid)
    }
    if at < index {
      low = mid + 1
    } else {
      high = mid
    }
  }
  (false, low)
}

///|
fn HllSparse::insert(
  self : HllSparse,
  at : Int32,
  index : Int32,
  rank : Int32,
) -> Unit {
  if self.count == self.capacity() {
    let grown = FixedArray::make(self.capacity() * 2, 0U)
    for offset in 0..<self.count {
      grown[offset] = self.entries[offset]
    }
    self.entries = grown
  }
  let mut slot = self.count
  while slot > at {
    self.entries[slot] = self.entries[slot - 1]
    slot -= 1
  }
  self.write(at, index, rank)
  self.count += 1
}

///|
/// A sketch of the given precision. The precision fixes the register count and
/// therefore the standard error, and the dense form's size; the sketch starts in
/// the representation that precision allows, which is usually the sparse one.
pub fn HllSketch::new(
  precision : Int32,
) -> HllSketch raise @types.EncodingError {
  if precision < HLL_MIN_PRECISION || precision > HLL_MAX_PRECISION {
    raise @types.EncodingError::OutOfRange(precision.to_int64(), -1)
  }
  { precision, registers: hll_fresh_registers(precision), }
}

///|
/// The state a new sketch of this precision starts in.
fn hll_fresh_registers(precision : Int32) -> HllRegisters {
  if hll_sparse_limit(precision) == 0 {
    Dense(FixedArray::make(1 << precision, b'\x00'))
  } else {
    Sparse(hll_sparse_new())
  }
}

///|
pub fn HllSketch::new_default() -> HllSketch {
  {
    precision: HLL_DEFAULT_PRECISION,
    registers: hll_fresh_registers(HLL_DEFAULT_PRECISION),
  }
}

///|
pub fn HllSketch::precision(self : HllSketch) -> Int32 {
  self.precision
}

///|
pub fn HllSketch::register_count(self : HllSketch) -> Int32 {
  match self.registers {
    Dense(dense) => dense.length()
    Sparse(_) => 1 << self.precision
  }
}

///|
/// Every register's rank, in index order, however it is stored. Internal
/// readers (the estimator, `to_bytes`, `registers`) share this one accessor so a
/// representation cannot answer differently from its own serialized form.
fn HllSketch::rank_at(self : HllSketch, index : Int32) -> Int32 {
  match self.registers {
    Dense(dense) => dense[index].to_int()
    Sparse(sparse) =>
      match sparse.find(index) {
        (true, slot) => sparse.rank(slot)
        (false, _) => 0
      }
  }
}

///|
/// The same, for a caller that already knows the index is in range: the sparse
/// form pays one binary search, the dense form one load.
fn HllSketch::note_rank(self : HllSketch, index : Int32, rank : Int32) -> Unit {
  match self.registers {
    Dense(dense) =>
      if rank > dense[index].to_int() {
        dense[index] = rank.to_byte()
      }
    Sparse(sparse) =>
      match sparse.find(index) {
        (true, slot) =>
          if rank > sparse.rank(slot) {
            sparse.write(slot, index, rank)
          }
        (false, slot) =>
          if sparse.count >= hll_sparse_limit(self.precision) {
            // Promote, then let the dense arm absorb this update: the promoted
            // state and the serialized bytes an outside reader sees are the same
            // either way.
            let dense = self.promote()
            if rank > dense[index].to_int() {
              dense[index] = rank.to_byte()
            }
          } else {
            sparse.insert(slot, index, rank)
          }
      }
  }
}

///|
/// The sparse state of this sketch expanded to the dense array, which is also
/// what it is replaced with: called from the update path when a group's
/// cardinality outgrows the sparse form.
fn HllSketch::promote(self : HllSketch) -> FixedArray[Byte] {
  let count = 1 << self.precision
  let dense = FixedArray::make(count, b'\x00')
  match self.registers {
    Sparse(sparse) => {
      for slot in 0..<sparse.count {
        dense[sparse.index(slot)] = sparse.rank(slot).to_byte()
      }
      self.registers = Dense(dense)
    }
    Dense(current) => {
      for index in 0..<count {
        dense[index] = current[index]
      }
      self.registers = Dense(dense)
    }
  }
  dense
}

///|
/// One register's rank, for a rig that wants to look at the state rather than
/// only at the estimate. An index outside `0 <= index < register_count()` is an
/// error, not a panic.
pub fn HllSketch::register(
  self : HllSketch,
  index : Int32,
) -> Int32 raise @types.EncodingError {
  let count = self.register_count()
  if index < 0 || index >= count {
    raise @types.EncodingError::OutOfRange(
      index.to_int64(),
      count.to_int64().to_int(),
    )
  }
  self.rank_at(index)
}

///|
/// Every register's rank as a fresh `Int32` array. Until 0.1.1 this was a
/// non-copying view of the state; registers are bytes now, so the accessor
/// builds an array of the old element type (O(register_count) time and space
/// per call) and its result no longer tracks later updates. Use `register` to
/// read single ranks without that cost.
pub fn HllSketch::registers(self : HllSketch) -> ArrayView[Int32] {
  let count = self.register_count()
  let ranks : Array[Int32] = Array::make(count, 0)
  for index in 0..<count {
    ranks[index] = self.rank_at(index)
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
  self.note_rank(index, rank)
}

///|
pub fn HllSketch::add_int32(self : HllSketch, value : Int32) -> Unit {
  self.absorb_hash(
    hll_hash_short_le(value.to_int64().reinterpret_as_uint64(), 4),
  )
}

///|
pub fn HllSketch::add_int32_batch(
  self : HllSketch,
  values : ArrayView[Int32],
) -> Unit {
  for value in values {
    self.absorb_hash(
      hll_hash_short_le(value.to_int64().reinterpret_as_uint64(), 4),
    )
  }
}

///|
pub fn HllSketch::add_int64(self : HllSketch, value : Int64) -> Unit {
  self.absorb_hash(hll_hash_short_le(value.reinterpret_as_uint64(), 8))
}

///|
pub fn HllSketch::add_int64_batch(
  self : HllSketch,
  values : ArrayView[Int64],
) -> Unit {
  for value in values {
    self.absorb_hash(hll_hash_short_le(value.reinterpret_as_uint64(), 8))
  }
}

///|
pub fn HllSketch::add_float(self : HllSketch, value : Float) -> Unit {
  self.absorb_hash(
    hll_hash_short_le(value.reinterpret_as_uint().to_uint64(), 4),
  )
}

///|
pub fn HllSketch::add_float_batch(
  self : HllSketch,
  values : ArrayView[Float],
) -> Unit {
  for value in values {
    self.absorb_hash(
      hll_hash_short_le(value.reinterpret_as_uint().to_uint64(), 4),
    )
  }
}

///|
pub fn HllSketch::add_double(self : HllSketch, value : Double) -> Unit {
  self.absorb_hash(hll_hash_short_le(value.reinterpret_as_uint64(), 8))
}

///|
pub fn HllSketch::add_double_batch(
  self : HllSketch,
  values : ArrayView[Double],
) -> Unit {
  for value in values {
    self.absorb_hash(hll_hash_short_le(value.reinterpret_as_uint64(), 8))
  }
}

///|
pub fn HllSketch::add_bool(self : HllSketch, value : Bool) -> Unit {
  let bits = if value { 1UL } else { 0UL }
  self.absorb_hash(hll_hash_short_le(bits, 1))
}

///|
pub fn HllSketch::add_bool_batch(
  self : HllSketch,
  values : ArrayView[Bool],
) -> Unit {
  for value in values {
    let bits = if value { 1UL } else { 0UL }
    self.absorb_hash(hll_hash_short_le(bits, 1))
  }
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
  let merged = self.copy()
  // Dense against dense is the case a large merge actually hits, and it is the
  // same loop it always was. Walking the other sketch's live registers instead of
  // all `m` of them is what keeps the union of two sparse sketches sparse.
  match (merged.registers, other.registers) {
    (Dense(mine), Dense(theirs)) =>
      for index in 0..<theirs.length() {
        if theirs[index] > mine[index] {
          mine[index] = theirs[index]
        }
      }
    _ =>
      match other.registers {
        Dense(dense) =>
          for index in 0..<dense.length() {
            let theirs = dense[index].to_int()
            if theirs > 0 {
              merged.note_rank(index, theirs)
            }
          }
        Sparse(sparse) =>
          for slot in 0..<sparse.count {
            merged.note_rank(sparse.index(slot), sparse.rank(slot))
          }
      }
  }
  merged
}

///|
/// A deep copy in the state the source is in: a result never aliases its input,
/// and copying a sparse sketch does not expand it to dense.
fn HllSketch::copy(self : HllSketch) -> HllSketch {
  let registers = match self.registers {
    Dense(dense) => {
      let copy = FixedArray::make(dense.length(), b'\x00')
      for index in 0..<dense.length() {
        copy[index] = dense[index]
      }
      Dense(copy)
    }
    Sparse(sparse) => {
      let copy = FixedArray::make(sparse.entries.length(), 0U)
      for offset in 0..<sparse.entries.length() {
        copy[offset] = sparse.entries[offset]
      }
      Sparse({ count: sparse.count, entries: copy, })
    }
  }
  { precision: self.precision, registers, }
}

///|
/// The cardinality estimate, with linear counting over the empty registers at
/// the small end and the logarithmic correction at the large end.
pub fn HllSketch::estimate(self : HllSketch) -> Double {
  let count = self.register_count()
  let m = count.to_double()
  let mut inverse_sum = 0.0
  let mut empty = 0
  match self.registers {
    Dense(dense) =>
      for index in 0..<count {
        let rank = dense[index].to_int()
        inverse_sum = inverse_sum + hll_inverse_pow(rank)
        if rank == 0 {
          empty += 1
        }
      }
    Sparse(sparse) => {
      empty = count - sparse.count
      // A zero register contributes 2^-0 = 1 to the sum, which is why the empty
      // registers are seeded here rather than skipped: the estimator has to see
      // the same vector the dense form would hold.
      inverse_sum = empty.to_double()
      for slot in 0..<sparse.count {
        inverse_sum = inverse_sum + hll_inverse_pow(sparse.rank(slot))
      }
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
/// 2^-rank as an exact IEEE-754 power of two: bias minus rank in the exponent
/// bits, so the estimator spends one shift and no loop per register.
fn hll_inverse_pow(rank : Int32) -> Double {
  let exponent = 1023 - rank
  if exponent < 0 {
    0.0
  } else {
    (exponent.to_uint64() << 52).reinterpret_as_double()
  }
}

///|
/// The serialized form: version byte, precision byte, then one byte per
/// register, little-endian throughout.
pub fn HllSketch::to_bytes(self : HllSketch) -> Bytes {
  let count = self.register_count()
  let out = FixedArray::make(2 + count, b'\x00')
  out[0] = HLL_VERSION.to_byte()
  out[1] = self.precision.to_byte()
  match self.registers {
    Dense(dense) =>
      for index in 0..<count {
        out[2 + index] = dense[index]
      }
    Sparse(sparse) =>
      for slot in 0..<sparse.count {
        out[2 + sparse.index(slot)] = sparse.rank(slot).to_byte()
      }
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
  let limit = hll_sparse_limit(precision)
  let mut live = 0
  // One pass validates and builds the dense array while collecting sparse
  // entries in index order. Once the live count passes the promotion limit,
  // candidate collection stops and the rest of a dense stream is filled without
  // an extra branch per register; a sparse state no longer re-reads the stream.
  let registers = FixedArray::make(count, b'\x00')
  let candidates = FixedArray::make(limit + 1, 0U)
  let mut index = 0
  while index < count && live <= limit {
    let rank = bytes[2 + index]
    let rank_value = rank.to_int()
    if rank_value > ceiling {
      raise @types.EncodingError::Corrupt(2 + index)
    }
    registers[index] = rank
    if rank_value > 0 {
      candidates[live] = (index.reinterpret_as_uint() << HLL_SPARSE_RANK_BITS) |
        rank_value.reinterpret_as_uint()
      live += 1
    }
    index += 1
  }
  for index in index..<count {
    let rank = bytes[2 + index]
    if rank.to_int() > ceiling {
      raise @types.EncodingError::Corrupt(2 + index)
    }
    registers[index] = rank
  }
  if limit > 0 && live <= limit {
    let capacity = if live < 8 { 8 } else { live }
    let entries = FixedArray::make(capacity, 0U)
    for slot in 0..<live {
      entries[slot] = candidates[slot]
    }
    { precision, registers: Sparse({ count: live, entries, }), }
  } else {
    { precision, registers: Dense(registers), }
  }
}
