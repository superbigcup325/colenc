/// Blackbox tests for the quantile summary: the structural half of the contract
/// in `docs/SKETCHES.md`. The accuracy half needs the matrix and lives in the
/// acceptance rig.

///|
fn tdigest_of(values : Array[Double]) -> @sketches.TDigest {
  let digest = @sketches.TDigest::new_default()
  for value in values {
    digest.update(value) catch {
      error => abort(@types.EncodingError::message(error))
    }
  }
  digest
}

///|
test "compression outside 10..1000 is rejected" {
  let low = try {
    let _ = @sketches.TDigest::new(9)
    false
  } catch {
    _ => true
  }
  let high = try {
    let _ = @sketches.TDigest::new(1001)
    false
  } catch {
    _ => true
  }
  assert_true(low)
  assert_true(high)
  let small = @sketches.TDigest::new(10) catch { _ => abort("10 rejected") }
  let large = @sketches.TDigest::new(1000) catch { _ => abort("1000 rejected") }
  assert_eq(small.compression(), 10)
  assert_eq(large.compression(), 1000)
}

///|
test "an empty digest has no quantile and no extremes" {
  let digest = @sketches.TDigest::new_default()
  let quantile = try {
    let _ = digest.quantile(0.5)
    false
  } catch {
    _ => true
  }
  let extreme = try {
    let _ = digest.minimum()
    false
  } catch {
    _ => true
  }
  assert_true(quantile)
  assert_true(extreme)
  assert_true(digest.to_bytes() != Bytes::from_array([]))
}

///|
test "a single value answers every quantile" {
  let digest = tdigest_of([42.0])
  for q in [0.0, 0.25, 0.5, 0.75, 1.0] {
    let answer = digest.quantile(q) catch { _ => abort("quantile raised") }
    assert_true(answer == 42.0)
  }
  assert_true((digest.minimum() catch { _ => abort("x") }) == 42.0)
  assert_true((digest.maximum() catch { _ => abort("x") }) == 42.0)
}

///|
test "a NaN or an infinite value is rejected" {
  let digest = @sketches.TDigest::new_default()
  let nan = 0.0 / 0.0
  let infinite = 1.0 / 0.0
  let rejected_nan = try {
    digest.update(nan)
    false
  } catch {
    _ => true
  }
  let rejected_inf = try {
    digest.update(infinite)
    false
  } catch {
    _ => true
  }
  assert_true(rejected_nan)
  assert_true(rejected_inf)
  assert_true(digest.count() == 0.0)
}

///|
test "a quantile outside 0..1 is rejected" {
  let digest = tdigest_of([1.0, 2.0, 3.0])
  for q in [-0.1, 1.1, 0.0 / 0.0] {
    let rejected = try {
      let _ = digest.quantile(q)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "the weight sum is the value count and the centroid count stays bounded" {
  let digest = @sketches.TDigest::new(100) catch { _ => abort("x") }
  for index in 0..<50_000 {
    digest.update(index.to_double() / 7.0) catch {
      _ => abort("update")
    }
  }
  assert_true(digest.count() == 50_000.0)
  let bytes = digest.to_bytes()
  assert_true(digest.centroid_count() <= 201)
  let back = @sketches.TDigest::from_bytes(bytes.exact_view()) catch {
    _ => abort("round trip rejected its own bytes")
  }
  assert_true(back.count() == 50_000.0)
  assert_true(back.centroid_count() <= 201)
}

///|
test "quantiles are monotone and the extremes are exact" {
  let digest = @sketches.TDigest::new(100) catch { _ => abort("x") }
  for index in 0..<20_000 {
    let value = (index * 37 % 1000).to_double()
    digest.update(value) catch {
      _ => abort("update")
    }
  }
  let mut previous = -1.0
  for step in 0..<=20 {
    let q = step.to_double() / 20.0
    let answer = digest.quantile(q) catch { _ => abort("quantile") }
    assert_true(answer >= previous)
    previous = answer
  }
  assert_true((digest.minimum() catch { _ => abort("x") }) == 0.0)
  assert_true((digest.maximum() catch { _ => abort("x") }) == 999.0)
}

///|
test "serialization round trips and keeps the extremes" {
  let digest = @sketches.TDigest::new(50) catch { _ => abort("x") }
  for index in 0..<5_000 {
    digest.update((index % 400).to_double() - 100.0) catch {
      _ => abort("u")
    }
  }
  let bytes = digest.to_bytes()
  let back = @sketches.TDigest::from_bytes(bytes.exact_view()) catch {
    _ => abort("round trip")
  }
  assert_true(back.to_bytes() == bytes)
  assert_true((back.minimum() catch { _ => abort("x") }) == -100.0)
  assert_true((back.maximum() catch { _ => abort("x") }) == 299.0)
}

///|
test "merge preserves the count, the extremes and leaves both operands alone" {
  let left = tdigest_of([1.0, 2.0, 3.0, 4.0])
  let right = tdigest_of([-5.0, 100.0])
  let left_before = left.to_bytes()
  let right_before = right.to_bytes()
  let merged = left.merge(right) catch { _ => abort("merge") }
  assert_true(merged.count() == 6.0)
  assert_true((merged.minimum() catch { _ => abort("x") }) == -5.0)
  assert_true((merged.maximum() catch { _ => abort("x") }) == 100.0)
  assert_true(left.to_bytes() == left_before)
  assert_true(right.to_bytes() == right_before)
}

///|
test "merging different compression parameters is rejected" {
  let left = @sketches.TDigest::new(50) catch { _ => abort("x") }
  let right = @sketches.TDigest::new(60) catch { _ => abort("x") }
  left.update(1.0) catch {
    _ => abort("u")
  }
  right.update(2.0) catch {
    _ => abort("u")
  }
  let rejected = try {
    let _ = left.merge(right)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "malformed streams are rejected" {
  let digest = tdigest_of([1.0, 2.0, 3.0, 4.0, 5.0])
  let bytes = digest.to_bytes()
  let corrupt = fn(offset : Int32, value : Int32) -> Bytes {
    let copy = FixedArray::make(bytes.length(), b'\x00')
    for index in 0..<bytes.length() {
      copy[index] = bytes[index]
    }
    copy[offset] = value.to_byte()
    Bytes::from_array(copy.exact_view())
  }
  let rejects = fn(candidate : BytesView) -> Bool {
    try {
      let _ = @sketches.TDigest::from_bytes(candidate)
      false
    } catch {
      _ => true
    }
  }
  assert_true(rejects(corrupt(0, 9).exact_view()))
  assert_true(rejects(corrupt(1, 1).exact_view()))
  assert_true(rejects(bytes.exact_view(start=0, end=10)))
}
