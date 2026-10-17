// Property tests for the FSST-style compressor: repetitive strings, random
// lengths and shared substrings must round trip exactly.

///|
struct FsstRng {
  mut state : UInt64
}

///|
fn FsstRng::new(seed : Int32) -> FsstRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn FsstRng::next_u64(self : FsstRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn FsstRng::next_int(self : FsstRng, bound : Int32) -> Int32 {
  (self.next_u64() >> 33).to_int() % bound
}

///|
test "property: fsst round trips repetitive columns" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = FsstRng::new(seed)
      let pieces = ["alpha", "beta", "gamma-", "delta", "0123456789"]
      let count = rng.next_int(80)
      let values = Array::makei(count, fn(_) {
        let repeats = 1 + rng.next_int(4)
        let buffer = Buffer()
        for _ in 0..<repeats {
          buffer.write_bytes(
            @utf8.encode(pieces[rng.next_int(pieces.length())]),
          )
        }
        buffer.to_bytes()
      })
      let out = @buffer.Buffer()
      @encoders.encode_fsst(values, out)
      let bytes = out.to_bytes()
      let decoded = @encoders.decode_fsst(bytes, count) catch { _ => ([], -1) }
      decoded.0 == values && decoded.1 == bytes.length()
    }),
    max_success=80,
  )
}
