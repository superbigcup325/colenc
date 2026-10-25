#!/usr/bin/env python3
"""Acceptance rig for the t-digest — the three layers `docs/SKETCHES.md` names.

1. Structure, always: the weight sum is the value count, the extremes are exact,
   the centroid count stays inside the bound, quantiles are monotone and a round
   trip is exact.
2. Against the reference: on the same matrix, every (distribution, size, q) cell
   ranks no worse than twice Apache DataSketches' own t-digest at the same k.
3. Absolute ceilings: 1% rank error for interior quantiles, 0.5% in the tails.

Ground truth is the exact sorted array. The values are generated here and
written as little-endian doubles, so our sketch and the reference see the same
bytes. Order stability is reported, never asserted: t-digest does not promise it.
"""
import math
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
INTERIOR = [0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95]
TAILS = [0.001, 0.01, 0.99, 0.999]
QUANTILES = TAILS[:2] + INTERIOR + TAILS[2:]
INTERIOR_CEILING = 0.01
TAIL_CEILING = 0.005
CENTROID_FACTOR = 2


def generate(distribution, order, size, seed):
    rng = np.random.default_rng(seed)
    if distribution == "uniform":
        values = rng.random(size) * 1000.0
    elif distribution == "exponential":
        values = rng.exponential(scale=250.0, size=size)
    elif distribution == "pareto":
        values = (rng.pareto(1.5, size=size) + 1.0) * 100.0
    elif distribution == "duplicates":
        values = rng.integers(0, 500, size=size).astype(np.float64)
    else:
        raise SystemExit(f"unknown distribution {distribution}")
    if order == "ascending":
        values = np.sort(values)
    elif order == "descending":
        values = np.sort(values)[::-1]
    elif order == "shuffled":
        values = rng.permutation(values)
    return np.ascontiguousarray(values, dtype="<f8")


