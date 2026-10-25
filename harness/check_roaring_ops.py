#!/usr/bin/env python3
"""Check the Roaring sequences that have no reference bytes (P6 / R1).

Byte identity cannot judge these. After `run_optimize`, CRoaring keeps the run
container when an id is added while colenc de-optimises it, so the two streams
legitimately differ. The criteria here are the ones that actually broke in R0:

- the stream parses back to the expected set (round trip, from the bytes);
- every container is legal *as read from the bytes*: arrays hold at most 4096
  values and are strictly ascending, bitmaps hold more and their popcount is the
  declared cardinality, runs are ascending, disjoint, non-adjacent and strictly
  smaller than the form they replaced. The library is never asked to grade its
  own containers, because a reader that trusts the writer would agree with it;
- a set operation's result does not alias its operands, so mutating the result
  leaves both inputs unchanged.

`fixtures/roaring_ops.json` pins the layout (encoded size and container shape
per step). That is a regression pin, not a criterion: a legal but different shape
choice should show up as a diff and a decision, not as a silent change.

Usage:
    python3 harness/check_roaring_ops.py
    python3 harness/check_roaring_ops.py --update   # re-pin the layout
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PIN = HERE / "fixtures" / "roaring_ops.json"

COOKIE_NO_RUN = 12346
COOKIE_RUN = 12347
ARRAY_MAX = 4096
WORDS = 1024
MAX_VALUE = 65536


class Failure(SystemExit):
    pass


def fail(step: str, message: str) -> None:
    raise SystemExit(f"FAIL {step}: {message}")


def u16(raw: bytes, position: int) -> int:
    return struct.unpack_from("<H", raw, position)[0]


def u32(raw: bytes, position: int) -> int:
    return struct.unpack_from("<I", raw, position)[0]


def popcount(value: int) -> int:
    return bin(value).count("1")


def parse(step: str, raw: bytes) -> tuple[list[dict], list[int]]:
    """Parse a portable bitmap and validate every container it declares."""
    if len(raw) < 8:
        fail(step, f"{len(raw)} bytes is too short for a bitmap header")
    cookie = u32(raw, 0)
    position = 4
    low = cookie & 0xFFFF
    if low == COOKIE_RUN:
        size = (cookie >> 16) + 1
        flag_bytes = (size + 7) // 8
        flags = raw[position : position + flag_bytes]
        if len(flags) != flag_bytes:
            fail(step, "run-container flag bytes are truncated")
        position += flag_bytes
        has_run = [bool((flags[i // 8] >> (i % 8)) & 1) for i in range(size)]
    elif low == COOKIE_NO_RUN:
        size = u32(raw, position)
        position += 4
        has_run = [False] * size
    else:
        fail(step, f"bad cookie {low}")

    keys: list[int] = []
    cards: list[int] = []
    for _ in range(size):
        key, card_minus_one = struct.unpack_from("<HH", raw, position)
        position += 4
        keys.append(key)
        cards.append(card_minus_one + 1)
    for index in range(1, size):
        if keys[index - 1] >= keys[index]:
            fail(step, f"keys are not ascending at container {index}")

    with_runs = any(has_run)
    has_offsets = (not with_runs) or size >= 4
    offsets = None
    if has_offsets:
        offsets = [u32(raw, position + 4 * index) for index in range(size)]
        position += 4 * size

    containers: list[dict] = []
    ids: list[int] = []
    for index in range(size):
        key = keys[index]
        card = cards[index]
        if offsets is not None and offsets[index] != position:
            fail(
                step,
                f"container {index} declares offset {offsets[index]} but its "
                f"body starts at {position}",
            )
        if has_run[index]:
            runs = u16(raw, position)
            position += 2
            pairs = []
            previous_end = -2
            covered = 0
            for _ in range(runs):
                start, length = struct.unpack_from("<HH", raw, position)
                position += 4
                if length < 0:
                    fail(step, f"container {index} has a negative run length")
                if start <= previous_end + 1:
                    fail(
                        step,
                        f"container {index}: run at {start} overlaps or touches "
                        f"the previous run ending at {previous_end}",
                    )
                if start + length >= MAX_VALUE:
                    fail(step, f"container {index}: run {start}+{length} is out of range")
                previous_end = start + length
                covered += length + 1
                pairs.append((start, length))
            if covered != card:
                fail(
                    step,
                    f"container {index}: runs cover {covered} values but the "
                    f"descriptor declares {card}",
                )
            alternative = 2 * card if card <= ARRAY_MAX else 8 * WORDS
            if 2 + 4 * runs >= alternative:
                fail(
                    step,
                    f"container {index}: a run container of {runs} runs is not "
                    f"strictly smaller than its {alternative}-byte alternative",
                )
            for start, length in pairs:
                ids.extend(key * MAX_VALUE + value for value in range(start, start + length + 1))
            containers.append({"key": key, "shape": "run", "cardinality": card})
        elif card <= ARRAY_MAX:
            values = list(struct.unpack_from(f"<{card}H", raw, position))
            position += 2 * card
            for offset in range(1, card):
                if values[offset - 1] >= values[offset]:
                    fail(step, f"container {index}: array values are not strictly ascending")
            if values and values[-1] >= MAX_VALUE:
                fail(step, f"container {index}: array value out of range")
            ids.extend(key * MAX_VALUE + value for value in values)
            containers.append({"key": key, "shape": "array", "cardinality": card})
        else:
            words = struct.unpack_from(f"<{WORDS}q", raw, position)
            position += 8 * WORDS
            if card <= ARRAY_MAX:
                fail(step, f"container {index}: a bitmap container declares {card} values")
            seen = sum(popcount(word & 0xFFFFFFFFFFFFFFFF) for word in words)
            if seen != card:
                fail(
                    step,
                    f"container {index}: bitmap popcount {seen} != declared {card}",
                )
            for word_index, word in enumerate(words):
                value = word & 0xFFFFFFFFFFFFFFFF
                while value:
                    bit = (value & -value).bit_length() - 1
                    ids.append(key * MAX_VALUE + word_index * 64 + bit)
                    value &= value - 1
            containers.append({"key": key, "shape": "bitmap", "cardinality": card})

    if position != len(raw):
        fail(step, f"parse ended at {position} of {len(raw)} bytes")
    if ids != sorted(ids):
        fail(step, "the decoded ids are not ascending")
    if len(set(ids)) != len(ids):
        fail(step, "the decoded ids contain a duplicate")
    return containers, ids


def fnv1a(ids: list[int]) -> int:
    """The probe's hash: FNV-1a 32 over the ascending ids, four bytes each."""
    value = 2166136261
    for id_ in ids:
        for byte in struct.pack("<I", id_ & 0xFFFFFFFF):
            value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return value


