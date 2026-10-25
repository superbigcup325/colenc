/// Whitebox tests for the Roaring bitmap: the portable layout byte for byte
/// against the reference's own output, the container choice bits, the set
/// operations and the malformed inputs.

///|
test "roaring: empty bitmap is the bare no-run header" {
  let bitmap = RoaringBitmap::new()
  // cookie 12346 (u32) then size 0
  assert_eq(bitmap.to_bytes(), b"\x3a\x30\x00\x00\x00\x00\x00\x00")
}

///|
test "roaring: one id serializes as an array container with an offset" {
  let bitmap = RoaringBitmap::from_ids([0]) catch { _ => RoaringBitmap::new() }
  // cookie, size 1, key 0, card-1 0, offset 16, value 0
  assert_eq(
    bitmap.to_bytes(),
    b"\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00",
  )
}

///|
test "roaring: three consecutive ids keep the array form" {
  let bitmap = RoaringBitmap::from_ids([1, 2, 3]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(
    bitmap.to_bytes(),
    b"\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x02\x00\x10\x00\x00\x00\x01\x00\x02\x00\x03\x00",
  )
}

///|
test "roaring: the top of a container stays in the same key" {
  let bitmap = RoaringBitmap::from_ids([65535]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(
    bitmap.to_bytes(),
    b"\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\xff\xff",
  )
}

///|
test "roaring: two containers get one offset each" {
  let bitmap = RoaringBitmap::from_ids([0, 65536]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(
    bitmap.to_bytes(),
    b"\x3a\x30\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x18\x00\x00\x00\x1a\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
test "roaring: four containers still carry the offset table" {
  let bitmap = RoaringBitmap::from_ids([0, 65536, 131072, 196608]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(
    bitmap.to_bytes(),
    b"\x3a\x30\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x28\x00\x00\x00\x2a\x00\x00\x00\x2c\x00\x00\x00\x2e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
test "roaring: run optimisation switches the cookie and drops the offsets" {
  let values : Array[Int32] = []
  for value in 0..<100 {
    values.push(value)
  }
  for value in 200..<300 {
    values.push(value)
  }
  let bitmap = RoaringBitmap::from_ids(values) catch {
    _ => RoaringBitmap::new()
  }
  bitmap.run_optimize()
  // run cookie | (size-1) << 16, run bitmap 0x01, key 0, card-1 199, two runs
  assert_eq(
    bitmap.to_bytes(),
    b"\x3b\x30\x00\x00\x01\x00\x00\xc7\x00\x02\x00\x00\x00\x63\x00\xc8\x00\x63\x00",
  )
}

///|
test "roaring: a tie in run size keeps the array form" {
  // card 5, two runs: array is 10 bytes, run form is 10 bytes, so no switch
  let bitmap = RoaringBitmap::from_ids([0, 1, 2, 100, 101]) catch {
    _ => RoaringBitmap::new()
  }
  bitmap.run_optimize()
  let cookie = bitmap.to_bytes()[0].to_int() |
    (bitmap.to_bytes()[1].to_int() << 8)
  assert_eq(cookie, 12346)
}

///|
test "roaring: array containers hold 4096 ids and bitmaps take the 4097th" {
  let boundary : Array[Int32] = []
  for value in 0..<4096 {
    boundary.push(value)
  }
  let exact = RoaringBitmap::from_ids(boundary) catch {
    _ => RoaringBitmap::new()
  }
  let beyond : Array[Int32] = boundary.copy()
  beyond.push(4096)
  let overflow = RoaringBitmap::from_ids(beyond) catch {
    _ => RoaringBitmap::new()
  }
  // both payloads are 8192 bytes, so the container shape is what differs
  assert_eq(exact.cardinality(), 4096)
  assert_eq(overflow.cardinality(), 4097)
  assert_eq(exact.to_bytes().length(), 8208)
  assert_eq(overflow.to_bytes().length(), 8208)
  match exact.containers[0] {
    ArrayContainer(values) => assert_eq(values.length(), 4096)
    _ => fail("4096 ids must stay an array container")
  }
  match overflow.containers[0] {
    BitmapContainer(words) => assert_eq(words.length(), 1024)
    _ => fail("4097 ids must become a bitmap container")
  }
}

///|
test "roaring: round trip keeps the ids and their order" {
  let ids : Array[Int32] = [5, 0, 70000, 65535, 65536, 2147483647]
  let bitmap = RoaringBitmap::from_ids(ids) catch { _ => RoaringBitmap::new() }
  let bytes = bitmap.to_bytes()
  let back = RoaringBitmap::from_bytes(bytes) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(back.to_array(), [0, 5, 65535, 65536, 70000, 2147483647])
  assert_eq(back.cardinality(), 6)
  assert_true(back.contains(70000))
  assert_false(back.contains(70001))
}

///|
test "roaring: union and intersect agree with set arithmetic" {
  let left = RoaringBitmap::from_ids([1, 2, 3, 100000]) catch {
    _ => RoaringBitmap::new()
  }
  let right = RoaringBitmap::from_ids([3, 4, 100000, 200000]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(left.union(right).to_array(), [1, 2, 3, 4, 100000, 200000])
  assert_eq(left.intersect(right).to_array(), [3, 100000])
  assert_eq(left.intersect(right).cardinality(), 2)
  let disjoint = RoaringBitmap::from_ids([9]) catch {
    _ => RoaringBitmap::new()
  }
  assert_eq(left.intersect(disjoint).cardinality(), 0)
}

///|
test "roaring: negative ids and the u32 half are refused" {
  let negative : Array[Int32] = [-1]
  try RoaringBitmap::from_ids(negative) catch {
    @types.EncodingError::OutOfRange(value, offset) => {
      assert_eq(value, -1L)
      assert_eq(offset, 0)
    }
    other => fail("unexpected error \{@types.EncodingError::message(other)}")
  } noraise {
    _ => fail("a negative id must be refused")
  }
}

///|
test "roaring: truncated and malformed inputs raise with an offset" {
  try RoaringBitmap::from_bytes(b"\x3a\x30\x00\x00") catch {
    @types.EncodingError::Truncated(offset, need, available) => {
      assert_eq(offset, 4)
      assert_eq(need, 4)
      assert_eq(available, 0)
    }
    other => fail("unexpected error \{@types.EncodingError::message(other)}")
  } noraise {
    _ => fail("a four-byte stream must be refused")
  }
  try RoaringBitmap::from_bytes(b"\xff\x00\x00\x00\x00\x00\x00\x00") catch {
    @types.EncodingError::InvalidTag(tag) => assert_eq(tag, 255)
    other => fail("unexpected error \{@types.EncodingError::message(other)}")
  } noraise {
    _ => fail("an unknown cookie must be refused")
  }
}

///|
test "roaring: a wrong offset in the table is detected" {
  // a valid two-container bitmap with the second offset moved by one
  let bytes = b"\x3a\x30\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x18\x00\x00\x00\x1b\x00\x00\x00\x00\x00\x00\x00"
  try RoaringBitmap::from_bytes(bytes) catch {
    @types.EncodingError::Corrupt(offset) => assert_eq(offset, 26)
    other => fail("unexpected error \{@types.EncodingError::message(other)}")
  } noraise {
    _ => fail("a wrong offset must be refused")
  }
}

// --- Regressions for operand aliasing and container-shape legality -------------
//
// The byte layout is a function of the container's shape: the writer emits an
// array body or a bitmap body from the container it holds, while the reader
// picks the shape from the cardinality. Two defects hid behind that coupling —
// a set operation that reused an operand's container by reference (so a later
// `add` rewrote the operand), and a run container that was de-optimised into an
// array above the 4096-value range (so the writer and reader disagreed about
// the body). Both are shape-invariant violations, which is why the cases below
// assert the invariants after every operation rather than the symptom alone.

///|
/// Build a bitmap or fail where the raise happened. The older cases in this file
/// turn a raise into an empty bitmap, which would hide a regression behind a
/// confusing assertion.
fn wb_bitmap(ids : Array[Int32]) -> RoaringBitmap raise {
  RoaringBitmap::from_ids(ids) catch {
    error => fail("from_ids raised: \{@types.EncodingError::message(error)}")
  }
}

///|
fn wb_parse(bytes : Bytes) -> RoaringBitmap raise {
  RoaringBitmap::from_bytes(bytes) catch {
    error => fail("from_bytes raised: \{@types.EncodingError::message(error)}")
  }
}

///|
fn consecutive_ids(start : Int32, count : Int32) -> Array[Int32] {
  Array::makei(count, fn(index) { start + index })
}

///|
/// Assert the container invariants the serialization depends on.
fn check_container_invariants(bitmap : RoaringBitmap) -> Unit raise {
  assert_eq(bitmap.keys.length(), bitmap.containers.length())
  for index in 0..<bitmap.keys.length() {
    if index > 0 {
      assert_true(
        bitmap.keys[index - 1] < bitmap.keys[index],
        msg="keys are strictly ascending",
      )
    }
    let container = bitmap.containers[index]
    let cardinality = container_cardinality(container)
    assert_true(cardinality > 0, msg="containers are never empty")
    match container {
      ArrayContainer(values) => {
        assert_true(
          cardinality <= ROARING_ARRAY_MAX,
          msg="an array container holds at most 4096 values",
        )
        assert_eq(values.length(), cardinality)
        for position in 0..<values.length() {
          assert_true(
            values[position] >= 0 && values[position] < ROARING_CONTAINER_VALUES,
            msg="an array value stays in the low half",
          )
          if position > 0 {
            assert_true(
              values[position - 1] < values[position],
              msg="array values are strictly ascending",
            )
          }
        }
      }
      BitmapContainer(words) => {
        assert_true(
          cardinality > ROARING_ARRAY_MAX,
          msg="a bitmap container holds more than 4096 values",
        )
        assert_eq(words.length(), ROARING_WORDS)
      }
      RunContainer(runs) => {
        assert_true(
          runs.length() % 2 == 0,
          msg="runs come as (start, length) pairs",
        )
        let mut covered = 0
        let mut position = 0
        while position < runs.length() {
          let start = runs[position]
          let length = runs[position + 1]
          assert_true(length >= 0, msg="a run length is non-negative")
          assert_true(
            start >= 0 && start + length < ROARING_CONTAINER_VALUES,
            msg="a run stays in the low half",
          )
          if position > 0 {
            let previous_end = runs[position - 2] + runs[position - 1]
            assert_true(
              start > previous_end + 1,
              msg="runs are disjoint and not adjacent",
            )
          }
          covered += length + 1
          position += 2
        }
        assert_eq(covered, cardinality)
        // `run_optimize` only adopts the run form when it is strictly smaller.
        let alternative = if cardinality <= ROARING_ARRAY_MAX {
          2 * cardinality
        } else {
          8 * ROARING_WORDS
        }
        assert_true(
          2 + 2 * runs.length() < alternative,
          msg="the run form is strictly smaller than the form it replaced",
        )
      }
    }
  }
}

///|
test "roaring: a union result is independent of its operands" {
  // Disjoint keys, one container per side: the result reuses a side as-is.
  let left = wb_bitmap([1, 2])
  let right = wb_bitmap([65536])
  let merged = left.union(right)
  merged.add(3)
  assert_eq(left.to_array(), [1, 2])
  assert_eq(right.to_array(), [65536])
  assert_eq(merged.to_array(), [1, 2, 3, 65536])
  // The same with bitmap containers.
  let dense_left = wb_bitmap(consecutive_ids(0, 5000))
  let dense_right = wb_bitmap(consecutive_ids(65536, 5000))
  let dense_merged = dense_left.union(dense_right)
  dense_merged.add(6000)
  assert_eq(dense_left.cardinality(), 5000)
  assert_eq(dense_left.contains(6000), false)
  assert_eq(dense_merged.cardinality(), 10001)
  // And with a run container on one side.
  let run_left = wb_bitmap(consecutive_ids(0, 5000))
  run_left.run_optimize()
  let run_merged = run_left.union(wb_bitmap([65536]))
  run_merged.add(6000)
  assert_eq(run_left.cardinality(), 5000)
  assert_eq(run_left.contains(6000), false)
  // Mutating an operand after the union leaves the result alone.
  let first = wb_bitmap([10, 20])
  let second = wb_bitmap([65536, 131072])
  let both = first.union(second)
  first.add(30)
  second.add(65537)
  assert_eq(both.to_array(), [10, 20, 65536, 131072])
  check_container_invariants(both)
  // Intersect keeps its operands too.
  let base = wb_bitmap(consecutive_ids(0, 100))
  let overlap = wb_bitmap(consecutive_ids(50, 100))
  let shared = base.intersect(overlap)
  shared.add(200)
  assert_eq(base.cardinality(), 100)
  assert_eq(base.contains(200), false)
  check_container_invariants(shared)
}

///|
test "roaring: adding after run_optimize keeps a legal container at every size" {
  for size in [4095, 4096, 4097, 5000, 65535] {
    let bitmap = wb_bitmap(consecutive_ids(0, size))
    bitmap.run_optimize()
    check_container_invariants(bitmap)
    bitmap.add(size)
    check_container_invariants(bitmap)
    assert_eq(bitmap.cardinality(), size + 1)
    assert_eq(bitmap.contains(size), true)
    let back = wb_parse(bitmap.to_bytes())
    check_container_invariants(back)
    assert_eq(back.to_array(), bitmap.to_array())
  }
}

///|
test "roaring: a run container that outgrows the array range becomes a bitmap" {
  let bitmap = wb_bitmap(consecutive_ids(0, 5000))
  bitmap.run_optimize()
  bitmap.add(6000)
  // Header of 16 bytes (cookie, container count, key/cardinality, offset) plus
  // one bitmap body; the array body of 5001 values would be 10002 bytes.
  assert_eq(bitmap.to_bytes().length(), 16 + 8 * ROARING_WORDS)
  let back = wb_parse(bitmap.to_bytes())
  assert_eq(back.cardinality(), 5001)
  assert_eq(back.contains(6000), true)
  assert_eq(back.to_array(), bitmap.to_array())
  check_container_invariants(back)
  // A value in a later key must not disturb the de-optimised container.
  let crossing = wb_bitmap(consecutive_ids(0, 5000))
  crossing.run_optimize()
  crossing.add(131072)
  check_container_invariants(crossing)
  assert_eq(crossing.cardinality(), 5001)
  assert_eq(wb_parse(crossing.to_bytes()).to_array(), crossing.to_array())
}

///|
test "roaring: adding a duplicate after run_optimize changes nothing" {
  let bitmap = wb_bitmap(consecutive_ids(0, 5000))
  bitmap.run_optimize()
  let before = bitmap.to_bytes()
  bitmap.add(4999)
  assert_eq(bitmap.to_bytes(), before)
  check_container_invariants(bitmap)
}

///|
test "roaring: mixed operation sequences keep the container invariants" {
  let mut bitmap = wb_bitmap([1, 2, 3, 65535, 65536])
  let mut state = 12345
  for step in 0..<48 {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF
    let id = (state >> 9) & 0x1FFFF
    match step % 4 {
      0 => bitmap.add(id)
      1 => bitmap = bitmap.union(wb_bitmap(consecutive_ids(id, 40)))
      2 => bitmap = bitmap.intersect(wb_bitmap(consecutive_ids(id, 40)))
      _ => bitmap.run_optimize()
    }
    check_container_invariants(bitmap)
    let back = wb_parse(bitmap.to_bytes())
    assert_eq(back.to_array(), bitmap.to_array())
  }
}

///|
test "roaring: a sorted input builds the same containers as repeated adds" {
  // The bulk path is an optimisation, not a second definition: whatever the
  // shape rule settles on for repeated adds, the one-walk build must produce.
  let cases : Array[Array[Int32]] = [
    [],
    [0],
    [2147483647],
    [1, 1, 2, 2, 2, 3],
    consecutive_ids(0, 4096),
    consecutive_ids(0, 4097),
    consecutive_ids(0, 65536),
    consecutive_ids(65530, 20),
    [0, 65535, 65536, 131072, 2147483647],
    Array::makei(5000, fn(i) { i * 13 }),
    Array::makei(4096, fn(i) { 70000 + i * 2 }),
  ]
  for ids in cases {
    let bulk = RoaringBitmap::from_ids(ids)
    let incremental = RoaringBitmap::new()
    for id in ids {
      incremental.add(id)
    }
    assert_eq(bulk.to_array(), incremental.to_array())
    assert_eq(bulk.to_bytes(), incremental.to_bytes())
    check_container_invariants(bulk)
    // Duplicates must not change anything, and the run form must agree too.
    let doubled : Array[Int32] = []
    for id in ids {
      doubled.push(id)
      doubled.push(id)
    }
    assert_eq(RoaringBitmap::from_ids(doubled).to_bytes(), bulk.to_bytes())
    bulk.run_optimize()
    incremental.run_optimize()
    assert_eq(bulk.to_bytes(), incremental.to_bytes())
  }
}

///|
test "roaring: an unsorted input still inserts one id at a time" {
  let ids : Array[Int32] = [9, 1, 7, 3, 3, 1, 65540, 65536, 0]
  let bitmap = RoaringBitmap::from_ids(ids)
  let incremental = RoaringBitmap::new()
  for id in ids {
    incremental.add(id)
  }
  assert_eq(bitmap.to_bytes(), incremental.to_bytes())
  check_container_invariants(bitmap)
}
