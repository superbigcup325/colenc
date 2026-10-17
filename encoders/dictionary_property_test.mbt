// Property tests for dictionary encoding: low-cardinality columns must round
// trip and the dictionary must never hold duplicates.

///|
struct DictRng {
  mut state : UInt64
}

///|
fn DictRng::new(seed : Int32) -> DictRng {
  { state: seed.to_uint64() * 6364136223846793005UL + 1442695040888963407UL, }
}

///|
fn DictRng::next_u64(self : DictRng) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn DictRng::next_int(self : DictRng, bound : Int32) -> Int32 {
  (self.next_u64() >> 33).to_int() % bound
}

///|
test "property: low-cardinality int columns round trip through a dictionary" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = DictRng::new(seed)
      let cardinality = 1 + rng.next_int(10)
      let length = rng.next_int(300)
      let values = Array::makei(length, _ => rng.next_int(cardinality) - 3)
      let encoding = @encoders.encode_dictionary(@types.ColBuf::Int32s(values)) catch {
        _ => None
      }
      match encoding {
        None => false
        Some(encoding) => {
          let back = @encoders.decode_dictionary(
            encoding.dictionary,
            encoding.indices,
            @types.Int32,
            length,
            encoding.dictionary_size,
          ) catch {
            _ => abort("decode failed")
          }
          let dict_ok = encoding.dictionary_size <= cardinality &&
            encoding.dictionary_size >= 1
          match back {
            Int32s(got) => dict_ok && got == values
            _ => false
          }
        }
      }
    }),
    max_success=100,
  )
}

///|
test "property: low-cardinality string columns round trip through a dictionary" {
  @qc.quick_check(
    @qc.forall(@gen.int_range(1, 1000000), seed => {
      let rng = DictRng::new(seed)
      let cardinality = 1 + rng.next_int(8)
      let length = rng.next_int(200)
      let values = Array::makei(length, fn(_) {
        let suffix = rng.next_int(cardinality).to_string()
        "label-" + suffix
      })
      let encoding = @encoders.encode_dictionary(
        @types.ColBuf::ByteArrays(values.map(fn(value) { @utf8.encode(value) })),
      ) catch {
        _ => None
      }
      match encoding {
        None => false
        Some(encoding) => {
          let back = @encoders.decode_dictionary(
            encoding.dictionary,
            encoding.indices,
            @types.ByteArray,
            length,
            encoding.dictionary_size,
          ) catch {
            _ => abort("decode failed")
          }
          let expected = values.map(fn(value) { @utf8.encode(value) })
          match back {
            ByteArrays(got) => got == expected
            _ => false
          }
        }
      }
    }),
    max_success=80,
  )
}
