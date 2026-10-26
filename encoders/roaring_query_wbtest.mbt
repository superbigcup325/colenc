/// Whitebox tests for the read-side bitmap queries: counts and overlap against
/// an independent set oracle, and batches against `to_array`, across every
/// container shape pairing.

///|
fn rq_range(start : Int32, end : Int32) -> Array[Int32] {
  Array::makei(end - start, fn(i) { start + i })
}

///|
fn rq_bitmap(ids : Array[Int32], optimize : Bool) -> RoaringBitmap {
  let bitmap = RoaringBitmap::from_ids(ids) catch {
    _ => abort("from_ids rejected a test id")
  }
  if optimize {
    bitmap.run_optimize()
  }
  bitmap
}

///|
fn rq_shape(bitmap : RoaringBitmap, key_index : Int32) -> String {
  match bitmap.containers[key_index] {
    ArrayContainer(_) => "array"
    BitmapContainer(_) => "bitmap"
    RunContainer(_) => "run"
  }
}

///|
fn rq_cases() -> Array[(String, Array[Int32])] {
  let mixed = rq_range(0, 5000)
  mixed.append([65539, 65545])
  mixed.append(Array::makei(5000, fn(i) { 131072 + i * 2 }))
  [
    ("empty", []),
    ("small-array", [1, 5, 70000]),
    ("array-4096", rq_range(0, 4096)),
    ("bitmap-4097", rq_range(0, 4097)),
    ("bitmap-even", Array::makei(5000, fn(i) { i * 2 })),
    ("full-key", rq_range(0, 65536)),
    ("run-mid", rq_range(100, 5000)),
    ("run-small", rq_range(10, 21)),
    ("multi-key", Array::makei(200, fn(i) { i / 50 * 65536 + i % 50 * 7 })),
    ("mixed", mixed),
    ("max-id", [0, 2147483646, 2147483647]),
    ("sparse-keys", Array::makei(40, fn(i) { i * 196608 + 7 })),
  ]
}

///|
fn rq_oracle(left : Array[Int32], right : Array[Int32]) -> Int32 {
  let small = if left.length() <= right.length() { left } else { right }
  let large = if left.length() <= right.length() { right } else { left }
  let set : Map[Int32, Bool] = Map([])
  for value in small {
    set.set(value, true)
  }
  let mut count = 0
  for value in large {
    if set.get(value) is Some(_) {
      count += 1
    }
  }
  count
}

///|
test "query fixtures cover every container shape and their mixtures" {
  assert_eq(rq_shape(rq_bitmap(rq_range(0, 4096), false), 0), "array")
  assert_eq(rq_shape(rq_bitmap(rq_range(0, 4097), false), 0), "bitmap")
  assert_eq(rq_shape(rq_bitmap(rq_range(100, 5000), false), 0), "bitmap")
  assert_eq(rq_shape(rq_bitmap(rq_range(100, 5000), true), 0), "run")
  assert_eq(rq_shape(rq_bitmap(rq_range(10, 21), true), 0), "run")
  assert_eq(rq_shape(rq_bitmap(rq_range(0, 4096), true), 0), "run")
  let mixed = rq_cases()[9].1
  let optimized = rq_bitmap(mixed, true)
  assert_eq(rq_shape(optimized, 0), "run")
  assert_eq(rq_shape(optimized, 1), "array")
  assert_eq(rq_shape(optimized, 2), "bitmap")
}

///|
test "intersection count and overlap match an independent oracle" {
  let cases = rq_cases()
  let plain = cases.map(fn(entry) { rq_bitmap(entry.1, false) })
  let optimized = cases.map(fn(entry) { rq_bitmap(entry.1, true) })
  for i in 0..<cases.length() {
    for j in 0..<cases.length() {
      let expected = rq_oracle(cases[i].1, cases[j].1)
      for left in [plain[i], optimized[i]] {
        for right in [plain[j], optimized[j]] {
          assert_eq(left.intersection_cardinality(right), expected)
          assert_eq(left.intersects(right), expected > 0)
          assert_eq(left.intersect(right).cardinality(), expected)
        }
      }
    }
  }
}

///|
test "queries leave both operands untouched" {
  let cases = rq_cases()
  for entry in cases {
    let left = rq_bitmap(entry.1, true)
    let right = rq_bitmap(rq_range(0, 7000), false)
    let left_before = left.to_bytes()
    let right_before = right.to_bytes()
    ignore(left.intersection_cardinality(right))
    ignore(left.intersects(right))
    ignore(left.ids_after(-1L, 100))
    assert_eq(left.to_bytes(), left_before)
    assert_eq(right.to_bytes(), right_before)
  }
}

///|
test "batches concatenate to the full id array" {
  for entry in rq_cases() {
    for optimize in [false, true] {
      let bitmap = rq_bitmap(entry.1, optimize)
      let expected = bitmap.to_array()
      for limit in [1, 7, 4096, 100000] {
        let got : Array[Int32] = []
        let mut after = -1L
        while true {
          let batch = bitmap.ids_after(after, limit)
          for id in batch {
            got.push(id)
          }
          if batch.length() < limit {
            break
          }
          after = batch[batch.length() - 1].to_int64()
        }
        assert_eq(got, expected)
      }
    }
  }
}

///|
test "a cursor in the middle of a container, a gap or past the end" {
  let cursors : Array[Int64] = [
    -5L, -1L, 0L, 1L, 99L, 100L, 4095L, 4096L, 65535L, 65536L, 70000L, 196614L, 2147483645L,
    2147483646L, 2147483647L, 2147483648L, 9999999999L,
  ]
  for entry in rq_cases() {
    for optimize in [false, true] {
      let bitmap = rq_bitmap(entry.1, optimize)
      let all = bitmap.to_array()
      for after in cursors {
        let tail = all.filter(fn(id) { id.to_int64() > after })
        assert_eq(bitmap.ids_after(after, 10000000), tail)
      }
      // cursors taken from the ids themselves, before and at each
      if all.length() > 0 {
        for position in [0, all.length() / 2, all.length() - 1] {
          let id = all[position].to_int64()
          for after in [id - 1L, id] {
            let tail = all.filter(fn(value) { value.to_int64() > after })
            assert_eq(bitmap.ids_after(after, 10000000), tail)
          }
        }
      }
    }
  }
}

///|
test "a batch stops at its limit and zero or negative limits are empty" {
  let bitmap = rq_bitmap(rq_range(0, 10000), false)
  assert_eq(bitmap.ids_after(-1L, 3), [0, 1, 2])
  assert_eq(bitmap.ids_after(2L, 3), [3, 4, 5])
  assert_eq(bitmap.ids_after(-1L, 0), [])
  assert_eq(bitmap.ids_after(-1L, -4), [])
  assert_eq(RoaringBitmap::new().ids_after(-1L, 5), [])
  // a run container resumes inside a run, at the boundary of two keys
  let run = rq_bitmap(rq_range(65530, 65545), true)
  assert_eq(run.ids_after(65533L, 4), [65534, 65535, 65536, 65537])
}
