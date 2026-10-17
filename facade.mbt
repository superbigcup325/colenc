/// The dispatch layer: one entry point per direction, keyed by the neutral
/// `ColBuf` model. Encoders stay independent and testable; this file only
/// routes between them.
///
/// v1 decode is page-granular: RLE and DELTA are sequential encodings, so
/// callers split pages themselves. No IO happens here, and no consumer types
/// appear in the signatures.

///|
/// Encode a column with the requested family, appending to `out`. The returned
/// statistics describe this call only, so repeated encodes can be summed.
pub fn encode_column(
  column : @types.ColBuf,
  encoding : @types.Encoding,
  out : @buffer.Buffer,
) -> @types.EncodingStats raise @types.EncodingError {
  let start = out.length()
  match encoding {
    Plain =>
      match column {
        Int32s(values) => @encoders.encode_int32(values, out)
        Int64s(values) => @encoders.encode_int64(values, out)
        Floats(values) => @encoders.encode_float(values, out)
        Doubles(values) => @encoders.encode_double(values, out)
        ByteArrays(values) => @encoders.encode_byte_arrays(values, out)
        Bools(values) => @encoders.encode_bool(values, out)
      }
    Rle =>
      match column {
        Bools(values) => @encoders.encode_bool_rle(values, out)
        _ =>
          raise @types.EncodingError::TypeMismatch(column.physical_type(), Rle)
      }
    DeltaBinaryPacked =>
      match column {
        Int32s(values) => @encoders.encode_delta_int32(values[:], out)
        Int64s(values) => @encoders.encode_delta_int64(values[:], out)
        _ =>
          raise @types.EncodingError::TypeMismatch(
            column.physical_type(),
            DeltaBinaryPacked,
          )
      }
    DeltaLength =>
      match column {
        ByteArrays(values) =>
          @encoders.encode_delta_length_byte_array(values, out)
        _ =>
          raise @types.EncodingError::TypeMismatch(
            column.physical_type(),
            DeltaLength,
          )
      }
    DeltaByteArray =>
      match column {
        ByteArrays(values) => @encoders.encode_delta_byte_array(values, out)
        _ =>
          raise @types.EncodingError::TypeMismatch(
            column.physical_type(),
            DeltaByteArray,
          )
      }
    other => raise @types.EncodingError::Unsupported(other)
  }
  { value_count: column.value_count(), encoded_bytes: out.length() - start, }
}

///|
/// Decode `count` values of physical type `ty`. The input may be longer than
/// needed; trailing bytes belong to the caller.
pub fn decode_column(
  data : BytesView,
  ty : @types.PhysicalType,
  encoding : @types.Encoding,
  count : Int32,
) -> @types.ColBuf raise @types.EncodingError {
  match encoding {
    Plain =>
      match ty {
        Int32 => @types.ColBuf::Int32s(@encoders.decode_int32(data, count))
        Int64 => @types.ColBuf::Int64s(@encoders.decode_int64(data, count))
        Float => @types.ColBuf::Floats(@encoders.decode_float(data, count))
        Double => @types.ColBuf::Doubles(@encoders.decode_double(data, count))
        ByteArray =>
          @types.ColBuf::ByteArrays(@encoders.decode_byte_arrays(data, count))
        Bool => @types.ColBuf::Bools(@encoders.decode_bool(data, count))
      }
    Rle =>
      match ty {
        Bool => @types.ColBuf::Bools(@encoders.decode_bool_rle(data, count))
        _ => raise @types.EncodingError::TypeMismatch(ty, Rle)
      }
    DeltaBinaryPacked =>
      match ty {
        Int32 =>
          @types.ColBuf::Int32s(@encoders.decode_delta_int32(data, count).0)
        Int64 =>
          @types.ColBuf::Int64s(@encoders.decode_delta_int64(data, count).0)
        _ => raise @types.EncodingError::TypeMismatch(ty, DeltaBinaryPacked)
      }
    DeltaLength =>
      match ty {
        ByteArray =>
          @types.ColBuf::ByteArrays(
            @encoders.decode_delta_length_byte_array(data, count).0,
          )
        _ => raise @types.EncodingError::TypeMismatch(ty, DeltaLength)
      }
    DeltaByteArray =>
      match ty {
        ByteArray =>
          @types.ColBuf::ByteArrays(
            @encoders.decode_delta_byte_array(data, count).0,
          )
        _ => raise @types.EncodingError::TypeMismatch(ty, DeltaByteArray)
      }
    other => raise @types.EncodingError::Unsupported(other)
  }
}

///|
/// Build a dictionary encoding for a column. Returns `None` when the PLAIN
/// dictionary payload exceeds `max_dictionary_bytes`, meaning the caller should
/// fall back to PLAIN. Dictionary encoding has two output streams, so it does
/// not go through `encode_column`.
pub fn encode_dictionary(
  column : @types.ColBuf,
  max_dictionary_bytes~ : Int32 = @encoders.DEFAULT_DICTIONARY_BYTE_LIMIT,
) -> @types.DictionaryEncoding? raise @types.EncodingError {
  @encoders.encode_dictionary(column, max_dictionary_bytes~)
}

///|
/// Decode a dictionary page plus its index stream back into values.
pub fn decode_dictionary(
  dictionary : BytesView,
  indices : BytesView,
  ty : @types.PhysicalType,
  count : Int32,
  dictionary_size : Int32,
) -> @types.ColBuf raise @types.EncodingError {
  @encoders.decode_dictionary(dictionary, indices, ty, count, dictionary_size)
}
