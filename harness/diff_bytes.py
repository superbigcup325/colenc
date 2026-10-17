#!/usr/bin/env python3
"""Byte-diff two blobs and point at the first divergence (T0.3).

The acceptance rig compares colenc output with a reference implementation
byte-for-byte. A plain `cmp` tells you they differ; this tool tells you where
the encoder went wrong: the exact offset, both sides in hex, and the following
difference runs.

Usage:
    python3 harness/diff_bytes.py OURS.bin REF.bin
    python3 harness/diff_bytes.py ours.bin ref.bin --context 32 --max-runs 3

Exit status: 0 identical, 1 different, 2 unreadable input.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

CHUNK = 4096


def first_difference(a: bytes, b: bytes) -> int | None:
    """Return the index of the first differing byte, or None if equal.

    A differing length counts as a difference at the end of the shorter blob.
    """
    shorter = min(len(a), len(b))
    for base in range(0, shorter, CHUNK):
        end = min(base + CHUNK, shorter)
        if a[base:end] != b[base:end]:
            for index in range(base, end):
                if a[index] != b[index]:
                    return index
    if len(a) != len(b):
        return shorter
    return None


def difference_runs(a: bytes, b: bytes, limit: int) -> list[tuple[int, int]]:
    """Group differing offsets into [start, end) runs, at most `limit` of them."""
    runs: list[tuple[int, int]] = []
    start = None
    for index in range(min(len(a), len(b))):
        if a[index] != b[index]:
            if start is None:
                start = index
        elif start is not None:
            runs.append((start, index))
            start = None
            if len(runs) == limit:
                return runs
    if start is not None and len(runs) < limit:
        runs.append((start, min(len(a), len(b))))
    return runs


def hexdump(data: bytes, offset: int, context: int) -> str:
    start = max(0, offset - context)
    end = min(len(data), offset + context)
    lines = []
    for line_start in range(start, end, 16):
        line_end = min(line_start + 16, end)
        raw = data[line_start:line_end]
        hexes = " ".join(f"{byte:02x}" for byte in raw)
        text = "".join(chr(byte) if 32 <= byte < 127 else "." for byte in raw)
        marker = "<" if line_start <= offset < line_end else " "
        lines.append(f"  {line_start:08x} {hexes:<47} {marker} {text}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ours", type=Path)
    parser.add_argument("reference", type=Path)
    parser.add_argument("--context", type=int, default=16, help="hexdump radius")
    parser.add_argument("--max-runs", type=int, default=5)
    args = parser.parse_args(argv)

    try:
        ours = args.ours.read_bytes()
        reference = args.reference.read_bytes()
    except OSError as error:
        print(f"diff_bytes: {error}", file=sys.stderr)
        return 2

    offset = first_difference(ours, reference)
    if offset is None:
        print(f"PASS {args.ours} == {args.reference} ({len(ours)} bytes)")
        return 0

    print(f"FAIL {args.ours} != {args.reference}")
    print(f"  candidate: {len(ours)} bytes")
    print(f"  reference: {len(reference)} bytes")
    if offset >= min(len(ours), len(reference)):
        print(f"  lengths differ; content matches for the first {offset} bytes")
    else:
        print(f"  first difference at byte {offset} (0x{offset:x})")
        print(
            f"  candidate byte 0x{ours[offset]:02x}, reference byte 0x{reference[offset]:02x}"
        )
        print("  candidate:")
        print(hexdump(ours, offset, args.context))
        print("  reference:")
        print(hexdump(reference, offset, args.context))

    runs = difference_runs(ours, reference, args.max_runs)
    if runs:
        total = sum(end - start for start, end in runs)
        shown = ", ".join(f"{start}..{end - 1}" for start, end in runs)
        print(f"  difference runs ({len(runs)} shown, {total} bytes): {shown}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
