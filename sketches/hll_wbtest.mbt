/// Whitebox tests: the pieces the public API hides, so a change in the hash or
/// the rank rule fails here rather than as a mysterious estimate drift.

///|
/// Which register representation a sketch is holding. The choice is internal, so
/// only a whitebox test can see it — and only a whitebox test can prove that it
/// does not change a register, an estimate or a byte.
fn HllSketch::is_sparse(self : HllSketch) -> Bool {
  match self.registers {
    Sparse(_) => true
    Dense(_) => false
  }
}

///|
fn hll_hex(bytes : Bytes) -> String {
  let mut out = ""
  for index in 0..<bytes.length() {
    let byte = bytes[index].to_int()
    if byte < 16 {
      out = out + "0"
    }
    out = out + byte.to_string()
  }
  out
}

///|
test "the hash is MurmurHash3 x64 128, lower half, seed 0" {
  // The pinned value was produced by an independent implementation of the same
  // algorithm, not by this code, so it checks the mix, the rotation offsets and
  // the tail handling rather than only the fact that the answer is stable.
  let value = 1065353216L
  let scratch : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  for index in 0..<8 {
    scratch[index] = (value >> (8 * index)).to_byte()
  }
  let hash = hll_hash(scratch.unsafe_reinterpret_as_bytes().exact_view())
  inspect(hash, content="1190283028274821352")
  inspect(hll_hash(Bytes::from_array([]).exact_view()), content="0")
}

///|
test "leading zeros ladder" {
  inspect(hll_leading_zeros(0UL), content="64")
  inspect(hll_leading_zeros(1UL), content="63")
  inspect(hll_leading_zeros(0x8000000000000000UL), content="0")
  inspect(hll_leading_zeros(0x00FF000000000000UL), content="8")
}

///|
test "the rank ceiling follows the precision" {
  let sketch = HllSketch::new(4) catch { _ => abort("precision 4 rejected") }
  // A hash of zero has no set bit among its rank bits, so the rank is the
  // ceiling: 64 - precision + 1.
  sketch.absorb_hash(0UL)
  inspect(sketch.rank_at(0), content="61")
  // Precision 4 never goes sparse, so the same read reaches the dense arm.
  assert_true(!sketch.is_sparse())
}

///|
test "the serialized form of a fixed sequence" {
  // Pinned so all three backends have to agree on the bytes, not only on the
  // estimate: version, precision, then one byte per register.
  let sketch = HllSketch::new(4) catch { _ => abort("precision 4 rejected") }
  for value in [1, 2, 3, 1000] {
    sketch.add_int32(value)
  }
  inspect(
    hll_hex(sketch.to_bytes()),
    content="010400000000010000000100000000020000",
  )
}

///|
test "register reads one rank and reports a bad index as an error" {
  let sketch = HllSketch::new(4) catch { _ => abort("precision 4 rejected") }
  sketch.absorb_hash(0UL)
  assert_eq(sketch.register(0) catch { _ => -1 }, 61)
  assert_eq(sketch.register(15) catch { _ => -1 }, 0)
  let mut raised = 0
  ignore(
    sketch.register(-1) catch {
      _ => {
        raised += 1
        0
      }
    },
  )
  ignore(
    sketch.register(16) catch {
      _ => {
        raised += 1
        0
      }
    },
  )
  assert_eq(raised, 2)
}

///|
test "registers is a snapshot of the byte state, not a live view" {
  let sketch = HllSketch::new(4) catch { _ => abort("precision 4 rejected") }
  let before = sketch.registers()
  assert_eq(before.length(), 16)
  sketch.absorb_hash(0UL)
  assert_eq(before[0], 0)
  assert_eq(sketch.registers()[0], 61)
  // The register count is the precision's, whatever the representation holds.
  assert_eq(sketch.register_count(), 16)
}

///|
test "every legal rank survives the byte state and the serialized round trip" {
  // Ranks 0 through the ceiling for each precision, written register by register
  // into a serialized state and read back: the bytes are the input, so this
  // covers whatever representation the reader decides those bytes deserve.
  for precision in 4..<=16 {
    let ceiling = 64 - precision + 1
    let count = 1 << precision
    let bytes = FixedArray::make(2 + count, b'\x00')
    bytes[0] = HLL_VERSION.to_byte()
    bytes[1] = precision.to_byte()
    for index in 0..<count {
      bytes[2 + index] = (index % (ceiling + 1)).to_byte()
    }
    let raw = Bytes::from_array(bytes.exact_view())
    let sketch = HllSketch::from_bytes(raw.exact_view()) catch {
      _ => abort("round trip rejected")
    }
    for index in 0..<count {
      assert_eq(sketch.register(index) catch { _ => -1 }, index % (ceiling + 1))
    }
    assert_eq(sketch.to_bytes(), raw)
  }
}

