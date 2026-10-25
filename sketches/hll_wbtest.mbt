/// Whitebox tests: the pieces the public API hides, so a change in the hash or
/// the rank rule fails here rather than as a mysterious estimate drift.

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
  inspect(sketch.registers[0], content="61")
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
    content="010400000000010000000100000000010000",
  )
}
