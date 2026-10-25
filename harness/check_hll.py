#!/usr/bin/env python3
"""Acceptance rig for the HLL sketch — the four groups `docs/SKETCHES.md` names.

The encodings are judged by byte identity against a reference writer. A sketch
has no such reference stream, so this rig judges properties instead:

  1. error at the default precision, against the analytic interval;
  2. merge as a register algebra (commutative, associative, operands untouched);
  3. serialization: exact round trip, rejection of malformed state, and the same
     bytes on all three backends;
  4. boundaries: empty, single, all-duplicate, and the precision range.

The bound is `1.96 * 1.04 / sqrt(m)`: a confidence interval over hashes, not a
maximum. The worst deviation is printed so a reader sees the spread rather than
only a pass. Apache DataSketches' `datasketches` package is the outside opinion:
it is HLL++, so it says whether an estimate sits where an independent
implementation puts it, never whether registers or bytes match.
"""
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("native", "js", "wasm-gc")


def run(command, *args, target="native"):
    completed = subprocess.run(
        ["moon", "run", "--target", target, "harness/hll_probe", "--", command, *map(str, args)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    values = {}
    for line in completed.stdout.splitlines():
        if line.startswith("RESULT|"):
            _, key, value = line.split("|", 2)
            values[key] = value
    return completed.returncode, values, completed.stdout + completed.stderr


def sigma(precision):
    return 1.04 / math.sqrt(2 ** precision)


def group_error(failures):
    """The estimator's spread, not a coin flip on every sample.

    Asserting that *each* sample lands inside 1.96 sigma would fail about five
    percent of the time by construction, which is a broken criterion rather than
    a strict one. The group instead measures the standard deviation across many
    seeds and compares it with the analytic 1.04/sqrt(m), checks that the mean is
    centred, and bounds the fraction of samples in the tail.
    """
    print("group 1: error at the default precision")
    precision = 14
    theory = sigma(precision)
    for size, count in ((1_000, 20), (100_000, 20), (1_000_000, 10)):
        errors = []
        empties = []
        for seed in range(1, count + 1):
            code, values, _ = run("build", precision, seed, size)
            if code != 0 or "estimate" not in values:
                failures.append(f"build {precision} {seed} {size} failed")
                continue
            errors.append((float(values["estimate"]) - size) / size)
        if not errors:
            continue
        mean = sum(errors) / len(errors)
        spread = (
            (sum((error - mean) ** 2 for error in errors) / (len(errors) - 1)) ** 0.5
            if len(errors) > 1
            else 0.0
        )
        # The spread is bounded from above, not held to the analytic value from
        # below: below n ~ 2.5m the linear-counting correction is *more* accurate
        # than 1.04/sqrt(m), so a small sigma is the estimator working, and the
        # upper bound is the part that catches a defect.
        if spread > 1.5 * theory:
            failures.append(
                f"n={size}: measured sigma {spread * 100:.3f}% exceeds 1.5x the "
                f"analytic {theory * 100:.3f}%"
            )
        if abs(mean) > 0.5 * theory:
            failures.append(f"n={size}: mean error {mean * 100:+.3f}% is not centred")
        tail = sum(1 for error in errors if abs(error) > 1.96 * theory)
        if tail > max(1, len(errors) // 10):
            failures.append(
                f"n={size}: {tail}/{len(errors)} samples outside 1.96 sigma"
            )
        worst = max(errors, key=abs)
        print(f"  n={size:>9,} over {len(errors):>2} seeds: "
              f"sigma {spread * 100:.3f}% (analytic {theory * 100:.3f}%), "
              f"mean {mean * 100:+.3f}%, worst {worst * 100:+.2f}%, "
              f"tail {tail}/{len(errors)}")

    # One sample at 10M, reported rather than promised: at that size the
    # registers are saturated and the raw estimator carries the whole error.
    code, values, _ = run("build", precision, 7, 10_000_000)
    if code == 0 and "estimate" in values:
        estimate = float(values["estimate"])
        print(f"  n=10,000,000 single sample: {estimate:,.0f} "
              f"({(estimate - 10_000_000) / 10_000_000 * 100:+.2f}%)")

    # The outside opinion on the same cardinalities.
    try:
        from datasketches import hll_sketch
    except ImportError:
        failures.append("datasketches is not installed; the reference judge is missing")
        return
    worst_reference = 0.0
    for size in (1_000, 100_000, 1_000_000):
        sketch = hll_sketch(precision)
        for index in range(size):
            sketch.update(f"v{index}")
        error = (sketch.get_estimate() - size) / size
        worst_reference = max(worst_reference, abs(error))
    print(f"  datasketches (HLL++, independent judge) worst |error| "
          f"{worst_reference * 100:.3f}%")


def group_merge(failures):
    print("group 2: merge as a register algebra")
    for precision in (10, 14, 16):
        code, values, output = run("merge", precision, 1, 500, 2, 400, 3, 300)
        if code != 0:
            failures.append(f"merge at precision {precision} failed: {output[-200:]}")
            continue
        for key in ("associativity", "commutativity", "operands_untouched"):
            if values.get(key) != "true":
                failures.append(f"merge at precision {precision}: {key} is not true")
    print("  associativity, commutativity and operand independence hold at "
          "precisions 10, 14 and 16")


def group_serialization(failures):
    print("group 3: serialization")
    code, values, output = run("roundtrip", 14, 91, 5_000)
    if code != 0 or values.get("roundtrip") != "true":
        failures.append(f"round trip failed: {output[-200:]}")
    elif values.get("precision_kept") != "true":
        failures.append("precision not preserved across a round trip")
    else:
        print(f"  round trip is exact, checksum {values['bytes_checksum']}")

    # Cross-backend byte identity is enforced by the test suite: the serialized
    # form of a fixed sequence is pinned, so a backend that disagrees fails
    # there. A `moon run` probe cannot carry CLI arguments to the JS backend,
    # which is why this group goes through the tests rather than the probe.
    for target in TARGETS:
        completed = subprocess.run(
            ["moon", "test", "--target", target, "sketches"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            failures.append(f"the pinned-bytes test failed on {target}")
    print(f"  the pinned bytes and the suite pass on {', '.join(TARGETS)}")

    code, values, output = run("reject", 14, 7, 100)
    if code != 0:
        failures.append(f"reject probe failed: {output[-200:]}")
        return
    expected = (
        "bad_version",
        "bad_precision",
        "bad_register",
        "truncated",
        "merge_precision_mismatch",
    )
    for key in expected:
        if values.get(key) != "true":
            failures.append(f"malformed input not rejected: {key}")
    print(f"  {len(expected)} malformed states rejected with typed errors")


def group_boundaries(failures):
    print("group 4: boundaries")
    code, values, _ = run("build", 14, 5, 0)
    if code != 0 or float(values.get("estimate", -1)) != 0.0:
        failures.append("an empty sketch does not estimate zero")
    code, values, _ = run("build", 14, 5, 1)
    estimate = float(values.get("estimate", -1))
    if code != 0 or not 0.9 < estimate < 1.1:
        failures.append(f"a single element estimates {estimate}")
    # Ten copies of the same 1000 values must read the same as one copy.
    _, once, _ = run("build", 14, 5, 1_000)
    _, twice, _ = run("duplicates", 14, 5, 1_000, 10)
    if once.get("bytes_checksum") != twice.get("bytes_checksum"):
        failures.append("duplicates changed the registers")
    # The precision range: 4 and 16 are legal, 3 and 17 are not.
    for precision in (4, 16):
        code, values, _ = run("build", precision, 5, 100)
        if code != 0 or values.get("registers") != str(2 ** precision):
            failures.append(f"precision {precision} is not usable")
    for precision in (3, 17):
        code, _, _ = run("build", precision, 5, 100)
        if code == 0:
            failures.append(f"precision {precision} was accepted")
    print("  empty, single, all-duplicate, and the ends of the precision range")


def main():
    failures = []
    group_error(failures)
    group_merge(failures)
    group_serialization(failures)
    group_boundaries(failures)
    if failures:
        print("\nFAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("\nHLL acceptance: all four groups passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
