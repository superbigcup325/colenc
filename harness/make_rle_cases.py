#!/usr/bin/env python3
"""Build RLE byte-diff cases from the reference fixtures (T1.3).

For every case this writes two blobs:

- `<case>.input.bin`: the value sequence as little-endian u64, one per value
- `<case>.ref.bin`: the reference hybrid stream extracted from the fixture

The MoonBit probe (`rle_probe/`) encodes the input and `check_rle.py` diffs the
result against the reference byte for byte.

Boolean pages carry the stream behind a 4-byte length prefix; the case strips
it. Dictionary pages carry a leading bit-width byte followed by the stream;
the case reports the width and strips the byte, so widths above 1 get the same
byte-level check as width 1.

Usage:
    python3 harness/make_rle_cases.py
    python3 harness/make_rle_cases.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

import pyarrow.parquet as pq
from make_refs import DICT_VALUES, RLE_BOOL, RLE_RUNS
from parquet_pages import iter_pages

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUT = FIXTURES / "rle"


def page_blobs(path: Path) -> tuple[bytes, list]:
    data = path.read_bytes()
    pages = iter_pages(data, pq.ParquetFile(path))
    return data, pages


def data_page(data: bytes, pages: list):
    found = [page for page in pages if page.page_type == "DATA_PAGE"]
    if len(found) != 1:
        raise SystemExit(f"expected one data page, found {len(found)}")
    page = found[0]
    return data[page.values_offset : page.values_offset + page.values_len]


def dictionary_entries(data: bytes, pages: list) -> list[bytes]:
    found = [page for page in pages if page.page_type == "DICTIONARY_PAGE"]
    if len(found) != 1:
        raise SystemExit(f"expected one dictionary page, found {len(found)}")
    page = found[0]
    blob = data[page.values_offset : page.values_offset + page.values_len]
    out = []
    pos = 0
    while pos < len(blob):
        (length,) = struct.unpack_from("<I", blob, pos)
        pos += 4
        out.append(blob[pos : pos + length])
        pos += length
    return out


def bool_case(name: str, values: list[bool]) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    payload = data_page(data, pages)
    (length,) = struct.unpack_from("<I", payload, 0)
    if len(payload) != 4 + length:
        raise SystemExit(
            f"{name}: payload is {len(payload)} bytes, prefix says {4 + length}"
        )
    stream = payload[4:]
    return {
        "name": name,
        "width": 1,
        "values": [1 if value else 0 for value in values],
        "reference": stream,
        "source": f"{name}.parquet",
    }


def dictionary_case(name: str, values: list[str]) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    entries = dictionary_entries(data, pages)
    payload = data_page(data, pages)
    if not payload:
        raise SystemExit(f"{name}: empty dictionary data page")
    width = payload[0]
    index = {entry: position for position, entry in enumerate(entries)}
    missing = [value for value in values if value.encode() not in index]
    if missing:
        raise SystemExit(f"{name}: dictionary misses {missing[0]!r}")
    return {
        "name": name,
        "width": width,
        "values": [index[value.encode()] for value in values],
        "reference": payload[1:],
        "source": f"{name}.parquet",
    }


def build() -> list[dict]:
    return [
        bool_case("rle_bool", RLE_BOOL),
        bool_case("rle_bool_runs", RLE_RUNS),
        dictionary_case("dict_string", DICT_VALUES),
    ]


def input_bytes(values: list[int]) -> bytes:
    return b"".join(struct.pack("<Q", value) for value in values)


def write_cases(cases: list[dict]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for case in cases:
        input_path = OUT / f"{case['name']}.input.bin"
        ref_path = OUT / f"{case['name']}.ref.bin"
        raw = input_bytes(case["values"])
        input_path.write_bytes(raw)
        ref_path.write_bytes(case["reference"])
        manifest.append(
            {
                "name": case["name"],
                "source": case["source"],
                "width": case["width"],
                "count": len(case["values"]),
                "input": input_path.name,
                "reference": ref_path.name,
                "input_sha256": hashlib.sha256(raw).hexdigest(),
                "reference_sha256": hashlib.sha256(case["reference"]).hexdigest(),
            }
        )
    (OUT / "manifest.json").write_text(
        json.dumps({"cases": manifest}, indent=2, sort_keys=True) + "\n"
    )
    print(f"wrote {len(cases)} RLE cases to {OUT}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    cases = build()
    if args.check:
        from diff_bytes import first_difference

        failures = 0
        for case in cases:
            ref_path = OUT / f"{case['name']}.ref.bin"
            input_path = OUT / f"{case['name']}.input.bin"
            if not ref_path.exists() or not input_path.exists():
                failures += 1
                print(f"  FAIL  {case['name']}: case files missing")
                continue
            for path, payload in (
                (input_path, input_bytes(case["values"])),
                (ref_path, case["reference"]),
            ):
                if path.read_bytes() == payload:
                    print(f"  PASS  {path.name}")
                else:
                    failures += 1
                    offset = first_difference(payload, path.read_bytes())
                    print(f"  FAIL  {path.name}: first difference at byte {offset}")
        return 1 if failures else 0
    write_cases(cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
