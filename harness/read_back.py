#!/usr/bin/env python3
"""Judge a Parquet file with both judges: DuckDB and pyarrow (T0.2).

A file passes when both judges read the same values, and, when an expected
values file is supplied, when those values equal the source column. The
expected file is in PLAIN form with no level bytes (BOOLEAN bit-packed LSB
first), the same shape `make_refs.py` writes.

Usage:
    python3 harness/read_back.py file.parquet
    python3 harness/read_back.py file.parquet --values ref.values.bin --type INT32
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

PHYSICAL_TYPES = ("INT32", "INT64", "FLOAT", "DOUBLE", "BOOLEAN", "BYTE_ARRAY")


def decode_plain(raw: bytes, physical_type: str, count: int | None) -> list:
    """Decode expected values written in Parquet PLAIN form."""
    if physical_type == "INT32":
        values = list(struct.unpack(f"<{len(raw) // 4}i", raw))
    elif physical_type == "INT64":
        values = list(struct.unpack(f"<{len(raw) // 8}q", raw))
    elif physical_type == "FLOAT":
        values = list(struct.unpack(f"<{len(raw) // 4}f", raw))
    elif physical_type == "DOUBLE":
        values = list(struct.unpack(f"<{len(raw) // 8}d", raw))
    elif physical_type == "BOOLEAN":
        values = []
        for index in range(len(raw) * 8):
            if count is not None and index >= count:
                break
            values.append(bool(raw[index // 8] & (1 << (index % 8))))
    elif physical_type == "BYTE_ARRAY":
        values = []
        pos = 0
        while pos < len(raw):
            (length,) = struct.unpack_from("<I", raw, pos)
            pos += 4
            values.append(raw[pos : pos + length].decode("utf-8"))
            pos += length
    else:
        raise ValueError(f"unknown physical type {physical_type}")
    if count is not None and len(values) != count:
        raise ValueError(f"expected {count} values, decoded {len(values)}")
    return values


def judge(parquet: Path) -> tuple[list, list]:
    arrow_values = pq.read_table(parquet).column(0).to_pylist()
    duckdb_values = [
        row[0]
        for row in duckdb.connect()
        .execute(f"select * from read_parquet('{parquet.as_posix()}')")
        .fetchall()
    ]
    return arrow_values, duckdb_values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("parquet", type=Path)
    parser.add_argument("--values", type=Path, help="expected values in PLAIN form")
    parser.add_argument("--type", default="INT32", choices=PHYSICAL_TYPES)
    parser.add_argument("--count", type=int, help="rows expected")
    args = parser.parse_args(argv)

    try:
        arrow_values, duckdb_values = judge(args.parquet)
    except (OSError, ValueError, pa.ArrowException, duckdb.Error) as error:
        print(f"FAIL {args.parquet}: {type(error).__name__}: {error}", file=sys.stderr)
        return 2

    failures = 0
    if arrow_values != duckdb_values:
        failures += 1
        offset = next(
            (
                index
                for index, (a, b) in enumerate(zip(arrow_values, duckdb_values))
                if a != b
            ),
            min(len(arrow_values), len(duckdb_values)),
        )
        print(f"FAIL judges disagree at row {offset}")
    else:
        print(f"PASS judges agree on {len(arrow_values)} rows")

    if args.values is not None:
        expected = decode_plain(args.values.read_bytes(), args.type, args.count)
        if expected != arrow_values:
            failures += 1
            offset = next(
                (
                    index
                    for index, (want, got) in enumerate(zip(expected, arrow_values))
                    if want != got
                ),
                min(len(expected), len(arrow_values)),
            )
            print(
                f"FAIL values differ at row {offset} "
                f"(expected {len(expected)} rows, file has {len(arrow_values)})"
            )
        else:
            print(f"PASS values match {args.values.name}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
