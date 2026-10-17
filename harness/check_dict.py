#!/usr/bin/env python3
"""Diff the library's dictionary encoding against the reference (P2).

Runs `dict_probe` once per case in `fixtures/dict/manifest.json`, diffs both
payloads byte for byte, and prints the compression ratio against the PLAIN
baseline from the manifest.

Usage:
    python3 harness/check_dict.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from diff_bytes import first_difference

HERE = Path(__file__).resolve().parent
CASES = HERE / "fixtures" / "dict"
ROOT = HERE.parent


def main() -> int:
    manifest = json.loads((CASES / "manifest.json").read_text())
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for case in manifest["cases"]:
            dict_out = Path(tmp) / f"{case['name']}.dict.bin"
            indices_out = Path(tmp) / f"{case['name']}.indices.bin"
            result = subprocess.run(
                [
                    "moon",
                    "run",
                    "--target",
                    "native",
                    "harness/dict_probe",
                    "--",
                    "--in",
                    str(CASES / case["input_file"]),
                    "--type",
                    case["type"],
                    "--out-dict",
                    str(dict_out),
                    "--out-indices",
                    str(indices_out),
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

            pairs = (
                ("dictionary", dict_out, CASES / case["dictionary_file"]),
                ("indices", indices_out, CASES / case["indices_file"]),
            )
            case_failed = False
            for label, mine_path, ref_path in pairs:
                mine = mine_path.read_bytes()
                reference = ref_path.read_bytes()
                offset = first_difference(mine, reference)
                if offset is not None:
                    case_failed = True
                    print(
                        f"FAIL {case['name']} {label}: first difference at "
                        f"byte {offset} (mine {len(mine)}, reference {len(reference)})"
                    )
            if case_failed:
                failures += 1
                continue

            encoded = dict_out.stat().st_size + indices_out.stat().st_size
            ratio = 100.0 * encoded / case["plain_bytes"]
            print(
                f"PASS {case['name']}: type {case['type']}, "
                f"{case['dictionary_size']} entries at width {case['width']}, "
                f"{encoded} bytes vs {case['plain_bytes']} PLAIN ({ratio:.2f}%)"
            )
    if failures:
        print(f"{failures} case(s) differ")
        return 1
    print("all dictionary cases match the reference byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
