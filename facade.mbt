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
    other => raise @types.EncodingError::Unsupported(other)
  }
}
