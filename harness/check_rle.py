#!/usr/bin/env python3
"""Diff the library's RLE output against the reference streams (T1.3).

Runs `moon run harness/rle_probe` once per case in
`fixtures/rle/manifest.json` and byte-diffs the result against the reference
extracted from the Parquet fixture.

Usage:
    python3 harness/check_rle.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from diff_bytes import first_difference

HERE = Path(__file__).resolve().parent
CASES = HERE / "fixtures" / "rle"
ROOT = HERE.parent


def main() -> int:
    manifest = json.loads((CASES / "manifest.json").read_text())
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for case in manifest["cases"]:
            out = Path(tmp) / f"{case['name']}.mine.bin"
            result = subprocess.run(
                [
                    "moon",
                    "run",
                    "--target",
                    "native",
                    "harness/rle_probe",
                    "--",
                    "--in",
                    str(CASES / case["input"]),
                    "--width",
                    str(case["width"]),
                    "--out",
                    str(out),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                failures += 1
                print(f"FAIL {case['name']}: probe failed")
                print(result.stdout + result.stderr)
                continue
            mine = out.read_bytes()
            reference = (CASES / case["reference"]).read_bytes()
            offset = first_difference(mine, reference)
            if offset is None:
                print(
                    f"PASS {case['name']}: width {case['width']}, "
                    f"{case['count']} values, {len(mine)} bytes"
                )
            else:
                failures += 1
                print(
                    f"FAIL {case['name']}: first difference at byte {offset} "
                    f"(mine {len(mine)} bytes, reference {len(reference)} bytes)"
                )
    if failures:
        print(f"{failures} case(s) differ")
        return 1
    print("all RLE cases match the reference byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
