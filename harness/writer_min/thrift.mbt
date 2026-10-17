/// Thrift compact protocol, the subset Parquet metadata needs.
///
/// The writer only emits the plain subset: i32, i64, binary, list and struct
/// fields. Booleans never appear, so the two boolean type nibbles are declared
/// but unused, and no map or set is ever written.

///|
const THRIFT_STOP : Int32 = 0

///|
const THRIFT_I32 : Int32 = 5

///|
const THRIFT_I64 : Int32 = 6

///|
const THRIFT_BINARY : Int32 = 8

///|
const THRIFT_LIST : Int32 = 9

///|
const THRIFT_STRUCT : Int32 = 12

///|
/// Write an unsigned LEB128 value, seven bits per byte, low bits first.
fn put_uvarint(buf : @buffer.Buffer, value : UInt64) -> Unit {
  let mut rest = value
  while rest >= 0x80UL {
    buf.write_byte(((rest.to_int() & 0x7F) | 0x80).to_byte())
    rest = rest >> 7
  }
  buf.write_byte(rest.to_int().to_byte())
}

///|
/// Zigzag-map a signed value onto the unsigned range, then write it as LEB128.
fn put_zigzag(buf : @buffer.Buffer, value : Int64) -> Unit {
  let zigzag = (value << 1) ^ (value >> 63)
  put_uvarint(buf, zigzag.reinterpret_as_uint64())
}

///|
fn put_i32(buf : @buffer.Buffer, value : Int32) -> Unit {
  put_zigzag(buf, value.to_int64())
}

///|
/// Write a field header and return the field id for the next delta.
///
/// A delta of 1..15 rides in the high nibble. A zero or large delta writes a
/// zero nibble and the absolute field id as a zigzag varint.
fn put_field_header(
  buf : @buffer.Buffer,
  last_id : Int32,
  field_id : Int32,
  type_id : Int32,
) -> Int32 {
  let delta = field_id - last_id
  if delta > 0 && delta <= 15 {
    buf.write_byte(((delta << 4) | type_id).to_byte())
  } else {
    buf.write_byte(type_id.to_byte())
    put_i32(buf, field_id)
  }
  field_id
}

///|
/// List header: size in the high nibble when it fits, otherwise 0xF plus a
/// varint size, with the element type in the low nibble.
fn put_list_header(
  buf : @buffer.Buffer,
  size : Int32,
  element_type : Int32,
) -> Unit {
  if size < 15 {
    buf.write_byte(((size << 4) | element_type).to_byte())
  } else {
    buf.write_byte((0xF0 | element_type).to_byte())
    put_uvarint(buf, size.to_uint64())
  }
}

///|
/// Binary field payload: varint length, then the UTF-8 bytes.
fn put_binary(buf : @buffer.Buffer, value : String) -> Unit {
  let raw = @utf8.encode(value)
  put_uvarint(buf, raw.length().to_uint64())
  buf.write_bytes(raw)
}

///|
fn put_stop(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(THRIFT_STOP.to_byte())
}

///|
fn field_i32(
  buf : @buffer.Buffer,
  last_id : Int32,
  field_id : Int32,
  value : Int32,
) -> Int32 {
  let next = put_field_header(buf, last_id, field_id, THRIFT_I32)
  put_i32(buf, value)
  next
}

///|
fn field_i64(
  buf : @buffer.Buffer,
  last_id : Int32,
  field_id : Int32,
  value : Int64,
) -> Int32 {
  let next = put_field_header(buf, last_id, field_id, THRIFT_I64)
  put_zigzag(buf, value)
  next
}

///|
fn field_binary(
  buf : @buffer.Buffer,
  last_id : Int32,
  field_id : Int32,
  value : String,
) -> Int32 {
  let next = put_field_header(buf, last_id, field_id, THRIFT_BINARY)
  put_binary(buf, value)
  next
}