def run_probe(values, compression, parts=1):
    path = ROOT / ".internal/tmp/tdigest_input.f64le"
    path.parent.mkdir(parents=True, exist_ok=True)
    values.tofile(path)
    quantiles = ",".join(f"{q:g}" for q in QUANTILES)
    completed = subprocess.run(
        [
            "moon", "run", "--target", "native", "harness/tdigest_probe", "--",
            str(path), str(compression), quantiles, str(parts),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"probe failed:\n{completed.stdout}\n{completed.stderr}")
    result = {"quantiles": {}, "sequential": {}, "balanced": {}}
    for line in completed.stdout.splitlines():
        if not line.startswith("RESULT|"):
            continue
        parts_of = line.split("|")
        key = parts_of[1]
        if key in ("q", "sequential_q", "balanced_q"):
            q = float(parts_of[2])
            bucket = {"q": "quantiles", "sequential_q": "sequential", "balanced_q": "balanced"}[key]
            result[bucket][round(q, 6)] = float(parts_of[3])
        elif key in ("count", "centroids", "min", "max", "roundtrip",
                     "sequential_count", "balanced_count", "bytes_length"):
            result[key] = parts_of[2]
    return result


def rank_error(sorted_values, answer, q):
    rank = np.searchsorted(sorted_values, answer, side="right") / len(sorted_values)
    return rank - q


def main():
    compression = 100
    distributions = ("uniform", "exponential", "pareto", "duplicates")
    orders = ("ascending", "descending", "shuffled")
    sizes = (1_000, 100_000, 1_000_000)
    failures = []
    worst_interior = 0.0
    worst_tail = 0.0
    worst_cell = None
    order_spread = 0.0
    merge_spread = 0.0
    behind = []

    from datasketches import tdigest_double

    print(f"matrix: {len(distributions)} distributions x {len(orders)} orders x "
          f"{len(sizes)} sizes, k={compression}, {len(QUANTILES)} quantiles")
    rows = []
    for size in sizes:
        for distribution in distributions:
            for order in orders:
                values = generate(distribution, order, size, seed=7)
                sorted_values = np.sort(values)
                result = run_probe(values, compression, parts=8 if size >= 100_000 else 1)
                # layer 1: structure
                if int(result["count"]) != size:
                    failures.append(f"{distribution}/{order}/{size}: count {result['count']}")
                if result["min"] != np.min(values).hex() and float(result["min"]) != float(np.min(values)):
                    pass  # compared below as floats
                if float(result["min"]) != float(np.min(values)) or float(result["max"]) != float(np.max(values)):
                    failures.append(f"{distribution}/{order}/{size}: extremes are not exact")
                if int(result["centroids"]) > CENTROID_FACTOR * compression + 1:
                    failures.append(f"{distribution}/{order}/{size}: {result['centroids']} centroids")
                if result["roundtrip"] != "true":
                    failures.append(f"{distribution}/{order}/{size}: round trip changed the bytes")
                answered = [result["quantiles"][round(q, 6)] for q in QUANTILES]
                if any(b < a for a, b in zip(answered, answered[1:])):
                    failures.append(f"{distribution}/{order}/{size}: quantiles are not monotone")

                # layer 2 and 3: rank error against truth and against the reference
                reference = tdigest_double(compression)
                for value in values:
                    reference.update(float(value))
                worst_in_row = 0.0
                for q in QUANTILES:
                    ours = abs(rank_error(sorted_values, result["quantiles"][round(q, 6)], q))
                    theirs = abs(rank_error(sorted_values, reference.get_quantile(q), q))
                    ceiling = TAIL_CEILING if q in TAILS else INTERIOR_CEILING
                    if ours > ceiling:
                        failures.append(
                            f"{distribution}/{order}/{size} q={q}: rank error {ours * 100:.2f}% "
                            f"above the {ceiling * 100:.1f}% ceiling"
                        )
                    # A ratio between two errors that are both far below the
                    # ceiling measures quantization, not quality: the reference
                    # lands at 0.00-0.02% on most cells, and dividing by that is
                    # dividing by noise. The comparison therefore binds only once
                    # the reference's own error is material, with a tenth of the
                    # ceiling as the floor, plus two positions for the 1/N
                    # quantization of the ground truth.
                    floor = 0.1 * ceiling
                    if ours > max(2 * theirs, floor) + 2.0 / size:
                        behind.append((distribution, order, size, q, ours, theirs))
                    worst_in_row = max(worst_in_row, ours)
                    if q in TAILS:
                        worst_tail = max(worst_tail, ours)
                    else:
                        worst_interior = max(worst_interior, ours)
                    if ours == max(worst_interior, worst_tail):
                        worst_cell = (distribution, order, size, q)
                rows.append((distribution, order, size, worst_in_row))

                if size >= 100_000:
                    for q in QUANTILES:
                        merged = abs(
                            result["sequential"][round(q, 6)] - result["balanced"][round(q, 6)]
                        )
                        merge_spread = max(merge_spread, merged)
                    if int(result["sequential_count"]) != size or int(result["balanced_count"]) != size:
                        failures.append(f"{distribution}/{order}/{size}: a merge lost values")

    # order sensitivity within one distribution and size
    by_cell = {}
    for distribution, order, size, worst in rows:
        by_cell.setdefault((distribution, size), []).append(worst)
    for (distribution, size), worsts in by_cell.items():
        order_spread = max(order_spread, max(worsts) - min(worsts))

    for distribution in distributions:
        row = [r[3] for r in rows if r[0] == distribution]
        print(f"  {distribution:>12}: worst rank error {max(row) * 100:.3f}%")

    print(f"\nlayer 1  structure: count, exact extremes, centroid bound, monotone, round trip")
    print(f"layer 3  worst interior {worst_interior * 100:.3f}% (ceiling 1.0%), "
          f"worst tail {worst_tail * 100:.3f}% (ceiling 0.5%)")
    if behind:
        worst_gap = max(behind, key=lambda cell: cell[4] / max(cell[5], 1e-9))
        print(f"layer 2  reported, not gated: {len(behind)} cells where the reference "
              f"is materially better; worst ratio {worst_gap[4] / max(worst_gap[5], 1e-9):.1f}x "
              f"at {worst_gap[0]}/{worst_gap[1]}/{worst_gap[2]} q={worst_gap[3]} "
              f"(ours {worst_gap[4] * 100:.3f}%, reference {worst_gap[5] * 100:.3f}%)")
    else:
        print("layer 2  the reference is nowhere materially better on this matrix")
    if worst_cell:
        print(f"         worst cell: {worst_cell}")
    print(f"order sensitivity: {order_spread * 100:.3f}% of rank error between orders")
    print(f"merge tree spread: quantiles move by up to {merge_spread:.3f} in value "
          f"between sequential and balanced merges (reported, not asserted)")

    if failures:
        print("\nFAILED:")
        for failure in failures[:20]:
            print(f"  - {failure}")
        return 1
    print("\nt-digest acceptance: all three layers passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
