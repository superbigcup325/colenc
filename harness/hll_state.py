#!/usr/bin/env python3
# What does a grouped HyperLogLog actually keep resident?
#
# `docs/SKETCHES.md` promises one sketch per group and `docs/NEXT-STEPS.md`
# records what that cost: 16 KiB of registers per group, which is why the
# consumer's grouped `approx_count_distinct` was worth a second look at many small
# groups. The figures that used to sit in the scoreboard came from a scratch probe
# through `harness/perf hll-groups`; this script is that probe, made repeatable and
# able to hold two builds side by side.
#
# Each case is one isolated child process running
# `harness/perf hll-groups <groups> <per_group>`, which builds that many sketches,
# fills each with that many distinct Int64 values, estimates every one of them and
# prints the sum. Peak RSS is the child's own `ru_maxrss`; the helper adds nothing
# but the measurement.
#
# Usage:
#   moon build --release --target native harness/perf
#   python3 harness/hll_state.py \
#       --binary _build/native/release/build/harness/perf/perf.exe
#
#   # the same matrix against a control build, one table per case
#   python3 harness/hll_state.py \
#       --binary _build/native/release/build/harness/perf/perf.exe \
#       --control /path/to/dense/build/harness/perf/perf.exe
#
# The answer is checked as well as the resource: a sum of estimates that drifts
# from the true cardinality fails the case rather than reporting a smaller number.

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# (label, groups, distinct values per group)
#
# The first row is the old scoreboard row; the rest sweep from "one big group" to
# "an enormous number of one-value groups", which is the shape a SQL GROUP BY
# produces and the reason the state cost matters at all.
SHAPES: list[tuple[str, int, int]] = [
    ("1000 x 10", 1_000, 10),
    ("1000 x 100", 1_000, 100),
    ("1000 x 128", 1_000, 128),
    ("1000 x 200", 1_000, 200),
    ("1000 x 500", 1_000, 500),
    ("1000 x 1000", 1_000, 1_000),
    ("5000 x 10", 5_000, 10),
    ("20000 x 10", 20_000, 10),
    ("50000 x 10", 50_000, 10),
    ("20000 x 1", 20_000, 1),
    ("1 x 1000000", 1, 1_000_000),
]

CHILD = r"""
import json, resource, subprocess, sys, time
cmd = json.loads(sys.argv[1])
start = time.perf_counter()
proc = subprocess.run(cmd, capture_output=True)
wall = (time.perf_counter() - start) * 1000.0
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
sys.stdout.write(json.dumps({"wall_ms": wall, "peak_mb": peak,
                             "code": proc.returncode,
                             "stdout": proc.stdout.decode()[-4000:],
                             "stderr": proc.stderr.decode()[-2000:]}))
"""


def run_child(cmd: list[str]) -> dict:
    out = subprocess.run(
        [sys.executable, "-c", CHILD, json.dumps(cmd)],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"helper failed: {out.stderr[-500:]}")
    return json.loads(out.stdout)


def measure(binary: pathlib.Path, groups: int, per_group: int, repeats: int) -> dict:
    args = [str(binary), "hll-groups", str(groups), str(per_group)]
    best = None
    for _ in range(repeats):
        result = run_child(args)
        if result["code"] != 0:
            raise SystemExit(
                f"{' '.join(args)} exited {result['code']}: {result['stderr']}"
            )
        if best is None or result["peak_mb"] > best["peak_mb"]:
            best = result
        if best is not None:
            best["wall_ms"] = min(best["wall_ms"], result["wall_ms"])
    # `groups=… per_group=… estimate=…` is the probe's one output line.
    fields = {}
    for part in best["stdout"].split():
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = value
    best["estimate"] = float(fields.get("estimate", "nan"))
    return best


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--control", type=pathlib.Path)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument(
        "--shapes",
        help="limit the matrix: a comma-separated list of labels",
    )
    args = parser.parse_args(argv)

    if not args.binary.exists():
        raise SystemExit(f"no binary at {args.binary}")
    if args.control and not args.control.exists():
        raise SystemExit(f"no control binary at {args.control}")

    wanted = None if not args.shapes else set(args.shapes.split(","))
    shapes = [shape for shape in SHAPES if not wanted or shape[0] in wanted]
    if not shapes:
        raise SystemExit(f"no shape matches {args.shapes}")

    record: dict = {
        "binary": str(args.binary),
        "control": str(args.control) if args.control else None,
        "repeats": args.repeats,
        "cases": [],
    }

    header = f"{'shape':14} {'rows':>9} {'peak':>9} {'wall':>9} {'answer':>9}"
    if args.control:
        header += f" {'control':>9} {'delta':>9}"
    print(header)

    for label, groups, per_group in shapes:
        sparse = measure(args.binary, groups, per_group, args.repeats)
        truth = groups * per_group
        error = (sparse["estimate"] - truth) / truth
        if not -0.05 < error < 0.05:
            raise SystemExit(
                f"{label}: estimate {sparse['estimate']:.0f} for {truth} values "
                f"({error * 100:+.1f}%)"
            )
        entry = {
            "shape": label,
            "groups": groups,
            "per_group": per_group,
            "rows": truth,
            "peak_mb": round(sparse["peak_mb"], 1),
            "wall_ms": round(sparse["wall_ms"], 1),
            "estimate": round(sparse["estimate"], 1),
        }
        row = (
            f"{label:14} {truth:9d} {sparse['peak_mb']:8.1f}M "
            f"{sparse['wall_ms']:8.1f}ms {sparse['estimate']:9.0f}"
        )
        if args.control:
            dense = measure(args.control, groups, per_group, args.repeats)
            entry["control_peak_mb"] = round(dense["peak_mb"], 1)
            entry["control_wall_ms"] = round(dense["wall_ms"], 1)
            row += f" {dense['peak_mb']:8.1f}M {dense['peak_mb'] - sparse['peak_mb']:8.1f}M"
        print(row)
        record["cases"].append(entry)

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(f"record in {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
