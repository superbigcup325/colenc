/// Roaring bitmap (E8): a compressed set of non-negative 32-bit ids, stored as
/// the portable Roaring format.
///
/// The bitmap is split by the high 16 bits of an id into containers; each
/// container holds the low 16 bits in whichever of three shapes is smallest —
/// a sorted array, a 65536-bit bitmap, or a list of runs. Container choice is a
/// choice bit, so it is pinned to the reference (CRoaring, through pyroaring):
/// an array while a container holds at most 4096 values, a bitmap above that,
/// and a run container only when `run_optimize` finds the run form *strictly*
/// smaller. Serialization follows the portable format's own choice bits too:
/// the offset table is written whenever there are no run containers, and for
/// run-carrying bitmaps only once there are at least four containers.
///
/// The encoding is a set encoding: a column is the set of its ids, so order and
/// duplicates do not survive a round trip and a decode returns the ids in
/// ascending order. Ids are non-negative INT32 (0..2^31-1); the upper half of
/// the format's u32 id space needs a column type this model does not have yet,
/// so it is rejected with a typed error rather than truncated.

///|
/// The portable format's cookie for a bitmap without run containers.
const ROARING_COOKIE_NO_RUN : Int32 = 12346

///|
/// The portable format's cookie for a bitmap with at least one run container.
const ROARING_COOKIE_RUN : Int32 = 12347

///|
/// Below this many containers the offset table is omitted when runs are present.
const ROARING_NO_OFFSET_THRESHOLD : Int32 = 4

///|
/// The largest cardinality an array container holds before it becomes a bitmap.
const ROARING_ARRAY_MAX : Int32 = 4096

///|
/// Low-half values per container: 2^16 bits.
const ROARING_CONTAINER_VALUES : Int32 = 65536

///|
/// 64-bit words in a bitmap container.
const ROARING_WORDS : Int32 = 1024

///|
/// The largest id the surface accepts (INT32, non-negative).
const ROARING_MAX_ID : Int32 = 2147483647

///|
/// One container's storage. Invariants: array values are sorted, run pairs are
/// (start, length - 1) in ascending order, and a bitmap container carries more
/// than `ROARING_ARRAY_MAX` values.
priv enum RoaringContainer {
  ArrayContainer(Array[Int32])
  BitmapContainer(Array[Int64])
  RunContainer(Array[Int32])
}

///|
/// A Roaring bitmap. Containers are sorted by key and never empty.
pub(all) struct RoaringBitmap {
  priv keys : Array[Int32]
  priv containers : Array[RoaringContainer]
}

///|
pub fn RoaringBitmap::new() -> RoaringBitmap {
  { keys: [], containers: [], }
}

