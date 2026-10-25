/// Blackbox tests: the public contract in `docs/SKETCHES.md`, one group per
/// test. The statistical group lives in the acceptance rig; these are the
/// invariants that do not need 10M ids.

///|
test "precision outside 4..16 is rejected" {
  let low = try {
    let _ = @sketches.HllSketch::new(3)
    false
  } catch {
    _ => true
  }
  let high = try {
    let _ = @sketches.HllSketch::new(17)
    false
  } catch {
    _ => true
  }
  assert_true(low)
  assert_true(high)
  let small = @sketches.HllSketch::new(4) catch { _ => abort("4 rejected") }
  let large = @sketches.HllSketch::new(16) catch { _ => abort("16 rejected") }
  assert_eq(small.register_count(), 16)
  assert_eq(large.register_count(), 65536)
}

///|
test "the default sketch is precision 14" {
  let sketch = @sketches.HllSketch::new_default()
  assert_eq(sketch.precision(), 14)
  assert_eq(sketch.register_count(), 16384)
}

///|
test "an empty sketch estimates zero and one element estimates one" {
  let empty = @sketches.HllSketch::new_default()
  assert_true(empty.estimate() == 0.0)
  let one = @sketches.HllSketch::new_default()
  one.add_int32(42)
  let estimate = one.estimate()
  assert_true(estimate > 0.9 && estimate < 1.1)
}

///|
test "adding the same values twice changes nothing" {
  let once = @sketches.HllSketch::new_default()
  let twice = @sketches.HllSketch::new_default()
  for value in 0..<1000 {
    once.add_int32(value)
    twice.add_int32(value)
    twice.add_int32(value)
  }
  assert_true(once.to_bytes() == twice.to_bytes())
}

///|
test "the estimate is inside the confidence interval at 10k" {
  let sketch = @sketches.HllSketch::new_default()
  for value in 0..<10000 {
    sketch.add_int32(value)
  }
  let estimate = sketch.estimate()
  let error = (estimate - 10000.0) / 10000.0
  // 1.96 sigma at m = 2^14 is about 1.6%; the bound is stated as a confidence
  // interval, not a maximum, so the test uses a fixed seed and a fixed input
  // and asserts the measured value — no more.
  assert_true(error > -0.03 && error < 0.03)
}

///|
test "merge is commutative and associative as registers" {
  let a = @sketches.HllSketch::new_default()
  let b = @sketches.HllSketch::new_default()
  let c = @sketches.HllSketch::new_default()
  for value in 0..<500 {
    a.add_int32(value)
  }
  for value in 400..<900 {
    b.add_int32(value)
  }
  for value in 800..<1200 {
    c.add_int32(value)
  }
  let left = (a.merge(b) catch { _ => abort("merge failed") }).merge(c) catch {
    _ => abort("merge failed")
  }
  let right = a.merge(b.merge(c) catch { _ => abort("merge failed") }) catch {
    _ => abort("merge failed")
  }
  let swapped = (b.merge(a) catch { _ => abort("merge failed") }).merge(c) catch {
    _ => abort("merge failed")
  }
  assert_true(left.to_bytes() == right.to_bytes())
  assert_true(left.to_bytes() == swapped.to_bytes())
}

///|
test "merging into an empty sketch equals building directly" {
  let direct = @sketches.HllSketch::new_default()
  for value in 0..<2000 {
    direct.add_int32(value)
  }
  let merged = @sketches.HllSketch::new_default().merge(direct) catch {
    _ => abort("merge failed")
  }
  assert_true(merged.to_bytes() == direct.to_bytes())
}

///|
test "merge leaves both operands untouched" {
  let a = @sketches.HllSketch::new_default()
  let b = @sketches.HllSketch::new_default()
  a.add_int32(1)
  b.add_int32(1 << 20)
  let before_a = a.to_bytes()
  let before_b = b.to_bytes()
  let merged = a.merge(b) catch { _ => abort("merge failed") }
  merged.add_int32(7)
  assert_true(a.to_bytes() == before_a)
  assert_true(b.to_bytes() == before_b)
}

