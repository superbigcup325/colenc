#!/usr/bin/env python3
"""Build the Roaring bitmap byte-diff cases from the reference (P6).

Each case is a set of non-negative INT32 ids. The reference bytes come from
pyroaring (CRoaring), built through `BitMap.add` so no run optimisation happens,
plus a second reference with `run_optimize()` applied. The generator also parses
its own reference output and fails when a case does not actually contain the
container shapes it is meant to pin — a fixture that silently stops exercising
its branch would weaken every byte diff.

Usage:
    python3 harness/make_roaring_cases.py
    python3 harness/make_roaring_cases.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

from pyroaring import BitMap

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUT = FIXTURES / "roaring"

COOKIE_NO_RUN = 12346
COOKIE_RUN = 12347
ARRAY_MAX = 4096


def parse(raw: bytes) -> dict:
    """Parse a portable Roaring bitmap far enough to name its container shapes."""
    cookie = struct.unpack_from("<I", raw, 0)[0]
    position = 4
    with_runs = (cookie & 0xFFFF) == COOKIE_RUN
    if with_runs:
        size = (cookie >> 16) + 1
        flag_bytes = (size + 7) // 8
        flags = raw[position : position + flag_bytes]
        position += flag_bytes
        has_run = [(flags[i // 8] >> (i % 8)) & 1 == 1 for i in range(size)]
    elif (cookie & 0xFFFF) == COOKIE_NO_RUN:
        size = struct.unpack_from("<I", raw, position)[0]
        position += 4
        has_run = [False] * size
    else:
        raise SystemExit(f"bad cookie {cookie} in the reference output")
    keys = []
    cards = []
    for _ in range(size):
        key, card_minus_one = struct.unpack_from("<HH", raw, position)
        position += 4
        keys.append(key)
        cards.append(card_minus_one + 1)
    has_offsets = (not with_runs) or size >= 4
    if has_offsets:
        position += 4 * size
    shapes = []
    for index in range(size):
        if has_run[index]:
            runs = struct.unpack_from("<H", raw, position)[0]
            position += 2 + 4 * runs
            shapes.append("run")
        elif cards[index] <= ARRAY_MAX:
            position += 2 * cards[index]
            shapes.append("array")
        else:
            position += 8192
            shapes.append("bitmap")
    if position != len(raw):
        raise SystemExit(f"reference parse ended at {position}, not {len(raw)}")
    return {
        "size": size,
        "cardinality": sum(cards),
        "shapes": shapes,
        "offsets": has_offsets,
        "cookie": cookie,
    }


def reference(ids: list[int], run_optimize: bool) -> bytes:
    bitmap = BitMap()
    for value in ids:
        bitmap.add(value)
    if run_optimize:
        bitmap.run_optimize()
    return bitmap.serialize()


def contiguous(start: int, length: int) -> list[int]:
    return list(range(start, start + length))


def cases() -> list[dict]:
    dense = contiguous(0, 5000)
    mixed = (
        [7, 9, 700]
        + contiguous(65536, 6000)
        + [2 * 65536 + 3, 2 * 65536 + 4, 2 * 65536 + 5]
        + contiguous(3 * 65536, 8192)
    )
    four_with_runs = contiguous(0, 100) + contiguous(2 * 65536, 50) + contiguous(
        3 * 65536, 50
    ) + contiguous(4 * 65536, 50)
    return [
        {
            "name": "roaring_empty",
            "ids": [],
            "note": "the bare no-run header",
        },
        {
            "name": "roaring_single",
            "ids": [0],
            "note": "one array container, offset table present",
        },
        {
            "name": "roaring_small_array",
            "ids": [1, 2, 3, 65535, 65536],
            "note": "two array containers, one at the container edge",
        },
        {
            "name": "roaring_three_containers",
            "ids": [0, 65536, 131072, 100, 200],
            "note": "three containers, still under the run offset rule",
        },
        {
            "name": "roaring_four_containers",
            "ids": [0, 65536, 131072, 196608],
            "note": "four containers, the offset table is unconditional",
        },
        {
            "name": "roaring_bitmap_container",
            "ids": dense,
            "note": "5000 dense ids cross the 4096 array/bitmap threshold",
        },
        {
            "name": "roaring_mixed",
            "ids": mixed,
            "note": "array and bitmap containers side by side",
        },
        {
            "name": "roaring_top_id",
            "ids": [0, 2147483647],
            "note": "the largest representable id lands in container 32767",
        },
        {
            "name": "roaring_duplicates",
            "ids": [5] * 40 + [6, 5, 7] * 10,
            "note": "duplicates collapse: a bitmap is a set",
        },
        {
            "name": "roaring_run_single",
            "ids": contiguous(0, 100) + contiguous(200, 100),
            "note": "run optimisation wins in one container",
            "expect_run": {"run": 1},
        },
        {
            "name": "roaring_run_four",
            "ids": four_with_runs,
            "note": "runs plus four containers: offsets stay in the stream",
            "expect_run": {"run": 4, "offsets": True},
        },
        {
            "name": "roaring_run_mixed",
            "ids": contiguous(0, 100) + [65536, 65537, 65538, 65539],
            "note": "one run container next to an array container",
            "expect_run": {"run": 2},
        },
    ]


def build() -> list[dict]:
    built = []
    for case in cases():
        ids = case["ids"]
        payload = b"".join(struct.pack("<i", value) for value in ids)
        plain = reference(ids, False)
        optimized = reference(ids, True)
        shape = parse(plain)
        if shape["cardinality"] != len(set(ids)):
            raise SystemExit(f"{case['name']}: reference cardinality drifted")
        if "expect_run" in case:
            optimized_shape = parse(optimized)
            for kind, count in case["expect_run"].items():
                if kind == "offsets":
                    if optimized_shape["offsets"] != count:
                        raise SystemExit(
                            f"{case['name']}: expected offsets={count}, "
                            f"got {optimized_shape['offsets']}"
                        )
                    continue
                if optimized_shape["shapes"].count(kind) != count:
                    raise SystemExit(
                        f"{case['name']}: expected {count} {kind} container(s), "
                        f"got {optimized_shape['shapes']}"
                    )
        built.append(
            {
                "name": case["name"],
                "note": case["note"],
                "count": len(ids),
                "distinct": len(set(ids)),
                "input": payload,
                "reference": plain,
                "reference_run_optimized": optimized,
                "reference_shape": shape,
                "plain_bytes": 4 * len(ids),
            }
        )
    return built


def write_cases(built: list[dict]) -> list[tuple[Path, bytes]]:
    outputs = []
    manifest = {"source": "pyroaring", "version": pyroaring_version(), "cases": []}
    for case in built:
        name = case["name"]
        files = {
            "input_file": f"{name}.input.i32le",
            "reference_file": f"{name}.ref.bin",
        }
        outputs.append((OUT / files["input_file"], case["input"]))
        outputs.append((OUT / files["reference_file"], case["reference"]))
        if case["reference_run_optimized"] != case["reference"]:
            files["reference_run_file"] = f"{name}.ref.run.bin"
            outputs.append(
                (OUT / files["reference_run_file"], case["reference_run_optimized"])
            )
        manifest["cases"].append(
            {
                "name": name,
                "note": case["note"],
                "count": case["count"],
                "distinct": case["distinct"],
                "plain_bytes": case["plain_bytes"],
                "reference_bytes": len(case["reference"]),
                "reference_shape": case["reference_shape"],
                **files,
            }
        )
    payload = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    outputs.append((OUT / "manifest.json", payload.encode()))
    return outputs


def pyroaring_version() -> str:
    import pyroaring

    return pyroaring.__version__


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the checked-in cases instead of rewriting them",
    )
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    built = build()
    outputs = write_cases(built)
    if args.check:
        failures = 0
        for path, payload in outputs:
            if not path.exists():
                print(f"MISSING {path.name}")
                failures += 1
            elif path.read_bytes() != payload:
                print(
                    f"DRIFT   {path.name} "
                    f"({hashlib.sha256(path.read_bytes()).hexdigest()[:12]} != "
                    f"{hashlib.sha256(payload).hexdigest()[:12]})"
                )
                failures += 1
            else:
                print(f"PASS    {path.name}")
        if failures:
            print(f"{failures} case file(s) drifted; rerun without --check")
            return 1
        print(f"all {len(built)} roaring cases are reproducible")
        return 0
    for path, payload in outputs:
        path.write_bytes(payload)
    print(f"wrote {len(built)} cases and {len(outputs)} files to {OUT}")
    for case in built:
        shapes = ",".join(case["reference_shape"]["shapes"]) or "none"
        print(
            f"  {case['name']}: {case['distinct']} distinct ids, "
            f"{len(case['reference'])} bytes, containers [{shapes}]"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
