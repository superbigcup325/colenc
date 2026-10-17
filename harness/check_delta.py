#!/usr/bin/env python3
"""Diff the library's delta encodings against the reference (P3).

Runs `delta_probe` once per case in `fixtures/delta/manifest.json`, byte-diffs
the stream, and prints the ratio against PLAIN.

Usage:
    python3 harness/check_delta.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from diff_bytes import first_difference

HERE = Path(__file__).resolve().parent
CASES = HERE / "fixtures" / "delta"
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
                    "harness/delta_probe",
                    "--",
                    "--in",
                    str(CASES / case["input_file"]),
                    "--type",
                    case["type"],
                    "--encoding",
                    case["encoding"],
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
            reference = (CASES / case["reference_file"]).read_bytes()
            offset = first_difference(mine, reference)
            if offset is not None:
                failures += 1
                print(
                    f"FAIL {case['name']}: first difference at byte {offset} "
                    f"(mine {len(mine)}, reference {len(reference)})"
                )
                continue
            ratio = 100.0 * len(mine) / case["plain_bytes"]
            print(
                f"PASS {case['name']}: {case['encoding']}, {case['count']} values, "
                f"{len(mine)} bytes vs {case['plain_bytes']} PLAIN ({ratio:.2f}%)"
            )
    if failures:
        print(f"{failures} case(s) differ")
        return 1
    print("all delta cases match the reference byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
