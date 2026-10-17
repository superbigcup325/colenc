/// Errors from the primitive layer. Decoding errors carry the byte offset so a
/// caller can say where the stream went bad instead of panicking.

///|
pub(all) suberror PrimitivesError {
  /// A read needed more bytes than the input has: offset, needed, available.
  Truncated(Int32, Int32, Int32)
  /// A varint that never terminates within 64 bits; offset of its first byte.
  InvalidVarint(Int32)
  /// A bit width outside the supported 0..64 range.
  InvalidBitWidth(Int32)
  /// A negative value count passed to a decoder.
  InvalidCount(Int32)
}

///|
pub fn PrimitivesError::message(self : PrimitivesError) -> String {
  match self {
    Truncated(offset, need, available) =>
      "byte \{offset}: need \{need}, available \{available}"
    InvalidVarint(offset) => "byte \{offset}: varint longer than 64 bits"
    InvalidBitWidth(width) => "bit width \{width} outside 0..64"
    InvalidCount(count) => "negative value count \{count}"
  }
}