///|
fn roaring_read_u16(
  data : BytesView,
  offset : Int32,
) -> Int32 raise @types.EncodingError {
  if offset + 2 > data.length() {
    raise @types.EncodingError::Truncated(offset, 2, data.length() - offset)
  }
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
fn roaring_read_u32(
  data : BytesView,
  offset : Int32,
) -> Int32 raise @types.EncodingError {
  if offset + 4 > data.length() {
    raise @types.EncodingError::Truncated(offset, 4, data.length() - offset)
  }
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
fn roaring_write_u16(out : @buffer.Buffer, value : Int32) -> Unit {
  out.write_byte((value & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
fn container_cardinality(container : RoaringContainer) -> Int32 {
  match container {
    ArrayContainer(values) => values.length()
    BitmapContainer(words) => {
      let mut total = 0
      for word in words {
        total += word.popcnt()
      }
      total
    }
    RunContainer(runs) => {
      let mut total = 0
      let mut index = 0
      while index < runs.length() {
        total += runs[index + 1] + 1
        index += 2
      }
      total
    }
  }
}

///|
fn container_byte_size(container : RoaringContainer) -> Int32 {
  match container {
    ArrayContainer(values) => 2 * values.length()
    BitmapContainer(_) => 8 * ROARING_WORDS
    RunContainer(runs) => 2 + 2 * runs.length()
  }
}

///|
fn container_of_sorted_values(values : Array[Int32]) -> RoaringContainer {
  if values.length() <= ROARING_ARRAY_MAX {
    ArrayContainer(values)
  } else {
    BitmapContainer(bitmap_words_of(values))
  }
}

///|
fn merge_sorted_unique(
  left : Array[Int32],
  right : Array[Int32],
) -> Array[Int32] {
  let merged : Array[Int32] = []
  let mut i = 0
  let mut j = 0
  let left_len = left.length()
  let right_len = right.length()
  while i < left_len && j < right_len {
    let a = left[i]
    let b = right[j]
    if a < b {
      merged.push(a)
      i += 1
    } else if b < a {
      merged.push(b)
      j += 1
    } else {
      merged.push(a)
      i += 1
      j += 1
    }
  }
  while i < left_len {
    merged.push(left[i])
    i += 1
  }
  while j < right_len {
    merged.push(right[j])
    j += 1
  }
  merged
}

///|
fn intersect_sorted(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let shared : Array[Int32] = []
  let mut i = 0
  let mut j = 0
  let left_len = left.length()
  let right_len = right.length()
  while i < left_len && j < right_len {
    let a = left[i]
    let b = right[j]
    if a < b {
      i += 1
    } else if b < a {
      j += 1
    } else {
      shared.push(a)
      i += 1
      j += 1
    }
  }
  shared
}

///|
fn filter_sorted_by_words(
  values : Array[Int32],
  words : Array[Int64],
) -> Array[Int32] {
  let kept : Array[Int32] = []
  for value in values {
    let word = value >> 6
    let bit = 1L << (value & 63)
    if (words[word] & bit) != 0L {
      kept.push(value)
    }
  }
  kept
}

///|
fn bitmap_words_of(values : Array[Int32]) -> Array[Int64] {
  let words : Array[Int64] = Array::make(ROARING_WORDS, 0L)
  for value in values {
    let word = value >> 6
    words[word] = words[word] | (1L << (value & 63))
  }
  words
}

///|
fn values_of_bitmap_words(words : Array[Int64]) -> Array[Int32] {
  let values : Array[Int32] = []
  for index in 0..<ROARING_WORDS {
    let mut word = words[index]
    while word != 0L {
      let lowest = word & -word
      values.push((index << 6) + lowest.ctz())
      word = word & (word - 1L)
    }
  }
  values
}

///|
fn runs_of_values(values : Array[Int32]) -> Array[Int32] {
  let runs : Array[Int32] = []
  let mut index = 0
  while index < values.length() {
    let start = values[index]
    let mut last = start
    index += 1
    while index < values.length() && values[index] == last + 1 {
      last = values[index]
      index += 1
    }
    runs.push(start)
    runs.push(last - start)
  }
  runs
}

///|
fn values_of_runs(runs : Array[Int32]) -> Array[Int32] {
  let values : Array[Int32] = []
  let mut index = 0
  while index < runs.length() {
    let start = runs[index]
    let length = runs[index + 1] + 1
    for step in 0..<length {
      values.push(start + step)
    }
    index += 2
  }
  values
}

///|
fn container_values(container : RoaringContainer) -> Array[Int32] {
  match container {
    ArrayContainer(values) => values
    BitmapContainer(words) => values_of_bitmap_words(words)
    RunContainer(runs) => values_of_runs(runs)
  }
}

///|
fn container_words(container : RoaringContainer) -> Array[Int64] {
  match container {
    ArrayContainer(values) => bitmap_words_of(values)
    BitmapContainer(words) => words.copy()
    RunContainer(runs) => bitmap_words_of(values_of_runs(runs))
  }
}

///|
/// Build the container a set of low-half values deserves: an array while it
/// fits, a bitmap once it does not.
fn container_of_values(values : Array[Int32]) -> RoaringContainer {
  if values.length() <= ROARING_ARRAY_MAX {
    ArrayContainer(values)
  } else {
    BitmapContainer(bitmap_words_of(values))
  }
}

///|
fn container_of_words(words : Array[Int64]) -> RoaringContainer {
  // The shape follows the cardinality the operation produced. Counting is one
  // popcount per word; enumerating mirrors every set bit and the values are
  // thrown away when the result stays a bitmap, which is the common case for a
  // dense container.
  let mut total = 0
  for word in words {
    total += word.popcnt()
  }
  if total <= ROARING_ARRAY_MAX {
    ArrayContainer(values_of_bitmap_words(words))
  } else {
    BitmapContainer(words)
  }
}

///|
fn sorted_position(values : Array[Int32], value : Int32) -> Int32 {
  let mut low = 0
  let mut high = values.length()
  while low < high {
    let mid = (low + high) >> 1
    if values[mid] < value {
      low = mid + 1
    } else {
      high = mid
    }
  }
  low
}

///|
fn container_contains(container : RoaringContainer, low : Int32) -> Bool {
  match container {
    ArrayContainer(values) => {
      let position = sorted_position(values, low)
      position < values.length() && values[position] == low
    }
    BitmapContainer(words) => {
      let word = words[low >> 6]
      ((word >> (low & 63)) & 1L) == 1L
    }
    RunContainer(runs) => {
      let mut lowrun = 0
      let mut highrun = runs.length() / 2
      let mut found = false
      while lowrun < highrun {
        let mid = (lowrun + highrun) >> 1
        let start = runs[mid * 2]
        if start <= low {
          if low <= start + runs[mid * 2 + 1] {
            found = true
            break
          }
          lowrun = mid + 1
        } else {
          highrun = mid
        }
      }
      found
    }
  }
}

///|
/// Deep copy a container, so a result can never alias an operand's storage.
fn container_copy(container : RoaringContainer) -> RoaringContainer {
  match container {
    ArrayContainer(values) => ArrayContainer(values.copy())
    BitmapContainer(words) => BitmapContainer(words.copy())
    RunContainer(runs) => RunContainer(runs.copy())
  }
}

///|
/// Add one low-half value to a container. A run container is de-optimised into
/// an array or bitmap first; call `run_optimize` after a batch of adds.
///
/// The shape is chosen from the cardinality the add *produces*, never from the
/// cardinality it started with: an array must not grow past `ROARING_ARRAY_MAX`
/// and a bitmap must stay above it, or the writer (which serializes by shape)
/// and the reader (which picks the shape by cardinality) disagree on the body.
fn container_add(container : RoaringContainer, low : Int32) -> RoaringContainer {
  if container_contains(container, low) {
    return container
  }
  match container {
    ArrayContainer(values) => {
      let position = sorted_position(values, low)
      values.insert(position, low)
      container_of_values(values)
    }
    BitmapContainer(words) => {
      let word = low >> 6
      words[word] = words[word] | (1L << (low & 63))
      BitmapContainer(words)
    }
    RunContainer(runs) => {
      let values = values_of_runs(runs)
      let position = sorted_position(values, low)
      values.insert(position, low)
      container_of_values(values)
    }
  }
}

///|
fn container_union(
  left : RoaringContainer,
  right : RoaringContainer,
) -> RoaringContainer {
  // Two array containers already hold sorted values, so merging them visits
  // each value once. Going through 1024 words instead materializes 8 KB per
  // operand and then enumerates the result again, which is what a small
  // container pays for nothing (measured at 68 ns per id against 0.4 ns for a
  // bitmap container on the same call).
  match (left, right) {
    (ArrayContainer(a), ArrayContainer(b)) =>
      container_of_sorted_values(merge_sorted_unique(a, b))
    (ArrayContainer(a), BitmapContainer(words))
    | (BitmapContainer(words), ArrayContainer(a)) => {
      let merged = words.copy()
      for value in a {
        let word = value >> 6
        merged[word] = merged[word] | (1L << (value & 63))
      }
      container_of_words(merged)
    }
    _ => {
      let words = container_words(left)
      let other = container_words(right)
      for index in 0..<ROARING_WORDS {
        words[index] = words[index] | other[index]
      }
      container_of_words(words)
    }
  }
}

///|
fn container_intersect(
  left : RoaringContainer,
  right : RoaringContainer,
) -> RoaringContainer {
  // An intersection is never larger than either operand, so every array path
  // here stays an array container: no word array is built and no shape decision
  // is needed.
  match (left, right) {
    (ArrayContainer(a), ArrayContainer(b)) =>
      ArrayContainer(intersect_sorted(a, b))
    (ArrayContainer(a), BitmapContainer(words))
    | (BitmapContainer(words), ArrayContainer(a)) =>
      ArrayContainer(filter_sorted_by_words(a, words))
    _ => {
      let words = container_words(left)
      let other = container_words(right)
      for index in 0..<ROARING_WORDS {
        words[index] = words[index] & other[index]
      }
      container_of_words(words)
    }
  }
}

///|
fn container_is_empty(container : RoaringContainer) -> Bool {
  match container {
    ArrayContainer(values) => values.length() == 0
    BitmapContainer(words) => {
      let mut empty = true
      for word in words {
        if word != 0L {
          empty = false
          break
        }
      }
      empty
    }
    RunContainer(runs) => runs.length() == 0
  }
}

///|
/// Build a bitmap from ids in any order. Ids must be non-negative INT32.
///
/// One validation pass also decides whether the input is ascending, which is
/// how a sorted column usually arrives (a dictionary index, an id list). A
/// sorted input is built container by container in a single walk; an unsorted
/// one falls back to inserting id by id. Both produce the same containers,
/// because the shape rule looks at the cardinality a container ends with.
pub fn RoaringBitmap::from_ids(
  ids : Array[Int32],
) -> RoaringBitmap raise @types.EncodingError {
  let mut ascending = true
  for index in 0..<ids.length() {
    let id = ids[index]
    if id < 0 || id > ROARING_MAX_ID {
      raise @types.EncodingError::OutOfRange(id.to_int64(), index)
    }
    if index > 0 && id < ids[index - 1] {
      ascending = false
    }
  }
  if ascending {
    return from_ascending_ids(ids)
  }
  let bitmap = RoaringBitmap::new()
  for id in ids {
    bitmap.add(id)
  }
  bitmap
}

///|
/// Build from ascending ids, one container per key, without a single insert.
/// The shape comes from the distinct count of the whole key run, which is what
/// repeated `add` calls would have settled on: an array up to 4096 values and a
/// bitmap above that. Only `run_optimize` turns a container into runs.
fn from_ascending_ids(ids : Array[Int32]) -> RoaringBitmap {
  let total = ids.length()
  // Ascending ids occupy the keys between the first and the last one, so that
  // span bounds the container count without a second pass over the ids (a
  // per-id key comparison cost 5% on the dense cases). A sparse id column is
  // mostly one-value containers, so reserving the right capacity is worth it:
  // growing the two arrays one push at a time was measurable here.
  let mut estimate : Int32 = 0
  if total > 0 {
    let first_key : Int32 = ids[0] >> 16
    let last_key : Int32 = ids[total - 1] >> 16
    // Int32 has no `to_int` in this toolchain, so the subtraction goes wide.
    let span : Int32 = (last_key - first_key).to_int64().to_int() + 1
    estimate = if span < total { span } else { total }
  }
  let keys : Array[Int32] = Array(capacity=estimate)
  let containers : Array[RoaringContainer] = Array(capacity=estimate)
  let mut start = 0
  while start < total {
    let key = ids[start] >> 16
    // One walk finds the key run and counts the distinct lows in it: the count
    // used to be a second pass, and the extra pass was a third of the build
    // time on a sparse column.
    let mut end = start
    let mut distinct = 0
    let mut previous_low : Int32 = -1
    while end < total && ids[end] >> 16 == key {
      let low = ids[end] & 0xFFFF
      if low != previous_low {
        distinct += 1
        previous_low = low
      }
      end += 1
    }
    keys.push(key)
    if distinct <= ROARING_ARRAY_MAX {
      // Exact size, filled by index: one allocation of `2 * distinct` bytes.
      // Every slot is written by the loop below, so the zero pass is skipped.
      let values : Array[Int32] = Array::unsafe_make_uninit(distinct)
      let mut previous = -1
      let mut value_slot = 0
      for index in start..<end {
        let low = ids[index] & 0xFFFF
        if low != previous {
          values[value_slot] = low
          value_slot += 1
          previous = low
        }
      }
      containers.push(ArrayContainer(values))
    } else {
      let words : Array[Int64] = Array::make(ROARING_WORDS, 0L)
      for index in start..<end {
        let low = ids[index] & 0xFFFF
        let word = low >> 6
        words[word] = words[word] | (1L << (low & 63))
      }
      containers.push(BitmapContainer(words))
    }
    start = end
  }
  { keys, containers, }
}

///|
/// Add one id. Ids outside the representable range raise.
pub fn RoaringBitmap::add(
  self : RoaringBitmap,
  id : Int32,
) -> Unit raise @types.EncodingError {
  if id < 0 || id > ROARING_MAX_ID {
    raise @types.EncodingError::OutOfRange(id.to_int64(), -1)
  }
  let key = id >> 16
  let low = id & 0xFFFF
  let position = sorted_position(self.keys, key)
  if position < self.keys.length() && self.keys[position] == key {
    self.containers[position] = container_add(self.containers[position], low)
  } else {
    self.keys.insert(position, key)
    self.containers.insert(position, container_of_values([low]))
  }
}

///|
pub fn RoaringBitmap::contains(self : RoaringBitmap, id : Int32) -> Bool {
  if id < 0 || id > ROARING_MAX_ID {
    return false
  }
  let key = id >> 16
  let position = sorted_position(self.keys, key)
  if position >= self.keys.length() || self.keys[position] != key {
    return false
  }
  container_contains(self.containers[position], id & 0xFFFF)
}

///|
pub fn RoaringBitmap::cardinality(self : RoaringBitmap) -> Int32 {
  let mut total = 0
  for container in self.containers {
    total += container_cardinality(container)
  }
  total
}

///|
pub fn RoaringBitmap::is_empty(self : RoaringBitmap) -> Bool {
  self.keys.length() == 0
}

///|
/// The ids in ascending order.
pub fn RoaringBitmap::to_array(self : RoaringBitmap) -> Array[Int32] {
  let ids : Array[Int32] = []
  for index in 0..<self.keys.length() {
    let key = self.keys[index]
    for low in container_values(self.containers[index]) {
      ids.push((key << 16) | low)
    }
  }
  ids
}

///|
/// The union of two bitmaps. The result owns its containers: a container that
/// only one side carries is copied, so mutating the result never rewrites an
/// operand (and vice versa).
pub fn RoaringBitmap::union(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result = RoaringBitmap::new()
  let mut left = 0
  let mut right = 0
  while left < self.keys.length() || right < other.keys.length() {
    if right >= other.keys.length() ||
      (left < self.keys.length() && self.keys[left] < other.keys[right]) {
      result.keys.push(self.keys[left])
      result.containers.push(container_copy(self.containers[left]))
      left += 1
    } else if left >= self.keys.length() || other.keys[right] < self.keys[left] {
      result.keys.push(other.keys[right])
      result.containers.push(container_copy(other.containers[right]))
      right += 1
    } else {
      result.keys.push(self.keys[left])
      result.containers.push(
        container_union(self.containers[left], other.containers[right]),
      )
      left += 1
      right += 1
    }
  }
  result
}

///|
pub fn RoaringBitmap::intersect(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result = RoaringBitmap::new()
  let mut left = 0
  let mut right = 0
  while left < self.keys.length() && right < other.keys.length() {
    if self.keys[left] < other.keys[right] {
      left += 1
    } else if other.keys[right] < self.keys[left] {
      right += 1
    } else {
      let container = container_intersect(
        self.containers[left],
        other.containers[right],
      )
      if !container_is_empty(container) {
        result.keys.push(self.keys[left])
        result.containers.push(container)
      }
      left += 1
      right += 1
    }
  }
  result
}

///|
/// Replace containers whose run form is strictly smaller than their current
/// form. Equal sizes keep the current form, matching the reference.
pub fn RoaringBitmap::run_optimize(self : RoaringBitmap) -> Unit {
  for index in 0..<self.keys.length() {
    let container = self.containers[index]
    match container {
      RunContainer(_) => ()
      _ => {
        let runs = runs_of_values(container_values(container))
        let run_size = 2 + 2 * runs.length()
        if run_size < container_byte_size(container) {
          self.containers[index] = RunContainer(runs)
        }
      }
    }
  }
}

///|
fn write_container(container : RoaringContainer, out : @buffer.Buffer) -> Unit {
  match container {
    ArrayContainer(values) =>
      for value in values {
        roaring_write_u16(out, value)
      }
    BitmapContainer(words) =>
      for word in words {
        out.write_int64_le(word)
      }
    RunContainer(runs) => {
      roaring_write_u16(out, runs.length() / 2)
      for value in runs {
        roaring_write_u16(out, value)
      }
    }
  }
}

///|
/// The serialized form is written in one pass over the containers: this walks
/// the containers once to collect what every later table needs (each card, each
/// body size, whether any container is a run) and to add up the exact byte
/// count, and only then writes. Two matches per container instead of four, and
/// a buffer that never grows.
fn RoaringBitmap::roaring_serialized_plan(
  self : RoaringBitmap,
) -> (Array[Int32], Array[Int32], Array[Int32], Bool, Int32) {
  let size = self.keys.length()
  let cards : Array[Int32] = Array::make(size, 0)
  let sizes : Array[Int32] = Array::make(size, 0)
  let run_bytes = (size + 7) / 8
  let flags : Array[Int32] = Array::make(run_bytes, 0)
  let mut bodies = 0
  let mut with_runs = false
  for index in 0..<size {
    let (card, bytes, is_run) = match self.containers[index] {
      ArrayContainer(values) => {
        let count = values.length()
        (count, 2 * count, false)
      }
      BitmapContainer(words) => {
        let mut count = 0
        for word in words {
          count += word.popcnt()
        }
        (count, 8 * ROARING_WORDS, false)
      }
      RunContainer(runs) => {
        // `runs` holds a start and a length-minus-one per pair, which is what
        // `container_cardinality` and the reader both assume
        let mut count = 0
        let mut pair = 0
        while pair < runs.length() {
          count += runs[pair + 1] + 1
          pair += 2
        }
        (count, 2 + 2 * runs.length(), true)
      }
    }
    cards[index] = card
    sizes[index] = bytes
    bodies += bytes
    if is_run {
      with_runs = true
      flags[index / 8] = flags[index / 8] | (1 << (index % 8))
    }
  }
  let header = if with_runs { 4 + run_bytes } else { 8 }
  let offsets = if !with_runs || size >= ROARING_NO_OFFSET_THRESHOLD {
    4 * size
  } else {
    0
  }
  (cards, sizes, flags, with_runs, header + 4 * size + offsets + bodies)
}

///|
fn RoaringBitmap::roaring_write_plan(
  self : RoaringBitmap,
  out : @buffer.Buffer,
  cards : Array[Int32],
  sizes : Array[Int32],
  flags : Array[Int32],
  with_runs : Bool,
) -> Unit {
  let size = self.keys.length()
  if with_runs {
    out.write_int_le(ROARING_COOKIE_RUN | ((size - 1) << 16))
    for flag in flags {
      out.write_byte(flag.to_byte())
    }
  } else {
    out.write_int_le(ROARING_COOKIE_NO_RUN)
    out.write_int_le(size)
  }
  for index in 0..<size {
    roaring_write_u16(out, self.keys[index])
    roaring_write_u16(out, cards[index] - 1)
  }
  if !with_runs || size >= ROARING_NO_OFFSET_THRESHOLD {
    let mut offset = out.length() + 4 * size
    for index in 0..<size {
      out.write_int_le(offset)
      offset += sizes[index]
    }
  }
  for container in self.containers {
    write_container(container, out)
  }
}

///|
/// Append the portable Roaring serialization.
pub fn RoaringBitmap::serialize(
  self : RoaringBitmap,
  out : @buffer.Buffer,
) -> Unit {
  let (cards, sizes, flags, with_runs, _) = self.roaring_serialized_plan()
  self.roaring_write_plan(out, cards, sizes, flags, with_runs)
}

///|
/// The portable Roaring serialization as a fresh buffer.
pub fn RoaringBitmap::to_bytes(self : RoaringBitmap) -> Bytes {
  let (cards, sizes, flags, with_runs, total) = self.roaring_serialized_plan()
  let out = @buffer.Buffer(size_hint=total)
  self.roaring_write_plan(out, cards, sizes, flags, with_runs)
  out.to_bytes()
}

///|
/// Parse the portable Roaring serialization. Trailing bytes are the caller's:
/// the container table is self-delimiting, so `bytes_read` is returned for a
/// caller that carries more than one bitmap in a stream.
pub fn RoaringBitmap::from_bytes(
  data : BytesView,
) -> RoaringBitmap raise @types.EncodingError {
  RoaringBitmap::from_bytes_with_consumed(data).0
}

///|
/// Like `from_bytes`, but also reports how many bytes the bitmap occupied.
pub fn RoaringBitmap::from_bytes_with_consumed(
  data : BytesView,
) -> (RoaringBitmap, Int32) raise @types.EncodingError {
  let cookie = roaring_read_u32(data, 0)
  let mut position = 4
  let with_runs = (cookie & 0xFFFF) == ROARING_COOKIE_RUN
  let size = if with_runs {
    (cookie >> 16) + 1
  } else if (cookie & 0xFFFF) == ROARING_COOKIE_NO_RUN {
    let declared = roaring_read_u32(data, 4)
    position = 8
    if declared < 0 {
      raise @types.EncodingError::Corrupt(4)
    }
    declared
  } else {
    raise @types.EncodingError::InvalidTag(cookie & 0xFFFF)
  }
  let flags : Array[Bool] = Array::make(size, false)
  if with_runs {
    let run_bytes = (size + 7) / 8
    if position + run_bytes > data.length() {
      raise @types.EncodingError::Truncated(
        position,
        run_bytes,
        data.length() - position,
      )
    }
    let mut seen_run = false
    for index in 0..<size {
      let byte = data[position + index / 8].to_int()
      let is_run = ((byte >> (index % 8)) & 1) == 1
      flags[index] = is_run
      if is_run {
        seen_run = true
      }
    }
    if !seen_run {
      raise @types.EncodingError::Corrupt(position)
    }
    position += run_bytes
  }
  // The key/card table and the offset table are read with one bounds check per
  // table and cursor arithmetic in the loops: a per-value `roaring_read_u16`
  // costs a call and a redundant length check, and these tables are walked
  // once per container.
  if position + 4 * size > data.length() {
    raise @types.EncodingError::Truncated(
      position,
      4 * size,
      data.length() - position,
    )
  }
  let keys : Array[Int32] = Array::make(size, 0)
  let cards : Array[Int32] = Array::make(size, 0)
  let mut cursor = position
  for index in 0..<size {
    keys[index] = data.unsafe_read_uint16_le(cursor).to_int()
    cards[index] = data.unsafe_read_uint16_le(cursor + 2).to_int() + 1
    cursor += 4
    if index > 0 && keys[index] <= keys[index - 1] {
      raise @types.EncodingError::Corrupt(cursor - 4)
    }
    if cards[index] < 1 || cards[index] > ROARING_CONTAINER_VALUES {
      raise @types.EncodingError::Corrupt(cursor - 2)
    }
  }
  position = cursor
  let offsets : Array[Int32] = Array::make(size, 0)
  let has_offsets = !with_runs || size >= ROARING_NO_OFFSET_THRESHOLD
  if has_offsets {
    if position + 4 * size > data.length() {
      raise @types.EncodingError::Truncated(
        position,
        4 * size,
        data.length() - position,
      )
    }
    for index in 0..<size {
      offsets[index] = data.unsafe_read_uint32_le(cursor).reinterpret_as_int()
      cursor += 4
    }
    position = cursor
  }
  let containers : Array[RoaringContainer] = Array::make(
    size,
    ArrayContainer([]),
  )
  for index in 0..<size {
    if has_offsets && offsets[index] != position {
      raise @types.EncodingError::Corrupt(position)
    }
    let container = if flags[index] {
      let run_count = roaring_read_u16(data, position)
      position += 2
      let count = 2 * run_count
      if position + 2 * count > data.length() {
        raise @types.EncodingError::Truncated(
          position,
          2 * count,
          data.length() - position,
        )
      }
      // Both slots of every pair are written by the loop below, so the zero
      // pass is skipped; an error drops the array rather than exposing it.
      let pairs : Array[Int32] = Array::unsafe_make_uninit(count)
      let mut counted = 0
      for run in 0..<run_count {
        let start = data.unsafe_read_uint16_le(position).to_int()
        let length_minus_one = data.unsafe_read_uint16_le(position + 2).to_int()
        pairs[2 * run] = start
        pairs[2 * run + 1] = length_minus_one
        counted += length_minus_one + 1
        position += 4
      }
      if counted != cards[index] {
        raise @types.EncodingError::Corrupt(position)
      }
      RunContainer(pairs)
    } else if cards[index] <= ROARING_ARRAY_MAX {
      let card = cards[index]
      let needed = 2 * card
      if position + needed > data.length() {
        raise @types.EncodingError::Truncated(
          position,
          needed,
          data.length() - position,
        )
      }
      let values : Array[Int32] = Array::unsafe_make_uninit(card)
      let mut previous : Int32 = -1
      for value in 0..<card {
        let current = data.unsafe_read_uint16_le(position).to_int()
        if current <= previous {
          raise @types.EncodingError::Corrupt(position)
        }
        values[value] = current
        previous = current
        position += 2
      }
      ArrayContainer(values)
    } else {
      let words : Array[Int64] = Array::unsafe_make_uninit(ROARING_WORDS)
      if position + 8 * ROARING_WORDS > data.length() {
        raise @types.EncodingError::Truncated(
          position,
          8 * ROARING_WORDS,
          data.length() - position,
        )
      }
      // The card table's word is checked here rather than by a second walk over
      // the same 8 KB: the counts come out of the read.
      let mut counted = 0
      for word in 0..<ROARING_WORDS {
        let value = data
          .unsafe_read_uint64_le(position + word * 8)
          .reinterpret_as_int64()
        words[word] = value
        counted += value.popcnt()
      }
      position += 8 * ROARING_WORDS
      if counted != cards[index] {
        raise @types.EncodingError::Corrupt(position)
      }
      BitmapContainer(words)
    }
    // Each branch has already compared what it built against the card table: a
    // bitmap container counts its words, a run container adds its lengths, and
    // an array container is read by length, so its cardinality is the card word
    // by construction and there is nothing left to check here.
    containers[index] = container
  }
  ({ keys, containers, }, position)
}

///|
/// Encode a column of non-negative INT32 ids as a Roaring bitmap, appending to
/// `out`. The column is a set: duplicates are ignored and the decode returns
/// the ids ascending.
pub fn encode_roaring(
  values : Array[Int32],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let ids : Array[Int32] = Array::make(values.length(), 0)
  for index in 0..<values.length() {
    let value = values[index]
    if value < 0 {
      raise @types.EncodingError::OutOfRange(value.to_int64(), index)
    }
    ids[index] = value
  }
  let bitmap = RoaringBitmap::from_ids(ids)
  bitmap.serialize(out)
}

///|
/// Decode a Roaring bitmap back into an ascending, duplicate-free INT32 column.
pub fn decode_roaring(
  data : BytesView,
) -> Array[Int32] raise @types.EncodingError {
  let ids = RoaringBitmap::from_bytes(data).to_array()
  let values : Array[Int32] = Array::make(ids.length(), 0)
  for index in 0..<ids.length() {
    values[index] = ids[index]
  }
  values
}

///|
/// Encode with the run optimisation applied first, so containers with few runs
/// serialize as runs. Off by default to match the reference's incremental path.
pub fn encode_roaring_run_optimized(
  values : Array[Int32],
  out : @buffer.Buffer,
) -> Unit raise @types.EncodingError {
  let ids : Array[Int32] = Array::make(values.length(), 0)
  for index in 0..<values.length() {
    let value = values[index]
    if value < 0 {
      raise @types.EncodingError::OutOfRange(value.to_int64(), index)
    }
    ids[index] = value
  }
  let bitmap = RoaringBitmap::from_ids(ids)
  bitmap.run_optimize()
  bitmap.serialize(out)
}
