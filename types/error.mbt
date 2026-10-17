/// Errors from the encoding layer. Decoding errors carry a byte offset so a
/// caller can say where the page went bad instead of panicking.

///|
pub(all) suberror EncodingError {
  /// A decode needed more bytes than the input has: offset, needed, available.
  Truncated(Int32, Int32, Int32)
  /// The requested encoding family is not implemented (yet).
  Unsupported(Encoding)
  /// A negative value count or length.
  InvalidCount(Int32)
  /// A bit width outside the supported 0..64 range.
  InvalidBitWidth(Int32)
  /// The encoding exists but does not apply to this physical type.
  TypeMismatch(PhysicalType, Encoding)
  /// The stream ended before the requested values: decoded, expected.
  Incomplete(Int32, Int32)
  /// A dictionary index outside the dictionary: index, dictionary size.
  InvalidIndex(Int32, Int32)
}

///|
pub fn EncodingError::message(self : EncodingError) -> String {
  match self {
    Truncated(offset, need, available) =>
      "byte \{offset}: need \{need}, available \{available}"
    Unsupported(encoding) =>
      "encoding not implemented: \{encoding_name(encoding)}"
    InvalidCount(count) => "negative value count \{count}"
    InvalidBitWidth(width) => "bit width \{width} outside 0..64"
    TypeMismatch(ty, encoding) =>
      "\{encoding_name(encoding)} does not apply to \{physical_type_name(ty)}"
    Incomplete(decoded, expected) =>
      "stream ended after \{decoded} values, \{expected} requested"
    InvalidIndex(index, size) =>
      "dictionary index \{index} outside 0..\{size - 1}"
  }
}

///|
pub fn encoding_name(encoding : Encoding) -> String {
  match encoding {
    Plain => "PLAIN"
    Rle => "RLE"
    Dictionary => "DICTIONARY"
    DeltaBinaryPacked => "DELTA_BINARY_PACKED"
    DeltaLength => "DELTA_LENGTH_BYTE_ARRAY"
    DeltaByteArray => "DELTA_BYTE_ARRAY"
    ByteStreamSplit => "BYTE_STREAM_SPLIT"
    Fsst => "FSST"
  }
}

///|
pub fn physical_type_name(ty : PhysicalType) -> String {
  match ty {
    Int32 => "INT32"
    Int64 => "INT64"
    Float => "FLOAT"
    Double => "DOUBLE"
    ByteArray => "BYTE_ARRAY"
    Bool => "BOOLEAN"
  }
}
