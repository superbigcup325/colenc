# Next steps after the Roaring implementation

Planning snapshot: 2026-10-25, tree revision `3514ad1` (the code it carries is
`c08cad8`).

The next sequence is to finish the 0.1.1 release candidate, measure Roaring's
query operations, validate an engine use case, then develop HLL before
t-digest. The [roadmap](ROADMAP.md) remains the source of the existing
acceptance criteria. The sketch contracts below are proposals to settle
before implementation; they do not change the E0–E8 criteria.

## Evidence and current position

- The roadmap records P0–P6 as implemented, including the original moonlake
  integration and the Roaring bitmap. The manifest carries version 0.1.1;
  the release text still identifies 0.1.0 as the published version. The registry
  was checked: it carries 0.1.0 alone (published 2026-10-19), so 0.1.1 is
  unpublished and there is no earlier artifact to reconcile.
- The changelog and implementation already include the sorted bitmap build,
  container-array reservation, cursor-based parsing, bulk body reads,
  serialization planning and removal of redundant container zero-filling.
  The old roadmap's next allocation investigation has been superseded.
- The [scoreboard](scoreboard.md) contains measurements for revision
  `0cb57e9`. Its numbers were not rerun for this plan. Roaring's timed decode
  path in `harness/bench/main.mbt` calls `from_bytes` and `cardinality`;
  `to_array` is only in the correctness check outside that timer. The reported
  MB/s uses the equivalent raw INT32 id size as its numerator and does not
  measure expansion to an id array.
- Matching-key union and intersection currently convert both containers to
  bitmap words. `container_of_words` then enumerates the result values even
  when the result remains a bitmap. These are candidates for measurement;
  this inspection establishes no performance gain from changing them.

This pass inspected documentation, APIs and relevant implementation paths.
It did not rerun the test suite, acceptance harness, benchmarks or moonlake
regressions, and it did not establish release readiness.

## Work order

| Package | Deliverable | Dependency |
|---|---|---|
| A | Verified 0.1.1 release candidate and separate registry acceptance | Current E0–E8 implementation |
| B | Roaring query measurements and justified container-specific rewrites | A |
| C | A measured Roaring use case in moonlake | B |
| D | HLL contract, acceptance rig and implementation | C; record the sketch decisions before coding |
| E | t-digest contract, empirical accuracy rig and implementation | D; settle quantile criteria before coding |

## A. Finish the 0.1.1 release candidate

Entry points: [manifest](../moon.mod), [changelog](../CHANGELOG.md),
[CI](../.github/workflows/ci.yml),
[consumer check](../harness/check_consumer.py), and
[harness instructions](../harness/README.md).

1. Verify the live registry version and reconcile the manifest, changelog and
   release status. A dated changelog heading alone does not establish that a
   registry artifact exists.
2. On the selected candidate revision, run the pre-commit quartet, the tests on
   all three backends (native, wasm-gc and JS), and all fixture, byte-diff,
   operation-sequence and container checks defined in CI. Record the revision
   and toolchain with the results.
3. Inspect `moon package --list`, then run
   `python3 harness/check_consumer.py`. Record the archive hash and the three
   backend outcomes separately from the working-checkout results.
4. After an explicitly authorized publication, run
   `python3 harness/check_consumer.py --registry-version 0.1.1`. If that
   version already exists, check it before planning another publication.

**Exit:** the exact candidate passes the existing gates, its archive contains
only publishable material, and its packaged API works on native, wasm-gc and
JS. Registry acceptance is a separate post-publication result. Do not describe
the archive check as registry verification or the small consumer probe as
moonlake regression coverage.

## B. Measure and improve Roaring query operations

Entry points: [bitmap implementation](../encoders/roaring.mbt),
[performance rig](../harness/perf/main.mbt),
[scoreboard benchmark](../harness/bench/main.mbt), and
[scoreboard generator](../harness/scoreboard.py).

Extend the existing rig instead of introducing another benchmark framework:

- Report `from_bytes`, `to_array`, and the combined parse-and-expand path
  separately. Keep elapsed time alongside throughput, with each numerator
  named explicitly.
- Exercise `contains` hits and misses, and union/intersection across array,
  bitmap and run containers. Cover disjoint, partially overlapping and
  identical sets, small and large results, and narrow and wide key spans.
- Keep model checks outside timing, consume timed results, and abort on
  errors. Record revision, toolchain, dataset shape and measurement spread.

Measure these rewrites in order:

1. Merge sorted arrays directly for array/array operations.
2. For bitmap/bitmap results, use popcount to choose the output shape and
   enumerate values only when an array result is required.
