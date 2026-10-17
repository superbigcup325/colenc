/// The neutral column model: physical types, encoding families, the column
/// buffer the library operates on, and the statistics an encode returns.
///
/// `Int32` maps to MoonBit's `Int`, which is a signed 32-bit integer on every
/// backend, so a 32-bit column needs no extra type.
///
/// v1 handles flat, non-null columns only. Validity (definition levels) is
/// deliberately absent from `ColBuf`: when level encoders land, this type grows
/// a validity field rather than a second parallel type.

///|
pub(all) enum PhysicalType {
  Int32
  Int64
  Float
  Double
  ByteArray
  Bool
}

///|
pub(all) enum Encoding {
  Plain
  Rle
  Dictionary
  DeltaBinaryPacked
  DeltaLength
  DeltaByteArray
  ByteStreamSplit
  Fsst
}

///|
/// A flat column of values, one variant per physical type.
pub(all) enum ColBuf {
  Int32s(Array[Int32])
  Int64s(Array[Int64])
  Floats(Array[Float])
  Doubles(Array[Double])
  ByteArrays(Array[Bytes])
  Bools(Array[Bool])
}

///|
pub fn ColBuf::value_count(self : ColBuf) -> Int32 {
  match self {
    Int32s(values) => values.length()
    Int64s(values) => values.length()
    Floats(values) => values.length()
    Doubles(values) => values.length()
    ByteArrays(values) => values.length()
    Bools(values) => values.length()
  }
}

///|
pub fn ColBuf::physical_type(self : ColBuf) -> PhysicalType {
  match self {
    Int32s(_) => Int32
    Int64s(_) => Int64
    Floats(_) => Float
    Doubles(_) => Double
    ByteArrays(_) => ByteArray
    Bools(_) => Bool
  }
}

///|
/// A dictionary-encoded column: the distinct values as their page payload, the
/// data page payload (bit-width byte plus hybrid indices), and the size and
/// width a reader needs.
pub(all) struct DictionaryEncoding {
  dictionary : Bytes
  indices : Bytes
  dictionary_size : Int32
  bit_width : Int32
}

///|
/// What an encode reports: how many values went in and how many bytes came out.
/// Compression ratios against the PLAIN baseline are computed from this.
pub(all) struct EncodingStats {
  value_count : Int32
  encoded_bytes : Int32
}
