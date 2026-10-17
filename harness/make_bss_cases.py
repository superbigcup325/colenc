#!/usr/bin/env python3
"""Build BYTE_STREAM_SPLIT byte-diff cases from the reference fixtures (P4).

Input is the values themselves (f32 or f64 little-endian); the reference is the
fixture's data page payload.

Usage:
    python3 harness/make_bss_cases.py
    python3 harness/make_bss_cases.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

from make_refs import BSS_FLOAT32
from make_rle_cases import data_page, page_blobs

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUT = FIXTURES / "bss"

BSS_DOUBLE = [i * 0.1 - 3.25 for i in range(1000)]


def build() -> list[dict]:
    float_data, float_pages = page_blobs(FIXTURES / "bss_float32.parquet")
    double_data, double_pages = page_blobs(FIXTURES / "bss_double.parquet")
    return [
        {
            "name": "bss_float32",
            "type": "float",
            "count": len(BSS_FLOAT32),
            "input": b"".join(struct.pack("<f", value) for value in BSS_FLOAT32),
            "reference": data_page(float_data, float_pages),
            "plain_bytes": 4 * len(BSS_FLOAT32),
            "source": "bss_float32.parquet",
        },
        {
            "name": "bss_double",
            "type": "double",
            "count": len(BSS_DOUBLE),
            "input": b"".join(struct.pack("<d", value) for value in BSS_DOUBLE),
            "reference": data_page(double_data, double_pages),
            "plain_bytes": 8 * len(BSS_DOUBLE),
            "source": "bss_double.parquet",
        },
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
    print(f"wrote {len(cases)} BSS cases to {OUT}")


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
