// Property tests for BYTE_STREAM_SPLIT: arbitrary bit patterns, including NaN
// and infinities, must survive encode then decode bit for bit.

///|
struct BssRng {
  mut state : UInt64
}

///|
fn BssRng::new(seed : Int32) -> BssRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn BssRng::next_u64(self : BssRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
test "property: byte stream split float round trips bit patterns" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = BssRng::new(seed)
      let count = rng.next_u64().to_int() % 200
      let values = Array::makei(count, fn(_) {
        Float::reinterpret_from_int(rng.next_u64().to_int())
      })
      let out = @buffer.Buffer()
      @encoders.encode_byte_stream_split_float(values, out)
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_byte_stream_split_float(bytes, count) catch {
        _ => []
      }
      let mut ok = decoded.length() == values.length()
      if ok {
        for index in 0..<values.length() {
          if decoded[index].reinterpret_as_int() !=
            values[index].reinterpret_as_int() {
            ok = false
          }
        }
      }
      ok
    }),
    max_success=100,
  )
}

///|
test "property: byte stream split double round trips bit patterns" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = BssRng::new(seed)
      let count = rng.next_u64().to_int() % 200
      let values = Array::makei(count, fn(_) {
        rng.next_u64().reinterpret_as_double()
      })
      let out = @buffer.Buffer()
      @encoders.encode_byte_stream_split_double(values, out)
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_byte_stream_split_double(bytes, count) catch {
        _ => []
      }
      let mut ok = decoded.length() == values.length()
      if ok {
        for index in 0..<values.length() {
          if decoded[index].reinterpret_as_uint64() !=
            values[index].reinterpret_as_uint64() {
            ok = false
          }
        }
      }
      ok
    }),
    max_success=100,
  )
}
