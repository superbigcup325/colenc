/// The minimum Parquet container: one required flat column, uncompressed.
/// Plain and RLE-boolean pages are the two shapes built here.
///
/// Layout produced:
///
///   "PAR1"
///   <page header><page body>
///   <FileMetaData thrift-compact>
///   <footer length, u32 little endian>
///   "PAR1"
///
/// Only what a reader needs is written: no statistics, no column index, no
/// key/value metadata. The file is a judge target, not a general writer.

///|
const PAGE_TYPE_DATA_PAGE : Int32 = 0

///|
const ENCODING_PLAIN : Int32 = 0

///|
const ENCODING_RLE : Int32 = 3

///|
const TYPE_BOOLEAN : Int32 = 0

///|
const TYPE_INT32 : Int32 = 1

///|
const REPETITION_REQUIRED : Int32 = 0

///|
const CODEC_UNCOMPRESSED : Int32 = 0

///|
fn write_magic(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'P')
  buf.write_byte(b'A')
  buf.write_byte(b'R')
  buf.write_byte(b'1')
}

///|
/// PageHeader.data_page_header. Level encodings are declared even though a
/// required column carries no level bytes; both are required fields.
fn data_page_header(num_values : Int32, encoding_id : Int32) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_i32(buf, last, 1, num_values)
  last = field_i32(buf, last, 2, encoding_id)
  last = field_i32(buf, last, 3, ENCODING_RLE)
  last = field_i32(buf, last, 4, ENCODING_RLE)
  put_stop(buf)
  buf.to_bytes()
}

///|
/// PageHeader for a single V1 data page whose body is exactly the value bytes.
fn page_header(
  body_len : Int32,
  num_values : Int32,
  encoding_id : Int32,
) -> Bytes {
  let data_header = data_page_header(num_values, encoding_id)
  let buf = Buffer()
  let mut last = 0
  last = field_i32(buf, last, 1, PAGE_TYPE_DATA_PAGE)
  last = field_i32(buf, last, 2, body_len)
  last = field_i32(buf, last, 3, body_len)
  last = put_field_header(buf, last, 5, THRIFT_STRUCT)
  buf.write_bytes(data_header)
  put_stop(buf)
  buf.to_bytes()
}

///|
/// Root of the schema tree: a group with one child.
fn schema_element_root() -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_binary(buf, last, 4, "schema")
  last = field_i32(buf, last, 5, 1)
  put_stop(buf)
  buf.to_bytes()
}

///|
fn schema_element(name : String, type_id : Int32) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_i32(buf, last, 1, type_id)
  last = field_i32(buf, last, 3, REPETITION_REQUIRED)
  last = field_binary(buf, last, 4, name)
  put_stop(buf)
  buf.to_bytes()
}

///|
/// ColumnMetaData. Sizes include the page header, as the spec defines them.
fn column_meta_data(
  path : String,
  type_id : Int32,
  encodings : Array[Int32],
  num_values : Int32,
  total_size : Int32,
  data_page_offset : Int32,
) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_i32(buf, last, 1, type_id)
  last = put_field_header(buf, last, 2, THRIFT_LIST)
  put_list_header(buf, encodings.length(), THRIFT_I32)
  for encoding in encodings {
    put_i32(buf, encoding)
  }
  last = put_field_header(buf, last, 3, THRIFT_LIST)
  put_list_header(buf, 1, THRIFT_BINARY)
  put_binary(buf, path)
  last = field_i32(buf, last, 4, CODEC_UNCOMPRESSED)
  last = field_i64(buf, last, 5, num_values.to_int64())
  last = field_i64(buf, last, 6, total_size.to_int64())
  last = field_i64(buf, last, 7, total_size.to_int64())
  last = field_i64(buf, last, 9, data_page_offset.to_int64())
  put_stop(buf)
  buf.to_bytes()
}

///|
fn column_chunk(file_offset : Int32, meta_data : Bytes) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_i64(buf, last, 2, file_offset.to_int64())
  last = put_field_header(buf, last, 3, THRIFT_STRUCT)
  buf.write_bytes(meta_data)
  put_stop(buf)
  buf.to_bytes()
}

///|
fn row_group(
  columns : Array[Bytes],
  total_size : Int32,
  num_rows : Int32,
) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = put_field_header(buf, last, 1, THRIFT_LIST)
  put_list_header(buf, columns.length(), THRIFT_STRUCT)
  for column in columns {
    buf.write_bytes(column)
  }
  last = field_i64(buf, last, 2, total_size.to_int64())
  last = field_i64(buf, last, 3, num_rows.to_int64())
  put_stop(buf)
  buf.to_bytes()
}

///|
fn file_meta_data(
  schema : Array[Bytes],
  num_rows : Int32,
  row_groups : Array[Bytes],
) -> Bytes {
  let buf = Buffer()
  let mut last = 0
  last = field_i32(buf, last, 1, 1)
  last = put_field_header(buf, last, 2, THRIFT_LIST)
  put_list_header(buf, schema.length(), THRIFT_STRUCT)
  for element in schema {
    buf.write_bytes(element)
  }
  last = field_i64(buf, last, 3, num_rows.to_int64())
  last = put_field_header(buf, last, 4, THRIFT_LIST)
  put_list_header(buf, row_groups.length(), THRIFT_STRUCT)
  for group in row_groups {
    buf.write_bytes(group)
  }
  last = field_binary(buf, last, 6, "colpack writer_min")
  put_stop(buf)
  buf.to_bytes()
}

///|
/// Assemble a one-column Parquet file around an already-encoded page body.
pub fn build_page(
  column : String,
  type_id : Int32,
  encoding_id : Int32,
  encodings : Array[Int32],
  body_bytes : Bytes,
  count : Int32,
) -> Bytes {
  let header = page_header(body_bytes.length(), count, encoding_id)
  let data_page_offset = 4
  let total_size = header.length() + body_bytes.length()

  let file = Buffer()
  write_magic(file)
  file.write_bytes(header)
  file.write_bytes(body_bytes)

  let schema = [schema_element_root(), schema_element(column, type_id)]
  let meta = column_meta_data(
    column, type_id, encodings, count, total_size, data_page_offset,
  )
  let chunk = column_chunk(data_page_offset, meta)
  let groups = [row_group([chunk], total_size, count)]
  let footer = file_meta_data(schema, count, groups)

  file.write_bytes(footer)
  file.write_int_le(footer.length())
  write_magic(file)
  file.to_bytes()
}

///|
/// Build a complete Parquet file holding one required int32 column in PLAIN.
pub fn build_int32_plain(column : String, values : Array[Int32]) -> Bytes {
  let body = Buffer()
  for value in values {
    body.write_int_le(value)
  }
  build_plain_page(column, body.to_bytes(), values.length())
}

///|
/// Wrap an already-encoded PLAIN int32 body.
pub fn build_plain_page(
  column : String,
  body_bytes : Bytes,
  count : Int32,
) -> Bytes {
  build_page(
    column,
    TYPE_INT32,
    ENCODING_PLAIN,
    [ENCODING_PLAIN],
    body_bytes,
    count,
  )
}

///|
/// Wrap an already-encoded RLE boolean body, which starts with the 4-byte
/// length prefix the spec requires for RLE-encoded boolean values.
pub fn build_bool_rle_page(
  column : String,
  body_bytes : Bytes,
  count : Int32,
) -> Bytes {
  build_page(
    column,
    TYPE_BOOLEAN,
    ENCODING_RLE,
    [ENCODING_RLE],
    body_bytes,
    count,
  )
}
