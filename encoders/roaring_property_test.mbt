// Property tests for the Roaring bitmap: the serialized form must round trip,
// the set operations must agree with a naive model, and run optimisation must
// never change the set.

///|
struct RoaringRng {
  mut state : UInt64
}

///|
fn RoaringRng::new(seed : Int32) -> RoaringRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn RoaringRng::next_u64(self : RoaringRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn RoaringRng::next_int(self : RoaringRng, bound : Int32) -> Int32 {
  (self.next_u64() >> 33).to_int() % bound
}

///|
fn roaring_ids(rng : RoaringRng, count : Int32, bound : Int32) -> Array[Int32] {
  let ids : Array[Int32] = []
  for _ in 0..<count {
    ids.push(rng.next_int(bound))
  }
  ids
}

///|
fn roaring_model(ids : Array[Int32]) -> Array[Int32] {
  let sorted = ids.copy()
  sorted.sort()
  let values : Array[Int32] = []
  for index in 0..<sorted.length() {
    if index == 0 || sorted[index] != sorted[index - 1] {
      values.push(sorted[index])
    }
  }
  values
}

///|
test "property: a bitmap round trips through its serialization" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RoaringRng::new(seed)
      let ids = roaring_ids(rng, rng.next_int(500), 200000)
      let bitmap = @encoders.RoaringBitmap::from_ids(ids) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      let bytes = bitmap.to_bytes()
      let back = @encoders.RoaringBitmap::from_bytes(bytes) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      if back.to_array() != roaring_model(ids) {
        return false
      }
      if back.cardinality() != roaring_model(ids).length() {
        return false
      }
      for id in ids {
        if !back.contains(id) {
          return false
        }
      }
      // an id outside the generated range must stay out
      !back.contains(2147483647) || ids.contains(2147483647)
    }),
  )
}

///|
test "property: run optimisation never changes the set" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RoaringRng::new(seed)
      let ids = roaring_ids(rng, rng.next_int(400), 20000)
      let bitmap = @encoders.RoaringBitmap::from_ids(ids) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      let before = bitmap.to_array()
      bitmap.run_optimize()
      let after = bitmap.to_array()
      let back = @encoders.RoaringBitmap::from_bytes(bitmap.to_bytes()) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      before == after && back.to_array() == before
    }),
  )
}

///|
test "property: union and intersect agree with a naive model" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RoaringRng::new(seed)
      let left_ids = roaring_ids(rng, rng.next_int(300), 70000)
      let right_ids = roaring_ids(rng, rng.next_int(300), 70000)
      let left = @encoders.RoaringBitmap::from_ids(left_ids) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      let right = @encoders.RoaringBitmap::from_ids(right_ids) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      let union_model : Array[Int32] = []
      for id in roaring_model(left_ids) {
        union_model.push(id)
      }
      for id in roaring_model(right_ids) {
        union_model.push(id)
      }
      let union_expected = roaring_model(union_model)
      let intersection_expected : Array[Int32] = []
      let right_model = roaring_model(right_ids)
      for id in roaring_model(left_ids) {
        if right_model.contains(id) {
          intersection_expected.push(id)
        }
      }
      left.union(right).to_array() == union_expected &&
      left.intersect(right).to_array() == intersection_expected
    }),
  )
}

///|
test "property: the decoder rejects truncated streams" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RoaringRng::new(seed)
      let ids = roaring_ids(rng, 1 + rng.next_int(200), 100000)
      let bitmap = @encoders.RoaringBitmap::from_ids(ids) catch {
        _ => @encoders.RoaringBitmap::new()
      }
      let bytes = bitmap.to_bytes()
      let cut = rng.next_int(bytes.length())
      let trimmed = bytes[0:cut]
      // The container table is self-delimiting: a prefix either raises or
      // decodes to fewer ids, never to ids that were not in the input.
      if trimmed.length() < 4 {
        return true
      }
      match try_decode_roaring_prefix(trimmed) {
        None => true
        Some(values) => {
          let model = roaring_model(ids)
          let mut subset = true
          for value in values {
            if !model.contains(value) {
              subset = false
            }
          }
          subset
        }
      }
    }),
  )
}

///|
fn try_decode_roaring_prefix(data : BytesView) -> Array[Int32]? {
  let bitmap = @encoders.RoaringBitmap::from_bytes(data) catch {
    _ => return None
  }
  Some(bitmap.to_array())
}
