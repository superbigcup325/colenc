#!/usr/bin/env python3
"""Build delta byte-diff cases from the reference fixtures (P3).

Each case writes:

- `<case>.input.bin`: int32/int64 as little-endian u64 (sign-extended);
  strings as a u32le length plus bytes, once per value
- `<case>.ref.bin`: the reference stream carved from the fixture's data page

`delta_probe` encodes the input through the library and `check_delta.py`
byte-diffs the result, printing the ratio against PLAIN.

Usage:
    python3 harness/make_delta_cases.py
    python3 harness/make_delta_cases.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

from make_refs import (
    DELTA_BYTE_ARRAY_STRINGS,
    DELTA_INT32,
    DELTA_INT64,
    DELTA_LENGTH_STRINGS,
)
from make_rle_cases import data_page, page_blobs

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUT = FIXTURES / "delta"


def int_case(name: str, values: list[int], width: int, kind: str) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    return {
        "name": name,
        "type": kind,
        "encoding": "delta",
        "count": len(values),
        "input": b"".join(
            struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF) for value in values
        ),
        "reference": data_page(data, pages),
        "plain_bytes": width * len(values),
        "source": f"{name}.parquet",
    }


def string_case(name: str, values: list[str], encoding: str) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    encoded = [value.encode() for value in values]
    return {
        "name": name,
        "type": "string",
        "encoding": encoding,
        "count": len(values),
        "input": b"".join(struct.pack("<I", len(value)) + value for value in encoded),
        "reference": data_page(data, pages),
        "plain_bytes": sum(4 + len(value) for value in encoded),
        "source": f"{name}.parquet",
    }


def build() -> list[dict]:
    return [
        int_case("delta_int32", DELTA_INT32, 4, "int32"),
        int_case("delta_int64", DELTA_INT64, 8, "int64"),
        string_case("delta_length_string", DELTA_LENGTH_STRINGS, "delta-length"),
        string_case(
            "delta_byte_array_string", DELTA_BYTE_ARRAY_STRINGS, "delta-byte-array"
        ),
    ]


def write_cases(cases: list[dict]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for case in cases:
        input_path = OUT / f"{case['name']}.input.bin"
        ref_path = OUT / f"{case['name']}.ref.bin"
        input_path.write_bytes(case["input"])
        ref_path.write_bytes(case["reference"])
        manifest.append(
            {
                "name": case["name"],
                "source": case["source"],
                "type": case["type"],
                "encoding": case["encoding"],
                "count": case["count"],
                "plain_bytes": case["plain_bytes"],
                "input_file": input_path.name,
                "reference_file": ref_path.name,
                "input_sha256": hashlib.sha256(case["input"]).hexdigest(),
                "reference_sha256": hashlib.sha256(case["reference"]).hexdigest(),
            }
        )
    (OUT / "manifest.json").write_text(
        json.dumps({"cases": manifest}, indent=2, sort_keys=True) + "\n"
    )
    print(f"wrote {len(cases)} delta cases to {OUT}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    cases = build()
    if args.check:
        from diff_bytes import first_difference

        failures = 0
        for case in cases:
            for suffix, payload in (
                ("input", case["input"]),
                ("ref", case["reference"]),
            ):
                path = OUT / f"{case['name']}.{suffix}.bin"
                if not path.exists():
                    failures += 1
                    print(f"  FAIL  {path.name}: missing")
                    continue
                on_disk = path.read_bytes()
                if on_disk == payload:
                    print(f"  PASS  {path.name}")
                else:
                    failures += 1
                    offset = first_difference(payload, on_disk)
                    print(f"  FAIL  {path.name}: first difference at byte {offset}")
        return 1 if failures else 0
    write_cases(cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
