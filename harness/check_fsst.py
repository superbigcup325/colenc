#!/usr/bin/env python3
"""Check the FSST-style encoder's round trip and scoreboard (P4).

FSST is not a Parquet encoding, so there is no reference stream. Each case
feeds a string column through `fsst_probe`, which compresses, decompresses,
verifies the round trip and prints the sizes; this script collects the ratios.

Usage:
    python3 harness/check_fsst.py
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CASES = [
    ("dict_string", HERE / "fixtures" / "dict" / "dict_string.input.bin"),
    (
        "delta_byte_array_string",
        HERE / "fixtures" / "delta" / "delta_byte_array_string.input.bin",
    ),
]
LINE = re.compile(r"encoded=(\d+)B plain=(\d+)B roundtrip=ok")


def main() -> int:
    failures = 0
    for name, path in CASES:
        result = subprocess.run(
            [
                "moon",
                "run",
                "--target",
                "native",
                "harness/fsst_probe",
                "--",
                "--in",
                str(path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        match = LINE.search(result.stdout)
        if result.returncode != 0 or match is None:
            failures += 1
            print(f"FAIL {name}: round trip or probe failed")
            print(result.stdout + result.stderr)
            continue
        encoded = int(match.group(1))
        plain = int(match.group(2))
        ratio = 100.0 * encoded / plain
        print(f"PASS {name}: {encoded} bytes vs {plain} PLAIN ({ratio:.2f}%)")
    if failures:
        print(f"{failures} case(s) failed")
        return 1
    print("all FSST cases round trip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
