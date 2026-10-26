/// Read-side queries on a Roaring bitmap that never build a result bitmap:
/// the size of an intersection, an overlap test that stops at the first shared
/// id, and ascending id batches that do not expand the whole bitmap first.
///
/// Rules callers can rely on:
///
/// - counts are `Int32`, the width `cardinality` already uses
/// - `ids_after` is stateless. The cursor is the last id the caller received, so
///   there is no iterator to invalidate: a bitmap that changes between calls
///   simply answers for its current content. A batch shorter than `limit` means
///   the bitmap is exhausted
/// - operands are never modified, and nothing returned aliases them

///|
/// Count the values two sorted arrays share, stopping at the first one when
/// `first_only` is set.
fn count_sorted_shared(
  left : Array[Int32],
  right : Array[Int32],
  first_only : Bool,
) -> Int32 {
  let mut i = 0
  let mut j = 0
  let mut shared = 0
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
      shared += 1
      if first_only {
        return shared
      }
      i += 1
      j += 1
    }
  }
  shared
}

///|
fn count_sorted_in_words(
  values : Array[Int32],
  words : Array[Int64],
  first_only : Bool,
) -> Int32 {
  let mut shared = 0
  for value in values {
    if (words[value >> 6] & (1L << (value & 63))) != 0L {
      shared += 1
      if first_only {
        return shared
      }
    }
  }
  shared
}

///|
/// Both inputs ascend, so one forward walk over the runs serves every value.
fn count_sorted_in_runs(
  values : Array[Int32],
  runs : Array[Int32],
  first_only : Bool,
) -> Int32 {
  let run_count = runs.length() / 2
  let mut run = 0
  let mut shared = 0
  for value in values {
    while run < run_count && runs[run * 2] + runs[run * 2 + 1] < value {
      run += 1
    }
    if run >= run_count {
      break
    }
    if runs[run * 2] <= value {
      shared += 1
      if first_only {
        return shared
      }
    }
  }
  shared
}

///|
fn count_words_and(
  left : Array[Int64],
  right : Array[Int64],
  first_only : Bool,
) -> Int32 {
  let mut shared = 0
  for index in 0..<ROARING_WORDS {
    let both = left[index] & right[index]
    if both != 0L {
      shared += both.popcnt()
      if first_only {
        return shared
      }
    }
  }
  shared
}

///|
/// Set bits of `words` in the inclusive range `start..=end`.
fn count_words_range(words : Array[Int64], start : Int32, end : Int32) -> Int32 {
  let first = start >> 6
  let last = end >> 6
  let low_mask = -1L << (start & 63)
  let high_bits = end & 63
  let high_mask = if high_bits == 63 {
    -1L
  } else {
    (1L << (high_bits + 1)) - 1L
  }
  if first == last {
    (words[first] & low_mask & high_mask).popcnt()
  } else {
    let mut total = (words[first] & low_mask).popcnt()
    for index in (first + 1)..<last {
      total += words[index].popcnt()
    }
    total + (words[last] & high_mask).popcnt()
  }
}

///|
fn count_runs_in_words(
  runs : Array[Int32],
  words : Array[Int64],
  first_only : Bool,
) -> Int32 {
  let mut shared = 0
  let mut index = 0
  while index < runs.length() {
    let start = runs[index]
    shared += count_words_range(words, start, start + runs[index + 1])
    if first_only && shared > 0 {
      return shared
    }
    index += 2
  }
  shared
}

///|
fn count_runs_shared(
  left : Array[Int32],
  right : Array[Int32],
  first_only : Bool,
) -> Int32 {
  let mut i = 0
  let mut j = 0
  let mut shared = 0
  while i < left.length() && j < right.length() {
    let left_start = left[i]
    let left_end = left_start + left[i + 1]
    let right_start = right[j]
    let right_end = right_start + right[j + 1]
    let low = if left_start > right_start { left_start } else { right_start }
    let high = if left_end < right_end { left_end } else { right_end }
    if low <= high {
      shared += high - low + 1
      if first_only {
        return shared
      }
    }
    if left_end < right_end {
      i += 2
    } else {
      j += 2
    }
  }
  shared
}

