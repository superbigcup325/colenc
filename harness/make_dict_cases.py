#!/usr/bin/env python3
"""Build dictionary byte-diff cases from the reference fixtures (P2).

Each case writes:

- `<case>.input.bin`: the value sequence. int32 values are little-endian u64
  (sign-extended); strings are a u32le length followed by the bytes.
- `<case>.dict.bin`: the reference dictionary page payload (PLAIN values)
- `<case>.indices.bin`: the reference data page payload (bit-width byte plus
  the hybrid index stream)

`dict_probe` builds the dictionary with the library and `check_dict.py` diffs
both payloads against these blobs.

Usage:
    python3 harness/make_dict_cases.py
    python3 harness/make_dict_cases.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

from make_refs import DICT_INT32, DICT_VALUES
from make_rle_cases import data_page, dictionary_entries, page_blobs

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUT = FIXTURES / "dict"


def dictionary_blob(data: bytes, pages: list) -> bytes:
    found = [page for page in pages if page.page_type == "DICTIONARY_PAGE"]
    if len(found) != 1:
        raise SystemExit(f"expected one dictionary page, found {len(found)}")
    page = found[0]
    return data[page.values_offset : page.values_offset + page.values_len]


def int32_case(name: str, values: list[int]) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    payload = data_page(data, pages)
    blob = dictionary_blob(data, pages)
    entries = list(struct.unpack(f"<{len(blob) // 4}i", blob))
    return {
        "name": name,
        "type": "int32",
        "values": values,
        "input": b"".join(
            struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF) for value in values
        ),
        "dictionary": b"".join(struct.pack("<i", entry) for entry in entries),
        "indices": payload,
        "dictionary_size": len(entries),
        "width": payload[0],
        "plain_bytes": 4 * len(values),
        "source": f"{name}.parquet",
    }


def string_case(name: str, values: list[str]) -> dict:
    data, pages = page_blobs(FIXTURES / f"{name}.parquet")
    payload = data_page(data, pages)
    entries = dictionary_entries(data, pages)
    encoded = [value.encode() for value in values]
    return {
        "name": name,
        "type": "string",
        "values": encoded,
        "input": b"".join(struct.pack("<I", len(value)) + value for value in encoded),
        "dictionary": b"".join(
            struct.pack("<I", len(entry)) + entry for entry in entries
        ),
        "indices": payload,
        "dictionary_size": len(entries),
        "width": payload[0],
        "plain_bytes": sum(4 + len(value) for value in encoded),
        "source": f"{name}.parquet",
    }


def build() -> list[dict]:
    return [
        int32_case("dict_int32", DICT_INT32),
        string_case("dict_string", DICT_VALUES),
    ]


def write_cases(cases: list[dict]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for case in cases:
        files = {
            "input": OUT / f"{case['name']}.input.bin",
            "dictionary": OUT / f"{case['name']}.dict.bin",
            "indices": OUT / f"{case['name']}.indices.bin",
        }
        payloads = {
            "input": case["input"],
            "dictionary": case["dictionary"],
            "indices": case["indices"],
        }
        entry = {
            "name": case["name"],
            "source": case["source"],
            "type": case["type"],
            "count": len(case["values"]),
            "dictionary_size": case["dictionary_size"],
            "width": case["width"],
            "plain_bytes": case["plain_bytes"],
        }
        for key, path in files.items():
            path.write_bytes(payloads[key])
            entry[f"{key}_file"] = path.name
            entry[f"{key}_sha256"] = hashlib.sha256(payloads[key]).hexdigest()
        manifest.append(entry)
    (OUT / "manifest.json").write_text(
        json.dumps({"cases": manifest}, indent=2, sort_keys=True) + "\n"
    )
    print(f"wrote {len(cases)} dictionary cases to {OUT}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    cases = build()
    if args.check:
        from diff_bytes import first_difference

        failures = 0
        for case in cases:
            for key, payload in (
                ("input", case["input"]),
                ("dict", case["dictionary"]),
                ("indices", case["indices"]),
            ):
                path = OUT / f"{case['name']}.{key}.bin"
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
