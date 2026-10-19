/// Snapshot tests for the FSST stream.
///
/// FSST has no Parquet-native format to diff against — the criteria are round
/// trip plus the compression scoreboard — so nothing in the suite would notice
/// an "equivalent" rewrite that produced a different but same-sized stream.
/// These digests pin the bytes, which is the only way a reader can tell that a
/// speed change did not move the stream the scoreboard is measured on.

///|
/// FNV-1a over the encoded payload.
fn fsst_fnv1a(data : Bytes) -> UInt64 {
  let mut hash = 0xCBF29CE484222325UL
  for byte in data {
    hash = (hash ^ byte.to_uint64()) * 0x100000001B3UL
  }
  hash
}

///|
fn fsst_digest(values : Array[Bytes]) -> (Int32, UInt64) {
  let out = Buffer()
  @encoders.encode_fsst(values, out)
  (out.length(), fsst_fnv1a(out.to_bytes()))
}

///|
test "fsst output is pinned byte for byte" {
  // Stored mode: the table does not pay for itself on a scattering of phrases.
  let small : Array[Bytes] = [
    b"the quick brown fox", b"the quick brown fox jumps", b"jumps over the lazy dog",
    b"the lazy dog", b"", b"abcabcabcabc", b"abcabc", b"label-0", b"label-1", b"label-0",
    b"shared-prefix-1", b"shared-prefix-2", b"shared-prefix-10",
  ]
  let (length, hash) = fsst_digest(small)
  assert_eq(length, 221)
  assert_eq(hash, 0xB19D515544AB6008UL)

  // Compressed mode, one repeated sentence.
  let repetitive = Array::make(
    200, b"the quick brown fox jumps over the lazy dog",
  )
  let (length, hash) = fsst_digest(repetitive)
  assert_eq(length, 3558)
  assert_eq(hash, 0x0116592321120279UL)

  // Compressed mode, sixteen distinct labels.
  let labels = Array::makei(500, fn(i) {
    @utf8.encode("label-\{(i % 16).to_string()}")
  })
  let (length, hash) = fsst_digest(labels)
  assert_eq(length, 3153)
  assert_eq(hash, 0xD166243449790057UL)

  // Compressed mode, a shared prefix with a varying suffix.
  let prefixes = Array::makei(500, fn(i) {
    @utf8.encode("shared-prefix-value-\{i.to_string()}")
  })
  let (length, hash) = fsst_digest(prefixes)
  assert_eq(length, 6692)
  assert_eq(hash, 0x93A9C06C482F4C77UL)

  // Compressed mode, high cardinality: the table mostly escapes.
  let noise = Array::makei(500, fn(i) {
    let seed = (i * 1103515245 + 12345) & 0x3FFFFFFF
    @utf8.encode(
      "\{((seed & 0xFF)).to_string()}-\{((seed >> 8) & 0xFF).to_string()}-\{((seed >> 16) & 0x3FFF).to_string()}",
    )
  })
  let (length, hash) = fsst_digest(noise)
  assert_eq(length, 5944)
  assert_eq(hash, 0x5312CC6A77C8D0A4UL)
}