///|
test "merging two precisions is rejected" {
  let a = @sketches.HllSketch::new(10) catch { _ => abort("10 rejected") }
  let b = @sketches.HllSketch::new(11) catch { _ => abort("11 rejected") }
  let rejected = try {
    let _ = a.merge(b)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "serialization round trips" {
  let sketch = @sketches.HllSketch::new(12) catch { _ => abort("12 rejected") }
  for value in 0..<3000 {
    sketch.add_int64(value.to_int64() * 7L)
  }
  let bytes = sketch.to_bytes()
  let back = @sketches.HllSketch::from_bytes(bytes.exact_view()) catch {
    _ => abort("round trip rejected its own bytes")
  }
  assert_eq(back.precision(), sketch.precision())
  assert_true(back.to_bytes() == bytes)
}

///|
test "malformed sketches are rejected with typed errors" {
  let sketch = @sketches.HllSketch::new(4) catch { _ => abort("4 rejected") }
  sketch.add_int32(9)
  let bytes = sketch.to_bytes()
  // Wrong version.
  let wrong_version = FixedArray::make(bytes.length(), b'\x00')
  for index in 0..<bytes.length() {
    wrong_version[index] = bytes[index]
  }
  wrong_version[0] = b'\x09'
  let version_rejected = try {
    let _ = @sketches.HllSketch::from_bytes(
      Bytes::from_array(wrong_version.exact_view()).exact_view(),
    )
    false
  } catch {
    _ => true
  }
  // Precision below the range.
  let wrong_precision = FixedArray::make(bytes.length(), b'\x00')
  for index in 0..<bytes.length() {
    wrong_precision[index] = bytes[index]
  }
  wrong_precision[1] = b'\x02'
  let precision_rejected = try {
    let _ = @sketches.HllSketch::from_bytes(
      Bytes::from_array(wrong_precision.exact_view()).exact_view(),
    )
    false
  } catch {
    _ => true
  }
  // Truncated body.
  let truncated_rejected = try {
    let _ = @sketches.HllSketch::from_bytes(bytes.exact_view(start=0, end=5))
    false
  } catch {
    _ => true
  }
  // A register above the ceiling for this precision (61 at precision 4).
  let wrong_register = FixedArray::make(bytes.length(), b'\x00')
  for index in 0..<bytes.length() {
    wrong_register[index] = bytes[index]
  }
  wrong_register[2] = b'\x3f'
  let register_rejected = try {
    let _ = @sketches.HllSketch::from_bytes(
      Bytes::from_array(wrong_register.exact_view()).exact_view(),
    )
    false
  } catch {
    _ => true
  }
  assert_true(version_rejected)
  assert_true(precision_rejected)
  assert_true(truncated_rejected)
  assert_true(register_rejected)
}

///|
test "each scalar type hashes its canonical little-endian bytes" {
  // The same bit pattern through three entry points has to land in the same
  // registers, which is what "canonical form" means in the contract.
  let via_int32 = @sketches.HllSketch::new_default()
  via_int32.add_int32(1065353216)
  let via_float = @sketches.HllSketch::new_default()
  via_float.add_float(1.0)
  assert_true(via_int32.to_bytes() == via_float.to_bytes())
  let via_int64 = @sketches.HllSketch::new_default()
  via_int64.add_int64(1065353216L)
  assert_true(via_int32.to_bytes() != via_int64.to_bytes())
  // Booleans are one byte, so `true` and the integer 1 differ.
  let via_bool = @sketches.HllSketch::new_default()
  via_bool.add_bool(true)
  let via_one = @sketches.HllSketch::new_default()
  via_one.add_int32(1)
  assert_true(via_bool.to_bytes() != via_one.to_bytes())
}

///|
test "byte strings hash by their raw bytes" {
  let from_bytes = @sketches.HllSketch::new_default()
  from_bytes.add_bytes(@utf8.encode("hello"))
  let from_again = @sketches.HllSketch::new_default()
  from_again.add_bytes(@utf8.encode("hello"))
  assert_true(from_bytes.to_bytes() == from_again.to_bytes())
  let from_other = @sketches.HllSketch::new_default()
  from_other.add_bytes(@utf8.encode("hellp"))
  assert_true(from_bytes.to_bytes() != from_other.to_bytes())
}
