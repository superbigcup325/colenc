/// Whitebox tests for the t-digest's internal ordering: the merge-based sorted
/// list must be exactly the list the tuple sort produced.

///|
fn td_parts_match(digest : TDigest) -> Unit raise Error {
  let (means, weights) = tdigest_sorted_parts(digest)
  let (expected_means, expected_weights) = tdigest_split(tdigest_pairs(digest))
  assert_eq(means, expected_means)
  assert_eq(weights, expected_weights)
}

///|
test "sorted parts equal the tuple sort at every stage of a tied stream" {
  let digest = TDigest::new(10) catch { _ => abort("compression rejected") }
  for round in 0..<8 {
    for index in 0..<173 {
      // 50 distinct values, so centroid means and buffer values collide
      let value = ((index * 37 + round * 11) % 50).to_double()
      digest.update(value) catch {
        _ => abort("update raised")
      }
      if index % 7 == 0 {
        td_parts_match(digest)
      }
    }
  }
  td_parts_match(digest)
}

///|
test "sorted parts equal the tuple sort for distinct and signed values" {
  let digest = TDigest::new_default()
  for index in 0..<5000 {
    let value = (index * 7919 % 10007 - 5000).to_double() / 8.0
    digest.update(value) catch {
      _ => abort("update raised")
    }
  }
  td_parts_match(digest)
  digest.update(0.0) catch {
    _ => abort("update raised")
  }
  digest.update(-0.0) catch {
    _ => abort("update raised")
  }
  td_parts_match(digest)
}

///|
test "centroids out of order fall back to the tuple sort" {
  let digest = TDigest::new(10) catch { _ => abort("compression rejected") }
  digest.means = [3.0, 1.0, 2.0]
  digest.weights = [4.0, 2.0, 1.0]
  digest.buffer = [2.0, 0.5, 3.0]
  td_parts_match(digest)
  let (means, _) = tdigest_sorted_parts(digest)
  assert_eq(means, [0.5, 1.0, 2.0, 2.0, 3.0, 3.0])
}

///|
test "an empty digest and a buffer-only digest have sorted parts" {
  let empty = TDigest::new_default()
  td_parts_match(empty)
  let only_buffer = TDigest::new_default()
  for value in [5.0, 1.0, 3.0, 1.0] {
    only_buffer.update(value) catch {
      _ => abort("update raised")
    }
  }
  td_parts_match(only_buffer)
  let (means, weights) = tdigest_sorted_parts(only_buffer)
  assert_eq(means, [1.0, 1.0, 3.0, 5.0])
  assert_eq(weights, [1.0, 1.0, 1.0, 1.0])
}
