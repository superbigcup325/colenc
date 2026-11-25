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
test "opposite finite extremes interpolate to a finite median" {
  let digest = tdigest_of([-1.0e308, 1.0e308])
  assert_eq(digest.quantile(0.5), 0.0)
  assert_eq(digest.quantiles([0.25, 0.5, 0.75]), [-1.0e308, 0.0, 1.0e308])
}

///|
test "a quantile at the largest finite centroid returns its mean" {
  let largest = 1.7976931348623157e308
  let lower = 2.9937604643020797e292
  let digest = tdigest_of([lower, largest])
  assert_eq(digest.quantile(0.75), largest)
  assert_eq(digest.quantiles([0.75]), [largest])
}

///|
test "repeated finite extremes compress to centroids that survive serialization" {
  for value in [-1.0e308, 1.0e308] {
    let digest = tdigest_of(Array::make(1000, value))
    let back = @sketches.TDigest::from_bytes(digest.to_bytes().exact_view())
    assert_eq(back.count(), 1000.0)
    assert_eq(back.quantile(0.5), value)
  }
}

///|
test "compressing repeated fractional values preserves their exact extrema" {
  for value in [-0.1, 0.1] {
    let digest = tdigest_of(Array::make(1000, value))
    let restored = @sketches.TDigest::from_bytes(digest.to_bytes().exact_view())
    assert_eq(restored.quantile(0.5), value)
  }
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
test "batch quantiles match scalar queries in input order" {
  let values = Array::makei(1000, fn(index) {
    (index * 37 % 1009).to_double() / 3.0
  })
  let digest = tdigest_of(values)
  let qs : Array[Double] = [0.9, 0.0, 0.5, 0.5, 1.0, 0.25, 0.75]
  let got = digest.quantiles(qs) catch { _ => abort("batch quantiles raised") }
  assert_eq(got.length(), qs.length())
  for index in 0..<qs.length() {
    let expected = digest.quantile(qs[index]) catch {
      _ => abort("scalar quantile raised")
    }
    assert_eq(got[index], expected)
  }
  let buffered = tdigest_of([1.0, 2.0, 4.0, 8.0])
  let buffered_got = buffered.quantiles(qs) catch {
    _ => abort("buffered batch quantiles raised")
  }
  for index in 0..<qs.length() {
    let expected = buffered.quantile(qs[index]) catch {
      _ => abort("buffered scalar quantile raised")
    }
    assert_eq(buffered_got[index], expected)
  }
  assert_eq(
    (digest.quantiles([]) catch { _ => abort("empty batch raised") }).length(),
    0,
  )
  let invalid = try {
    let _ = digest.quantiles([0.5, 1.1])
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
  let empty = @sketches.TDigest::new_default()
  let no_values = try {
    let _ = empty.quantiles([0.5])
    false
  } catch {
    _ => true
  }
  assert_true(no_values)
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
test "self merge rejects a count that would overflow" {
  let mut digest = tdigest_of([0.0])
  for _ in 0..<1023 {
    digest = digest.merge(digest)
  }
  let bytes = digest.to_bytes()
  let round_trip = @sketches.TDigest::from_bytes(bytes.exact_view())
  assert_eq(round_trip.count(), digest.count())
  let outcome = try {
    let merged = digest.merge(digest)
    "merge succeeded with count \{merged.count()}"
  } catch {
    @types.EncodingError::InvalidArgument(_) => "rejected"
    error => @types.EncodingError::message(error)
  }
  assert_eq(outcome, "rejected")
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

///|
test "a short t-digest reports the size of the missing centroid body" {
  let bytes = tdigest_of([1.0]).to_bytes()
  let needed = try {
    ignore(@sketches.TDigest::from_bytes(bytes.exact_view(end=23)))
    abort("expected a truncated centroid")
  } catch {
    @types.EncodingError::Truncated(23, need, 0) => need
    _ => abort("expected a Truncated at the first centroid")
  }
  assert_eq(needed, 16)
}

///|
test "a centroid count whose high bit is set is refused" {
  // The count is a u32 in the format, and the reader assembles it into an
  // `Int32`, so 2^31 comes back negative: a negative count passes the
  // `count > 2k + 1` ceiling, and `23 + count * 16` wraps to 23, which a
  // 23-byte frame matches exactly. The reader then returned `has_values` with
  // no centroids, and `quantile` indexed `weights[-1]`, which aborts the
  // process instead of raising. Every high nibble that overflows `count * 16`
  // has to be refused, not just the one a test happens to pick.
  for high in [0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0] {
    let frame = FixedArray::make(23, b'\x00')
    frame[0] = b'\x01' // version
    frame[1] = b'\x0a' // compression 10
    frame[2] = b'\x00'
    frame[3] = b'\x00'
    frame[4] = b'\x00'
    frame[5] = b'\x00'
    frame[6] = high.to_byte() // the count's top byte
    let bytes = Bytes::from_array(frame.exact_view())
    let at = try {
      let _ = @sketches.TDigest::from_bytes(bytes.exact_view())
      abort("a negative centroid count was accepted")
    } catch {
      @types.EncodingError::Corrupt(at) => at
      _ => abort("expected Corrupt(3)")
    }
    assert_eq(at, 3)
  }
}

///|
fn tdigest_frame_put_f64(
  out : FixedArray[Byte],
  at : Int32,
  value : Double,
) -> Unit {
  let bits = value.reinterpret_as_int64()
  for index in 0..<8 {
    out[at + index] = ((bits >> (index * 8)) & 0xFFL).to_int().to_byte()
  }
}

///|
test "a centroid count above 2k + 1 and an infinite weight sum are refused" {
  // A frame whose length matches its count is not enough: the count itself has
  // a ceiling (`2k + 1`, here 21 at compression 10), and the weights, each
  // finite, can still sum to an infinity that every quantile would work in.
  let over = FixedArray::make(23 + 22 * 16, b'\x00')
  over[0] = b'\x01'
  over[1] = b'\x0a'
  over[2] = b'\x00'
  over[3] = b'\x16' // count 22
  let over_bytes = Bytes::from_array(over.exact_view())
  let at = try {
    let _ = @sketches.TDigest::from_bytes(over_bytes.exact_view())
    abort("a count above 2k + 1 was accepted")
  } catch {
    @types.EncodingError::Corrupt(at) => at
    _ => abort("expected Corrupt(3)")
  }
  assert_eq(at, 3)
  let huge = 1.7e308
  let overflowing = FixedArray::make(23 + 2 * 16, b'\x00')
  overflowing[0] = b'\x01'
  overflowing[1] = b'\x64' // compression 100
  overflowing[2] = b'\x00'
  overflowing[3] = b'\x02' // count 2
  tdigest_frame_put_f64(overflowing, 7, 0.0) // minimum
  tdigest_frame_put_f64(overflowing, 15, 1.0) // maximum
  tdigest_frame_put_f64(overflowing, 23, 0.5)
  tdigest_frame_put_f64(overflowing, 31, huge)
  tdigest_frame_put_f64(overflowing, 39, 0.5)
  tdigest_frame_put_f64(overflowing, 47, huge)
  let overflowing_bytes = Bytes::from_array(overflowing.exact_view())
  let weight_at = try {
    let _ = @sketches.TDigest::from_bytes(overflowing_bytes.exact_view())
    abort("an infinite weight sum was accepted")
  } catch {
    @types.EncodingError::Corrupt(at) => at
    _ => abort("expected Corrupt at the last weight")
  }
  assert_eq(weight_at, 47)
}

///|
test "the serialized form of a fixed sequence is pinned" {
  // The three backends have to produce these bytes, which is what keeps the
  // compression decisions (they depend on `asin`) from drifting apart silently.
  let digest = @sketches.TDigest::new(20) catch { _ => abort("x") }
  for index in 0..<300 {
    digest.update((index % 37).to_double() * 1.5) catch {
      _ => abort("u")
    }
  }
  let bytes = digest.to_bytes()
  let mut hex = ""
  for index in 0..<bytes.length() {
    let byte = bytes[index].to_int()
    if byte < 16 {
      hex = hex + "0"
    }
    hex = hex + byte.to_string()
  }
  inspect(
    hex,
    content="0120000110000000000000000000000000000000000756400000000000000000000000000001664454545454545245630000000000004964000000000019219640000000000005664171170170170170106366400000000000066641162096923932124964000000000000706445100330118972586400000000000071644718623216213994656400000000000070642168094671214569640000000000006764219182109219182617264000000000000606437731463673507464000000000000446400000000000075640000000000002064",
  )
}
