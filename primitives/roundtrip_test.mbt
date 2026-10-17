// Property tests: random widths, counts and values, generated from the
// quickcheck seed so a failure reproduces exactly.

///|
/// 64-bit LCG: deterministic in the seed, and cheap enough to draw a few
/// hundred values per case.

///|
struct Rng {
  mut state : UInt64
}

///|
fn Rng::new(seed : Int32) -> Rng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn Rng::next_u64(self : Rng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn Rng::next_int(self : Rng, bound : Int32) -> Int32 {
  // every call site passes a positive bound
  (self.next_u64() >> 33).to_int() % bound
}

///|
fn mask_to_width(value : UInt64, width : Int32) -> Int64 {
  let masked = if width == 64 { value } else { value & ((1UL << width) - 1UL) }
  masked.reinterpret_as_int64()
}

///|
test "property: bit_pack then bit_unpack returns the values" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = Rng::new(seed)
      let width = rng.next_int(65)
      let count = rng.next_int(200)
      let values = Array::makei(count, _ => mask_to_width(rng.next_u64(), width))
      let buffer = @buffer.Buffer()
      @primitives.bit_pack(values[:], width, buffer) catch {
        _ => ()
      }
      let bytes = buffer.to_bytes()
      let decoded = @primitives.bit_unpack(bytes, width, count) catch {
        _ => []
      }
      let expected_bytes = (width * count + 7) / 8
      bytes.length() == expected_bytes && decoded == values
    }),
    max_success=100,
  )
}

///|
test "property: uleb128 round trips at every width" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = Rng::new(seed)
      let values = Array::makei(1 + rng.next_int(50), _ => rng.next_u64())
      let buffer = @buffer.Buffer()
      for value in values {
        @primitives.put_uleb128(buffer, value)
      }
      let bytes = buffer.to_bytes()
      let mut pos = 0
      let mut ok = true
      for value in values {
        let (decoded, consumed) = @primitives.read_uleb128(bytes, offset=pos) catch {
          _ => (0UL, -1)
        }
        ok = ok && decoded == value && consumed > 0
        if consumed > 0 {
          pos += consumed
        }
      }
      ok && pos == bytes.length()
    }),
    max_success=100,
  )
}

///|
test "property: zigzag round trips signed values" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = Rng::new(seed)
      let values = Array::makei(1 + rng.next_int(50), _ => {
        rng.next_u64().reinterpret_as_int64()
      })
      let buffer = @buffer.Buffer()
      for value in values {
        @primitives.put_zigzag(buffer, value)
      }
      let bytes = buffer.to_bytes()
      let mut pos = 0
      let mut ok = true
      for value in values {
        let (decoded, consumed) = @primitives.read_zigzag(bytes, offset=pos) catch {
          _ => (0L, -1)
        }
        ok = ok && decoded == value && consumed > 0
        if consumed > 0 {
          pos += consumed
        }
      }
      ok && pos == bytes.length()
    }),
    max_success=100,
  )
}
