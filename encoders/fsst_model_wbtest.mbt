/// Whitebox tests for the reusable FSST model: same bytes as the one-shot
/// encoder on its own training batch, and a round trip through the unchanged
/// decoder for batches the model never saw.

///|
/// ASCII text as bytes; the whitebox package has no utf8 import.
fn fsst_model_text(text : String) -> Bytes {
  let bytes : Array[Byte] = []
  for ch in text {
    bytes.push(ch.to_int().to_byte())
  }
  Bytes::from_array(bytes[:])
}

///|
fn fsst_model_words(count : Int32, prefix : String) -> Array[Bytes] {
  Array::makei(count, fn(i) { fsst_model_text(prefix + (i % 16).to_string()) })
}

///|
test "a model trained on a batch encodes it exactly as encode_fsst does" {
  for
    values in [
      fsst_model_words(500, "shared-prefix-"),
      fsst_model_words(7, "label-"),
      [],
      [b"", b"\xff\x00\xff"],
    ] {
    let one = Buffer()
    encode_fsst(values, one)
    let two = Buffer()
    encode_fsst_with(FsstModel::train(values), values, two)
    assert_eq(one.to_bytes(), two.to_bytes())
  }
}

///|
test "a model from other data round trips batches it never saw" {
  let model = FsstModel::train(fsst_model_words(500, "label-"))
  let batches : Array[Array[Bytes]] = [
    [],
    [b""],
    [b"", b"\xff\xff\x00", b"label-3", b"zzzzzzzzzzzz", b"\x00"],
    fsst_model_words(300, "label-"),
    fsst_model_words(300, "unrelated-text-"),
  ]
  for batch in batches {
    let out = Buffer()
    encode_fsst_with(model, batch, out)
    let (back, consumed) = decode_fsst(out.to_bytes()[:], batch.length()) catch {
      _ => abort("decode raised")
    }
    assert_eq(back, batch)
    assert_eq(consumed, out.length())
  }
}

///|
test "an empty model and a reused model are both immutable across calls" {
  let empty = FsstModel::train([])
  assert_eq(empty.symbol_count(), 0)
  assert_eq(empty.table_bytes(), 1)
  let batch = fsst_model_words(50, "label-")
  let first = Buffer()
  encode_fsst_with(empty, batch, first)
  let second = Buffer()
  encode_fsst_with(empty, batch, second)
  assert_eq(first.to_bytes(), second.to_bytes())
  let model = FsstModel::train(batch)
  let a = Buffer()
  encode_fsst_with(model, batch, a)
  let b = Buffer()
  encode_fsst_with(model, batch, b)
  assert_eq(a.to_bytes(), b.to_bytes())
  assert_eq(model.table_bytes() > 1, true)
}
