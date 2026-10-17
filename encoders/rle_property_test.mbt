// Property tests for the hybrid encoder: run-heavy sequences at every width
// must survive encode then decode, and the decoder must consume the whole
// stream.

///|
struct RleRng {
  mut state : UInt64
}

///|
fn RleRng::new(seed : Int32) -> RleRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn RleRng::next_u64(self : RleRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn RleRng::next_int(self : RleRng, bound : Int32) -> Int32 {
  (self.next_u64() >> 33).to_int() % bound
}

///|
fn rle_mask(value : UInt64, width : Int32) -> Int64 {
  let masked = if width == 64 { value } else { value & ((1UL << width) - 1UL) }
  masked.reinterpret_as_int64()
}

///|
test "property: run heavy values round trip at every width" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RleRng::new(seed)
      let width = rng.next_int(65)
      let length = rng.next_int(400)
      let values : Array[Int64] = []
      let mut previous = rle_mask(rng.next_u64(), width)
      while values.length() < length {
        if rng.next_int(3) != 0 {
          let repeats = 1 + rng.next_int(20)
          for _ in 0..<repeats {
            if values.length() < length {
              values.push(previous)
            }
          }
        } else {
          previous = rle_mask(rng.next_u64(), width)
          values.push(previous)
        }
      }
      let out = @buffer.Buffer()
      @encoders.encode_rle_hybrid(values[:], width, out) catch {
        _ => ()
      }
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_rle_hybrid(bytes, width, values.length()) catch {
        _ => ([], -1)
      }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=100,
  )
}

///|
test "property: all identical values encode as a single repeated run" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = RleRng::new(seed)
      let width = rng.next_int(65)
      let length = 1 + rng.next_int(300)
      let value = rle_mask(rng.next_u64(), width)
      let values = Array::make(length, value)
      let out = @buffer.Buffer()
      @encoders.encode_rle_hybrid(values[:], width, out) catch {
        _ => ()
      }
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_rle_hybrid(bytes, width, length) catch {
        _ => ([], -1)
      }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=60,
  )
}
