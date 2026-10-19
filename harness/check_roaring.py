#!/usr/bin/env python3
"""Diff the library's Roaring bitmap output against the reference (P6).

Runs `roaring_probe` once per case and twice per case when the reference has a
run-optimised form, byte-diffs each stream, and prints the ratio against the
PLAIN baseline a bitmap index replaces.

Usage:
    python3 harness/check_roaring.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

from diff_bytes import first_difference

HERE = Path(__file__).resolve().parent
CASES = HERE / "fixtures" / "roaring"
ROOT = HERE.parent


def run_probe(case: dict, out: Path, run_optimize: bool) -> str | None:
    command = [
        "moon",
        "run",
        "--target",
        "native",
        "harness/roaring_probe",
        "--",
        "--in",
        str(CASES / case["input_file"]),
        "--out",
        str(out),
    ]
    if run_optimize:
        command.append("--run-optimize")
    result = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not out.exists():
        return result.stdout + result.stderr
    return None


def main() -> int:
    manifest = json.loads((CASES / "manifest.json").read_text())
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for case in manifest["cases"]:
            name = case["name"]
            reference = (CASES / case["reference_file"]).read_bytes()
            shape = ",".join(case["reference_shape"]["shapes"]) or "empty"

            plain = Path(tmp) / f"{name}.mine.bin"
            error = run_probe(case, plain, run_optimize=False)
            if error is not None:
                failures += 1
                print(f"FAIL {name}: probe failed")
                print(error)
                continue
            mine = plain.read_bytes()
            offset = first_difference(mine, reference)
            if offset is not None:
                failures += 1
                print(f"FAIL {name}: first difference at byte {offset}")
                print(f"  ours      {mine[:32].hex()}")
                print(f"  reference {reference[:32].hex()}")
                continue
            ratio = len(reference) / case["plain_bytes"] if case["plain_bytes"] else 0
            print(
                f"PASS {name}: {case['distinct']} distinct ids, "
                f"{len(reference)} bytes vs {case['plain_bytes']} PLAIN "
                f"({ratio:.2%}), containers [{shape}]"
            )

            if "reference_run_file" not in case:
                continue
            optimised_reference = (CASES / case["reference_run_file"]).read_bytes()
            optimised = Path(tmp) / f"{name}.mine.run.bin"
            error = run_probe(case, optimised, run_optimize=True)
            if error is not None:
                failures += 1
                print(f"FAIL {name} (run optimised): probe failed")
                print(error)
                continue
            offset = first_difference(optimised.read_bytes(), optimised_reference)
            if offset is not None:
                failures += 1
                print(
                    f"FAIL {name} (run optimised): first difference at byte {offset}"
                )
                print(f"  ours      {optimised.read_bytes()[:32].hex()}")
                print(f"  reference {optimised_reference[:32].hex()}")
                continue
            print(
                f"PASS {name} (run optimised): "
                f"{len(optimised_reference)} bytes vs "
                f"{len(reference)} without runs"
            )

    if failures:
        print(f"{failures} case(s) diverged from the reference")
        return 1
    print("all roaring cases match the reference byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