3. Investigate mixed-container and run paths if the measurements identify
   them as material costs. A count-only intersection API is a separate
   candidate if the consumer workload needs it.

**Exit:** each accepted rewrite has same-machine, interleaved control and
candidate measurements on native and wasm-gc. All three backends retain the
semantic and boundary coverage. `check_roaring.py` still matches the reference
bytes for its specified paths; `check_roaring_ops.py` still establishes legal
containers, round trips and operand independence for the other sequences.
Publish no speedup claim that the measurement spread cannot resolve.

## C. Validate a Roaring use case in moonlake

Entry points: [moonlake](https://github.com/superbigcup325/moonlake), the
current bitmap API, and the consumer's existing regression suite.

First inspect the consumer's current revision and determine whether an E8
path already exists. The documented P5 integration covers the earlier page
encodings and does not by itself establish bitmap-index integration.

Choose one real workload, such as combining predicate id sets for filtering
or counting an intersection. Keep row-id mapping, NULL semantics, index
lifetime, persistence and query planning in the consumer; colenc continues
to operate on in-memory buffers and sets.

Compare with an exact full-scan control on the same data. Record result
equality, query latency, index build/load time, memory and stored size. Include
selective and unselective predicates so the index overhead is visible.

**Exit:** the consumer regression remains green and the chosen workload has
reproducible correctness and cost evidence. If it shows no useful tradeoff,
record that result before adding more bitmap APIs.

## D. Define and implement HLL

Use a dedicated sketch API. HLL summarizes distinct counts and cannot restore
the original column, so a reversible `encode_column` / `decode_column`
contract does not describe it.

The contract is recorded in [sketches](SKETCHES.md): variant and estimator,
input canonicalization and hash, precision range, merge and ownership rules,
the serialization decision, the statistical acceptance groups, what is explicitly
not claimed, and the pinned test-time reference. This package therefore starts
from implementation, not from another design pass.

Before implementation, record:

- The HLL variant, estimator and pinned test-time reference implementation.
- Input hashing, including either a pre-hashed `UInt64` boundary or canonical
  typed input bytes, the hash algorithm and seed, and ownership of NULL and
  floating-point normalization.
- Precision range, memory budget, merge compatibility, incompatible-input
  errors, operand ownership, and serialization version and byte order.
- Whether serialization follows a named reference format or a colenc-owned
  format. Estimate agreement alone cannot establish byte compatibility.
- The statistical acceptance protocol: cardinality ranges, trial count,
  deterministic seeds, bias, relative error distribution and failure
  thresholds. Set the thresholds before measuring the implementation.

Build the acceptance rig first, then the implementation and consumer-facing
example. Check duplicate updates, empty inputs, state round trips, malformed
bytes, merge behavior and backend consistency. State the merge laws supported
by the selected variant and test its register state separately from its
estimator. Measure accuracy against exact distinct counts across multiple
trials; a standard error is not a hard limit for every individual sample.

**Exit:** the recorded contract and statistical gates pass on the three
backends, the reference comparison is reproducible, and update/merge/query
cost and sketch size are reported separately. The reference stays a test-time
judge, preserving zero FFI and zero runtime dependencies.

Reference: [Apache DataSketches HLL overview](https://datasketches.apache.org/docs/HLL/HllSketches.html).
Select the specific variant before adopting its estimator or accuracy figures.

## E. Define t-digest's empirical accuracy criteria

Start with a design and acceptance document. Select a pinned reference,
compression parameter, centroid rules, merge policy, serialization contract
and behavior for empty input, repeated values, invalid quantiles, NaN and
infinities.

Specify the quantile and rank conventions, including ties. Use exact sorted
data as ground truth. Test central and tail quantiles on uniform, skewed,
heavy-tailed and duplicate-heavy datasets, with ascending, descending and
shuffled input. Compare single-pass construction with sequential, balanced
and unbalanced merge trees. Set empirical rank-error thresholds and memory
limits for the named test matrix before implementation.

**Exit:** the agreed empirical matrix passes, state serialization and malformed
input handling are covered, and the report states sensitivity to data order
and merging. Keep proven structural invariants separate from measured
accuracy; this plan makes no universal numerical error-bound promise.

References: [Apache DataSketches t-digest overview](https://datasketches.apache.org/docs/tdigest/tdigest.html)
and the [author's reference implementation](https://github.com/tdunning/t-digest).

## Scope carried forward

Byte-stream compression, full nested levels, a public Parquet container API
and SIMD remain deferred under the roadmap. The next performance work is
driven by measured query costs, and new sketch families begin with recorded
contracts and acceptance criteria.