///|
/// Ids two containers share, without building the intersection. With
/// `first_only` the count is only meaningful as zero or non-zero.
fn container_shared_count(
  left : RoaringContainer,
  right : RoaringContainer,
  first_only : Bool,
) -> Int32 {
  match (left, right) {
    (ArrayContainer(a), ArrayContainer(b)) =>
      count_sorted_shared(a, b, first_only)
    (ArrayContainer(a), BitmapContainer(words))
    | (BitmapContainer(words), ArrayContainer(a)) =>
      count_sorted_in_words(a, words, first_only)
    (ArrayContainer(a), RunContainer(runs))
    | (RunContainer(runs), ArrayContainer(a)) =>
      count_sorted_in_runs(a, runs, first_only)
    (BitmapContainer(a), BitmapContainer(b)) =>
      count_words_and(a, b, first_only)
    (BitmapContainer(words), RunContainer(runs))
    | (RunContainer(runs), BitmapContainer(words)) =>
      count_runs_in_words(runs, words, first_only)
    (RunContainer(a), RunContainer(b)) => count_runs_shared(a, b, first_only)
  }
}

///|
/// The number of ids both bitmaps hold, equal to
/// `self.intersect(other).cardinality()` without materializing the result.
pub fn RoaringBitmap::intersection_cardinality(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Int32 {
  let mut total = 0
  let mut left = 0
  let mut right = 0
  while left < self.keys.length() && right < other.keys.length() {
    if self.keys[left] < other.keys[right] {
      left += 1
    } else if other.keys[right] < self.keys[left] {
      right += 1
    } else {
      total += container_shared_count(
        self.containers[left],
        other.containers[right],
        false,
      )
      left += 1
      right += 1
    }
  }
  total
}

///|
/// Whether the two bitmaps share at least one id. Stops at the first shared id.
pub fn RoaringBitmap::intersects(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Bool {
  let mut left = 0
  let mut right = 0
  while left < self.keys.length() && right < other.keys.length() {
    if self.keys[left] < other.keys[right] {
      left += 1
    } else if other.keys[right] < self.keys[left] {
      right += 1
    } else {
      if container_shared_count(
          self.containers[left],
          other.containers[right],
          true,
        ) >
        0 {
        return true
      }
      left += 1
      right += 1
    }
  }
  false
}

///|
/// Append up to `limit - out.length()` ids of one container that are at least
/// `from_low`, in ascending order, each combined with the container's key.
fn container_push_from(
  container : RoaringContainer,
  key : Int32,
  from_low : Int32,
  limit : Int32,
  out : Array[Int32],
) -> Unit {
  let base = key << 16
  match container {
    ArrayContainer(values) => {
      let mut index = sorted_position(values, from_low)
      while index < values.length() && out.length() < limit {
        out.push(base | values[index])
        index += 1
      }
    }
    BitmapContainer(words) => {
      let mut word_index = from_low >> 6
      let mut word = words[word_index] & (-1L << (from_low & 63))
      while true {
        while word != 0L && out.length() < limit {
          out.push(base | ((word_index << 6) + word.ctz()))
          word = word & (word - 1L)
        }
        if out.length() >= limit {
          break
        }
        word_index += 1
        if word_index >= ROARING_WORDS {
          break
        }
        word = words[word_index]
      }
    }
    RunContainer(runs) => {
      let mut index = 0
      while index < runs.length() && out.length() < limit {
        let start = runs[index]
        let end = start + runs[index + 1]
        if end >= from_low {
          let mut value = if start > from_low { start } else { from_low }
          while value <= end && out.length() < limit {
            out.push(base | value)
            value += 1
          }
        }
        index += 2
      }
    }
  }
}

///|
/// Up to `limit` ids strictly greater than `after`, ascending. Start with
/// `after = -1L`, and continue from the last id a batch returned; a batch
/// shorter than `limit` (including an empty one) means the bitmap is exhausted.
/// `after` is 64-bit so that continuing from the largest supported id cannot
/// overflow. A `limit` of zero or less returns an empty array.
pub fn RoaringBitmap::ids_after(
  self : RoaringBitmap,
  after : Int64,
  limit : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = []
  if limit <= 0 || after >= ROARING_MAX_ID.to_int64() {
    return out
  }
  let start = if after < 0L { 0L } else { after + 1L }
  let start_key = (start >> 16).to_int()
  let start_low = (start & 0xFFFFL).to_int()
  let mut index = sorted_position(self.keys, start_key)
  while index < self.keys.length() && out.length() < limit {
    let key = self.keys[index]
    let from_low = if key == start_key { start_low } else { 0 }
    container_push_from(self.containers[index], key, from_low, limit, out)
    index += 1
  }
  out
}
