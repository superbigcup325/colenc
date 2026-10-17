"""Minimal Parquet page extraction for the acceptance rig.

Byte-diffing compares the bytes an encoder produced, and those bytes sit behind
a Thrift-compact page header. pyarrow exposes page offsets but not page
headers, so this module carries a small Thrift compact protocol reader that
understands exactly what `PageHeader` needs.

Scope notes:

- Only page structures are parsed; footer and schema descriptors come from
  pyarrow's file metadata
- Bytes are returned verbatim; nothing here decompresses or decodes values
- Stdlib only, so it can be copied into CI without the rest of the rig
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

# Thrift compact protocol type nibbles (the subset page headers use).
STOP = 0x00
BOOL_TRUE = 0x01
BOOL_FALSE = 0x02
BYTE = 0x03
I16 = 0x04
I32 = 0x05
I64 = 0x06
DOUBLE = 0x07
BINARY = 0x08
LIST = 0x09
SET = 0x0A
MAP = 0x0B
STRUCT = 0x0C

PAGE_TYPE_NAMES = {
    0: "DATA_PAGE",
    1: "INDEX_PAGE",
    2: "DICTIONARY_PAGE",
    3: "DATA_PAGE_V2",
}

ENCODING_NAMES = {
    0: "PLAIN",
    1: "GROUP_VAR_INT",
    2: "PLAIN_DICTIONARY",
    3: "RLE",
    4: "BIT_PACKED",
    5: "DELTA_BINARY_PACKED",
    6: "DELTA_LENGTH_BYTE_ARRAY",
    7: "DELTA_BYTE_ARRAY",
    8: "RLE_DICTIONARY",
    9: "BYTE_STREAM_SPLIT",
}

# PageHeader field ids, from parquet.thrift.
PAGE_HEADER_TYPE = 1
PAGE_HEADER_UNCOMPRESSED_SIZE = 2
PAGE_HEADER_COMPRESSED_SIZE = 3
PAGE_HEADER_DATA_PAGE_HEADER = 5
PAGE_HEADER_DICTIONARY_PAGE_HEADER = 7
PAGE_HEADER_DATA_PAGE_HEADER_V2 = 8

# DataPageHeader field ids.
DATA_PAGE_NUM_VALUES = 1
DATA_PAGE_ENCODING = 2

# DataPageHeaderV2 field ids.
DATA_PAGE_V2_NUM_VALUES = 1
DATA_PAGE_V2_NUM_NULLS = 2
DATA_PAGE_V2_ENCODING = 4
DATA_PAGE_V2_DEF_LEVELS_BYTE_LENGTH = 5
DATA_PAGE_V2_REP_LEVELS_BYTE_LENGTH = 6

# DictionaryPageHeader field ids.
DICT_PAGE_NUM_VALUES = 1
DICT_PAGE_ENCODING = 2


class ParquetPageError(ValueError):
    """The bytes do not form the Parquet page chain the metadata promised."""


class CompactReader:
    """Reader for the Thrift compact protocol subset used by PageHeader."""

    def __init__(self, data: bytes, pos: int = 0) -> None:
        self.data = data
        self.pos = pos

    def byte(self) -> int:
        if self.pos >= len(self.data):
            raise ParquetPageError(f"unexpected end of data at byte {self.pos}")
        value = self.data[self.pos]
        self.pos += 1
        return value

    def take(self, count: int) -> bytes:
        end = self.pos + count
        if end > len(self.data):
            raise ParquetPageError(
                f"want {count} bytes at byte {self.pos}, "
                f"only {len(self.data) - self.pos} left"
            )
        chunk = self.data[self.pos : end]
        self.pos = end
        return chunk

    def varint(self) -> int:
        """Unsigned LEB128."""
        result = 0
        shift = 0
        while True:
            b = self.byte()
            result |= (b & 0x7F) << shift
            if not b & 0x80:
                return result
            shift += 7
            if shift > 63:
                raise ParquetPageError(
                    f"varint longer than 10 bytes at byte {self.pos}"
                )

    def zigzag(self) -> int:
        n = self.varint()
        return (n >> 1) ^ -(n & 1)

    def value(self, type_nibble: int):
        if type_nibble == BOOL_TRUE:
            return True
        if type_nibble == BOOL_FALSE:
            return False
        if type_nibble == BYTE:
            return struct.unpack("<b", self.take(1))[0]
        if type_nibble in (I16, I32, I64):
            return self.zigzag()
        if type_nibble == DOUBLE:
            return struct.unpack("<d", self.take(8))[0]
        if type_nibble == BINARY:
            return self.take(self.varint())
        if type_nibble in (LIST, SET):
            header = self.byte()
            size = header >> 4
            element_type = header & 0x0F
            if size == 15:
                size = self.varint()
            return [self.value(element_type) for _ in range(size)]
        if type_nibble == MAP:
            size = self.varint()
            if size == 0:
                return []
            kinds = self.byte()
            key_type = kinds >> 4
            value_type = kinds & 0x0F
            return [(self.value(key_type), self.value(value_type)) for _ in range(size)]
        if type_nibble == STRUCT:
            return self.struct()
        raise ParquetPageError(
            f"unknown thrift compact type 0x{type_nibble:02x} at byte {self.pos}"
        )

    def struct(self) -> dict[int, object]:
        """Read a struct into {field id: value}; nested structs become dicts."""
        fields: dict[int, object] = {}
        last_field_id = 0
        while True:
            header = self.byte()
            if header == STOP:
                return fields
            type_nibble = header & 0x0F
            delta = header >> 4
            if delta:
                field_id = last_field_id + delta
            else:
                field_id = self.zigzag()
            if field_id <= 0:
                raise ParquetPageError(
                    f"invalid field id {field_id} at byte {self.pos - 1}"
                )
            fields[field_id] = self.value(type_nibble)
            last_field_id = field_id


def read_page_header(data: bytes, offset: int) -> tuple[dict[int, object], int]:
    """Parse the PageHeader at `offset`; return (fields, header length)."""
    reader = CompactReader(data, offset)
    header = reader.struct()
    for required in (
        PAGE_HEADER_TYPE,
        PAGE_HEADER_UNCOMPRESSED_SIZE,
        PAGE_HEADER_COMPRESSED_SIZE,
    ):
        if required not in header:
            raise ParquetPageError(
                f"page header at byte {offset} misses required field {required}"
            )
    return header, reader.pos - offset


@dataclass
class Page:
    """One page as it sits in the file."""

    row_group: int
    column_index: int
    column_path: str
    page_index: int
    page_type: str
    header_offset: int
    header_len: int
    body_offset: int
    body_len: int
    uncompressed_page_size: int
    num_values: int | None
    num_nulls: int | None
    encoding: str | None
    # Bytes in front of the value stream: repetition levels, then definition
    # levels. Both are zero-length for required flat columns.
    rep_levels_len: int
    def_levels_len: int

    @property
    def levels_len(self) -> int:
        return self.rep_levels_len + self.def_levels_len

    @property
    def values_offset(self) -> int:
        return self.body_offset + self.levels_len

    @property
    def values_len(self) -> int:
        return self.body_len - self.levels_len

    def to_dict(self) -> dict:
        return {
            "row_group": self.row_group,
            "column_index": self.column_index,
            "column_path": self.column_path,
            "page_index": self.page_index,
            "page_type": self.page_type,
            "header_offset": self.header_offset,
            "header_len": self.header_len,
            "body_offset": self.body_offset,
            "body_len": self.body_len,
            "uncompressed_page_size": self.uncompressed_page_size,
            "num_values": self.num_values,
            "num_nulls": self.num_nulls,
            "encoding": self.encoding,
            "rep_levels_len": self.rep_levels_len,
            "def_levels_len": self.def_levels_len,
            "values_offset": self.values_offset,
            "values_len": self.values_len,
        }


def _v1_levels_len(
    data: bytes, body_offset: int, max_rep_level: int, max_def_level: int
) -> tuple[int, int]:
    """Split the V1 body prefix into (rep levels len, def levels len).

    V1 stores each level section as a 4-byte little-endian length followed by
    that many bytes; a section is absent when its max level is zero.
    """
    pos = body_offset
    rep_len = 0
    def_len = 0
    if max_rep_level > 0:
        (payload,) = struct.unpack_from("<I", data, pos)
        rep_len = 4 + payload
        pos += rep_len
    if max_def_level > 0:
        (payload,) = struct.unpack_from("<I", data, pos)
        def_len = 4 + payload
    return rep_len, def_len


def iter_pages(data: bytes, parquet_file) -> list[Page]:
    """Walk every column chunk and return its pages, in file order.

    The walk is self-checking: page headers and bodies must tile each column
    chunk exactly (`total_compressed_size`), otherwise the offsets are not
    trusted and `ParquetPageError` is raised. A Thrift misparse desynchronizes
    the chain immediately, so exact tiling is the guard.
    """
    metadata = parquet_file.metadata
    pages: list[Page] = []
    for row_group in range(metadata.num_row_groups):
        group = metadata.row_group(row_group)
        for column_index in range(group.num_columns):
            column = group.column(column_index)
            start = column.data_page_offset
            if column.has_dictionary_page and column.dictionary_page_offset is not None:
                start = min(start, column.dictionary_page_offset)
            if start is None:
                raise ParquetPageError(
                    f"row group {row_group} column {column_index} has no page offset"
                )
            end = start + column.total_compressed_size

            schema_column = metadata.schema.column(column_index)
            max_rep_level = schema_column.max_repetition_level
            max_def_level = schema_column.max_definition_level
            column_path = column.path_in_schema

            pos = start
            page_index = 0
            while pos < end:
                header, header_len = read_page_header(data, pos)
                page_type_id = header[PAGE_HEADER_TYPE]
                page_type = PAGE_TYPE_NAMES.get(page_type_id, f"UNKNOWN_{page_type_id}")
                body_offset = pos + header_len
                body_len = header[PAGE_HEADER_COMPRESSED_SIZE]
                if body_offset + body_len > len(data):
                    raise ParquetPageError(
                        f"{column_path} page {page_index}: body ends at "
                        f"{body_offset + body_len}, file has {len(data)} bytes"
                    )

                num_values = None
                num_nulls = None
                encoding = None
                rep_len = 0
                def_len = 0

                if page_type == "DATA_PAGE":
                    page_header = header.get(PAGE_HEADER_DATA_PAGE_HEADER)
                    if page_header is None:
                        raise ParquetPageError(
                            f"{column_path} page {page_index}: DATA_PAGE without header"
                        )
                    num_values = page_header.get(DATA_PAGE_NUM_VALUES)
                    encoding = ENCODING_NAMES.get(
                        page_header.get(DATA_PAGE_ENCODING), "UNKNOWN"
                    )
                    rep_len, def_len = _v1_levels_len(
                        data, body_offset, max_rep_level, max_def_level
                    )
                elif page_type == "DATA_PAGE_V2":
                    page_header = header.get(PAGE_HEADER_DATA_PAGE_HEADER_V2)
                    if page_header is None:
                        raise ParquetPageError(
                            f"{column_path} page {page_index}: DATA_PAGE_V2 without header"
                        )
                    num_values = page_header.get(DATA_PAGE_V2_NUM_VALUES)
                    num_nulls = page_header.get(DATA_PAGE_V2_NUM_NULLS)
                    encoding = ENCODING_NAMES.get(
                        page_header.get(DATA_PAGE_V2_ENCODING), "UNKNOWN"
                    )
                    rep_len = page_header.get(DATA_PAGE_V2_REP_LEVELS_BYTE_LENGTH, 0)
                    def_len = page_header.get(DATA_PAGE_V2_DEF_LEVELS_BYTE_LENGTH, 0)
                elif page_type == "DICTIONARY_PAGE":
                    page_header = header.get(PAGE_HEADER_DICTIONARY_PAGE_HEADER)
                    if page_header is None:
                        raise ParquetPageError(
                            f"{column_path} page {page_index}: DICTIONARY_PAGE "
                            "without header"
                        )
                    num_values = page_header.get(DICT_PAGE_NUM_VALUES)
                    encoding = ENCODING_NAMES.get(
                        page_header.get(DICT_PAGE_ENCODING), "UNKNOWN"
                    )

                if rep_len + def_len > body_len:
                    raise ParquetPageError(
                        f"{column_path} page {page_index}: levels "
                        f"({rep_len + def_len} bytes) exceed the body ({body_len})"
                    )

                pages.append(
                    Page(
                        row_group=row_group,
                        column_index=column_index,
                        column_path=column_path,
                        page_index=page_index,
                        page_type=page_type,
                        header_offset=pos,
                        header_len=header_len,
                        body_offset=body_offset,
                        body_len=body_len,
                        uncompressed_page_size=header[PAGE_HEADER_UNCOMPRESSED_SIZE],
                        num_values=num_values,
                        num_nulls=num_nulls,
                        encoding=encoding,
                        rep_levels_len=rep_len,
                        def_levels_len=def_len,
                    )
                )
                pos = body_offset + body_len
                page_index += 1

            if pos != end:
                raise ParquetPageError(
                    f"{column_path}: pages end at byte {pos}, chunk ends at {end}"
                )
    return pages