///|
test "the sparse state survives insertion order" {
  // Values that land in scattered registers, so the sorted insertion has to
  // move entries rather than append them.
  let scattered = HllSketch::new_default()
  for value in 0..<100 {
    scattered.add_int64(value.to_int64() * 2654435761L % 16384L)
  }
  assert_true(scattered.is_sparse())
  let bytes = scattered.to_bytes()
  // The same registers read back through a dense state must answer identically.
  let back = HllSketch::from_bytes(bytes.exact_view()) catch {
    _ => abort("from_bytes rejected")
  }
  let before = scattered.registers()
  let after = back.registers()
  for index in 0..<before.length() {
    assert_eq(before[index], after[index])
  }
  assert_true(scattered.estimate() == back.estimate())
}

///|
test "the representation changes neither the answer nor the bytes" {
  let sketch = HllSketch::new_default()
  for value in 0..<60 {
    sketch.add_int32(value)
  }
  assert_true(sketch.is_sparse())
  let bytes = sketch.to_bytes()
  let registers = sketch.registers()
  let estimate = sketch.estimate()
  ignore(sketch.promote())
  assert_true(!sketch.is_sparse())
  assert_eq(sketch.to_bytes(), bytes)
  assert_true(sketch.estimate() == estimate)
  let promoted = sketch.registers()
  for index in 0..<registers.length() {
    assert_eq(registers[index], promoted[index])
  }
}

///|
test "a group promotes to dense when it outgrows the sparse state" {
  let sketch = HllSketch::new_default()
  let mut live = 0
  while sketch.is_sparse() && live < 20000 {
    sketch.add_int64(live.to_int64() * 7919L)
    live += 1
  }
  assert_true(!sketch.is_sparse())
  // The estimate stays inside the interval after the switch.
  let estimate = sketch.estimate()
  let error = (estimate - live.to_double()) / live.to_double()
  assert_true(error > -0.05 && error < 0.05)
}

///|
test "merging two sparse sketches stays sparse and matches the dense union" {
  let a = HllSketch::new_default()
  let b = HllSketch::new_default()
  for value in 0..<40 {
    a.add_int32(value)
    b.add_int32(value + 40)
  }
  assert_true(a.is_sparse())
  assert_true(b.is_sparse())
  let merged = a.merge(b) catch { _ => abort("merge rejected") }
  assert_true(merged.is_sparse())
  let direct = HllSketch::new_default()
  for value in 0..<80 {
    direct.add_int32(value)
  }
  assert_eq(merged.to_bytes(), direct.to_bytes())
}

///|
test "reading a serialized state back keeps a small one sparse" {
  let small = HllSketch::new_default()
  for value in 0..<20 {
    small.add_int32(value)
  }
  let small_back = HllSketch::from_bytes(small.to_bytes()[:]) catch {
    _ => abort("from_bytes rejected")
  }
  assert_true(small_back.is_sparse())
  let large = HllSketch::new_default()
  for value in 0..<5000 {
    large.add_int32(value)
  }
  let large_back = HllSketch::from_bytes(large.to_bytes()[:]) catch {
    _ => abort("from_bytes rejected")
  }
  assert_true(!large_back.is_sparse())
  assert_eq(large_back.to_bytes(), large.to_bytes())
}

///|
test "precision below 9 never goes sparse" {
  for precision in 4..<=8 {
    let sketch = HllSketch::new(precision) catch { _ => abort("rejected") }
    assert_true(!sketch.is_sparse())
  }
  let smallest_sparse = HllSketch::new(9) catch { _ => abort("rejected") }
  assert_true(smallest_sparse.is_sparse())
}

///|
test "the promotion limit never reaches the dense form's size" {
  // An eighth of the register count, capped: 512 registers at precision 9 allow
  // 64 entries, everything from precision 10 up allows 128, and a dense array of
  // at most 512 bytes is not worth a second representation at all.
  assert_eq(hll_sparse_limit(4), 0)
  assert_eq(hll_sparse_limit(8), 0)
  assert_eq(hll_sparse_limit(9), 64)
  assert_eq(hll_sparse_limit(10), 128)
  assert_eq(hll_sparse_limit(14), 128)
  assert_eq(hll_sparse_limit(16), 128)
}
