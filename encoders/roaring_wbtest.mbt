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