def expected_sets() -> list[tuple[str, set[int]]]:
    """The sequences the probe runs, written out independently of the library."""
    base = set(range(0, 5000))
    run_add = base | {6000}
    union = {1, 2, 3, 65536}
    intersect = set(range(50, 100))
    steps = [
        ("base", base),
        ("base-run", base),
        ("base-run-add", run_add),
        ("base-run-add-reparse", run_add),
        ("union-left", {1, 2}),
        ("union-right", {65536}),
        ("union", union),
        ("union-left-after", {1, 2}),
        ("union-right-after", {65536}),
        ("same-key-union", set(range(100))),
        ("intersect", intersect),
        ("intersect-add", intersect | {200}),
        ("intersect-left-after", set(range(100))),
        ("run-union-add", base | {6000, 65536}),
        ("cross-key-add", base | {131072}),
    ]
    return steps


def run_probe(directory: Path) -> dict[str, dict]:
    result = subprocess.run(
        [
            "moon",
            "run",
            "--target",
            "native",
            "harness/roaring_ops_probe",
            "--",
            "--out-dir",
            str(directory),
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "FAIL: the probe did not run\n" + result.stdout + result.stderr
        )
    reported: dict[str, dict] = {}
    for line in result.stdout.splitlines():
        if not line.startswith("step|"):
            continue
        _, name, cardinality, size, digest = line.split("|")
        reported[name] = {
            "cardinality": int(cardinality),
            "bytes": int(size),
            "hash": int(digest),
        }
    return reported


def main() -> int:
    update = "--update" in sys.argv
    steps = expected_sets()
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        reported = run_probe(directory)
        missing = [name for name, _ in steps if name not in reported]
        if missing:
            raise SystemExit(f"FAIL: the probe did not report {missing}")
        extra = sorted(set(reported) - {name for name, _ in steps})
        if extra:
            raise SystemExit(f"FAIL: the probe reported unexpected steps {extra}")

        layout: dict[str, dict] = {}
        failures = 0
        for name, expected in steps:
            raw = (directory / f"{name}.bin").read_bytes()
            try:
                containers, ids = parse(name, raw)
            except SystemExit as error:
                print(error)
                failures += 1
                continue
            if set(ids) != expected:
                print(
                    f"FAIL {name}: the stream holds {len(ids)} ids, "
                    f"{len(expected)} expected, "
                    f"{len(set(ids) ^ expected)} differ"
                )
                failures += 1
                continue
            claim = reported[name]
            if claim["cardinality"] != len(ids):
                print(
                    f"FAIL {name}: the library reports {claim['cardinality']} "
                    f"ids but the stream holds {len(ids)}"
                )
                failures += 1
            if claim["bytes"] != len(raw):
                print(
                    f"FAIL {name}: the library reports {claim['bytes']} bytes "
                    f"but wrote {len(raw)}"
                )
                failures += 1
            if claim["hash"] != fnv1a(ids):
                print(f"FAIL {name}: the library's id hash does not match the stream")
                failures += 1
            layout[name] = {
                "bytes": len(raw),
                "containers": containers,
            }

    if failures:
        print(f"{failures} step(s) failed")
        return 1

    if update or not PIN.exists():
        PIN.parent.mkdir(parents=True, exist_ok=True)
        PIN.write_text(json.dumps({"steps": layout}, indent=1, sort_keys=True) + "\n")
        print(f"wrote {PIN} ({len(layout)} steps)")
        if update:
            return 0

    pinned = json.loads(PIN.read_text())["steps"]
    drifted = 0
    for name, entry in layout.items():
        before = pinned.get(name)
        if before is None:
            print(f"FAIL {name}: not pinned yet; re-run with --update")
            drifted += 1
        elif before != entry:
            print(
                f"FAIL {name}: layout changed\n"
                f"  pinned: {json.dumps(before, sort_keys=True)}\n"
                f"  actual: {json.dumps(entry, sort_keys=True)}"
            )
            drifted += 1
    if drifted:
        print(f"{drifted} step(s) drifted from the pinned layout")
        return 1

    shapes: dict[str, int] = {}
    for entry in layout.values():
        for container in entry["containers"]:
            shapes[container["shape"]] = shapes.get(container["shape"], 0) + 1
    summary = ", ".join(f"{count} {shape}" for shape, count in sorted(shapes.items()))
    print(
        f"PASS {len(layout)} sequences: round trip, container legality, operand "
        f"independence and layout pin all hold ({summary})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
