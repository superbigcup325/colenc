#!/usr/bin/env python3
"""Generate docs/scoreboard.md from the throughput bench.

Runs `harness/bench` on native and wasm-gc, converts the tab-separated output
to MB/s against the PLAIN input size, and writes the markdown tables.

Each phase is measured once per round, and the reported number is the median
over the rounds: a single round of the same binary swings by 10-20% for the
small cases on this host, so one round is not enough to compare two runs (a
toolchain bump, say) without inventing a difference.

Usage:
    python3 harness/scoreboard.py [--rounds N] [--raw out.json]

`--raw` keeps every round instead of only the medians, so a report can show the
dispersion the medians hide.
"""

from __future__ import annotations

import datetime as dt
import json
import platform
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("native", "wasm-gc")
ROUNDS = 3


def run(target: str) -> list[dict]:
    result = subprocess.run(
        ["moon", "run", "--target", target, "--release", "harness/bench"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    rows = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 7:
            continue
        case, encoding, values, plain, encoded, enc_ms, dec_ms = parts
        rows.append(
            {
                "case": case,
                "encoding": encoding,
                "values": int(values),
                "plain": int(plain),
                "encoded": int(encoded),
                "enc_ms": float(enc_ms),
                "dec_ms": float(dec_ms),
            }
        )
    if not rows:
        raise SystemExit(f"no bench rows for target {target}")
    return rows


def collect(target: str, rounds: int, raw: list[dict]) -> list[dict]:
    """Median of `rounds` runs, in the order the first round reported."""
    merged: dict[tuple[str, str], list[dict]] = {}
    order: list[tuple[str, str]] = []
    for round_index in range(rounds):
        for row in run(target):
            key = (row["case"], row["encoding"])
            if key not in merged:
                merged[key] = []
                order.append(key)
            merged[key].append(row)
            raw.append({"target": target, "round": round_index, **row})
    collected = []
    for key in order:
        rows = merged[key]
        if len(rows) != rounds:
            raise SystemExit(f"{key}: {len(rows)} of {rounds} rounds reported")
        sizes = {row["encoded"] for row in rows}
        if len(sizes) != 1:
            raise SystemExit(f"{key}: encoded size is not stable across rounds: {sizes}")
        collected.append(
            {
                "case": rows[0]["case"],
                "encoding": rows[0]["encoding"],
                "values": rows[0]["values"],
                "plain": rows[0]["plain"],
                "encoded": rows[0]["encoded"],
                "enc_ms": statistics.median(row["enc_ms"] for row in rows),
                "dec_ms": statistics.median(row["dec_ms"] for row in rows),
            }
        )
    return collected


def mb_per_s(plain_bytes: int, milliseconds: float) -> str:
    if milliseconds <= 0:
        return "n/a"
    return f"{plain_bytes / 1e6 / (milliseconds / 1000):.1f}"


def table(rows: list[dict]) -> str:
    lines = [
        "| case | encoding | encoded bytes | ratio | encode MB/s | decode MB/s |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        ratio = 100.0 * row["encoded"] / row["plain"]
        lines.append(
            f"| {row['case']} | {row['encoding']} | {row['encoded']} | "
            f"{ratio:.1f}% | {mb_per_s(row['plain'], row['enc_ms'])} | "
            f"{mb_per_s(row['plain'], row['dec_ms'])} |"
        )
    return "\n".join(lines)


def worst_swing(target: str, rows: list[dict], raw: list[dict]) -> str:
    """The largest round-to-round spread, as a share of the median."""
    worst = (0.0, "")
    for row in rows:
        rounds = [
            entry
            for entry in raw
            if entry["target"] == target
            and entry["case"] == row["case"]
            and entry["encoding"] == row["encoding"]
        ]
        times = [entry["enc_ms"] for entry in rounds if entry["enc_ms"] > 0]
        if len(times) < 2:
            continue
        spread = (max(times) - min(times)) / statistics.median(times)
        if spread > worst[0]:
            worst = (spread, f"{row['case']} / {row['encoding']}")
    if not worst[1]:
        return "n/a"
    return f"{100 * worst[0]:.0f}% ({worst[1]})"


def revision() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    commit = result.stdout.strip() if result.returncode == 0 else "unknown"
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    # The scoreboard itself is the file being regenerated, so its own pending
    # edit is not a contaminated measurement.
    dirty_lines = [
        line
        for line in status.stdout.splitlines()
        if not line.endswith(" docs/scoreboard.md")
    ]
    dirty = " + uncommitted changes" if dirty_lines else ""
    return f"`{commit}`{dirty}"


def cpu_name() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown CPU"


def main() -> int:
    rounds = ROUNDS
    if "--rounds" in sys.argv:
        rounds = int(sys.argv[sys.argv.index("--rounds") + 1])
    if rounds < 1:
        raise SystemExit("--rounds must be at least 1")
    raw_path = None
    if "--raw" in sys.argv:
        raw_path = Path(sys.argv[sys.argv.index("--raw") + 1])
    version = subprocess.run(
        ["moon", "version"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.splitlines()[0].strip()
    raw: list[dict] = []
    results = {target: collect(target, rounds, raw) for target in TARGETS}

    parts = [
        "# Throughput scoreboard",
        "",
        "Generated by `python3 harness/scoreboard.py` on "
        f"{dt.date.today().isoformat()}.",
        "",
        f"- Machine: {cpu_name()}",
        f"- Revision: {revision()}",
        f"- Toolchain: `{version}`",
        "- Method: `harness/bench` (release build) encodes and decodes fixed "
        "datasets, warming up once, sizing the repetition count for about "
        "200 ms and then growing it until each timed round spans at least "
        "20 ms, because the clock only resolves milliseconds; each figure is "
        f"the median of {rounds} rounds. MB/s is computed against the PLAIN "
        "input size. Numbers are single-machine and not comparable across "
        "hosts, and a single round of the same binary still swings by 10-20% on "
        "the small cases, so compare toolchains or rewrites through medians, "
        "never through one run.",
        "- Ratio is encoded bytes against PLAIN for the same column.",
        "- A `ROARING+run_optimize` decode expands a 230-byte stream back into "
        "a million ids, so its decode MB/s is the rate ids come out, not the "
        "rate bytes are read; compare it with the ratio column, not alone.",
        "- The `roaring-*` rows are a bitmap index, not a page encoding: "
        "`values` is the cardinality of the set, `plain` is the raw INT32 id "
        "stream it replaces (4 bytes per id, so MB/s is per input id byte), "
        "encode covers `from_ids` plus the serialization, and a "
        "`ROARING+run_optimize` row runs `run_optimize` before serializing.",
        "",
    ]
    for target in TARGETS:
        parts.append(f"## {target}")
        parts.append("")
        parts.append(table(results[target]))
        parts.append("")

    swings = {target: worst_swing(target, results[target], raw) for target in TARGETS}
    parts.insert(
        6,
        "- Worst round-to-round encode swing across all rows: "
        + ", ".join(f"{target} {swings[target]}" for target in TARGETS)
        + ".",
    )

    path = ROOT / "docs" / "scoreboard.md"
    path.write_text("\n".join(parts))
    print(f"wrote {path}")
    for target in TARGETS:
        delta = next(
            row
            for row in results[target]
            if row["case"] == "int64-monotonic"
            and row["encoding"] == "DELTA_BINARY_PACKED"
        )
        print(
            f"{target}: int64 monotonic delta "
            f"encode {mb_per_s(delta['plain'], delta['enc_ms'])} MB/s, "
            f"decode {mb_per_s(delta['plain'], delta['dec_ms'])} MB/s"
        )
        print(f"{target}: worst round-to-round encode swing {swings[target]}")
    if raw_path is not None:
        raw_path.write_text(json.dumps(raw, indent=1) + "\n")
        print(f"wrote {raw_path} ({len(raw)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
