// Property tests for the delta family: random sequences, including the
// extremes and block boundaries, must round trip exactly.

///|
struct DeltaRng {
  mut state : UInt64
}

///|
fn DeltaRng::new(seed : Int32) -> DeltaRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn DeltaRng::next_u64(self : DeltaRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn DeltaRng::next_int(self : DeltaRng, bound : Int32) -> Int32 {
  (self.next_u64() >> 33).to_int() % bound
}

///|
test "property: delta int64 round trips random sequences" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = DeltaRng::new(seed)
      let length = rng.next_int(700)
      let values = Array::makei(length, _ => {
        rng.next_u64().reinterpret_as_int64()
      })
      let out = @buffer.Buffer()
      @encoders.encode_delta_int64(values[:], out) catch {
        _ => ()
      }
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_delta_int64(bytes, length) catch {
        _ => ([], -1)
      }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=100,
  )
}

///|
test "property: delta int32 round trips random sequences" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = DeltaRng::new(seed)
      let length = rng.next_int(400)
      let values = Array::makei(length, _ => rng.next_u64().to_int())
      let out = @buffer.Buffer()
      @encoders.encode_delta_int32(values[:], out) catch {
        _ => ()
      }
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_delta_int32(bytes, length) catch {
        _ => ([], -1)
      }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=100,
  )
}

///|
test "property: delta byte array round trips shared prefixes" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = DeltaRng::new(seed)
      let length = rng.next_int(120)
      let prefix = "pre-" + rng.next_int(50).to_string()
      let values = Array::makei(length, fn(_) {
        @utf8.encode(prefix + rng.next_int(1000).to_string())
      })
      let out = @buffer.Buffer()
      @encoders.encode_delta_byte_array(values, out) catch {
        _ => ()
      }
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_delta_byte_array(bytes, length) catch {
        _ => ([], -1)
      }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=60,
  )
}
