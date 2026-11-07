# Kernel implementation record after 0.1.1

Updated 2026-10-26 (Asia/Shanghai), source revision `f0c6454`, released as
0.1.2 from `b1b2b7f`. K0 and the first deliveries of K1 through K6 are
implemented and published, so this record describes shipped code rather than a
candidate. The original task scope and acceptance rules below are retained, with
the outcomes identified. The original handoff and PLAIN experiment used
`9fdd252` as their baseline.

Start with [the follow-through record](NEXT-STEPS.md) for the release, consumer
and measurement state, and retain the
[roadmap's acceptance rules](ROADMAP.md#4-the-acceptance-system) and
[sketch contracts](SKETCHES.md).

## Completed deliveries

The bitmap dispatch separation landed in `9fdd252` (K0). The remaining
release and registry-consumer work follows the ordered plan in
[Next steps](NEXT-STEPS.md#release-order-and-ownership). Do not repeat these
implementations, the earlier bitmap rewrites, or SQL sketch adoption in
moonlake. Changing its accepted 0.6.0 candidate or dependency requires acceptance
on the resulting source again.

| Task | Implementation | Outcome and boundary |
|---|---|---|
| K1: PLAIN word loads | `cf91004`, `c68e39a` | Word loads for all four fixed-width numeric types and count checks without multiplication overflow; the full-width unpacker was not changed |
| K2: Dictionary budget during construction | `5df03c6` | Early `None` once the dictionary payload would pass the budget; accepted bytes unchanged |
| K3: Compact HLL state | `d497326` | Dense byte registers, snapshot `registers()` and allocation-free `register(index)`; sparse state deferred |
| K4: Roaring query APIs | `5163107` | Intersection count, overlap testing and stateless ordered batches; engine adoption still follows I0 |
| K5: t-digest compression and batch quantiles | `353e692` | Ordered centroid/buffer merge and cached lower scale values; batch queries were later measured and delivered in K7 |
| K6: Reusable FSST model | `3bb6ca0` | Immutable trained model and `encode_fsst_with`, retaining the existing self-contained frame |
| K7: Post-release CPU and query measurements | `9824a82`, `2f3278a`, `27a29a5` | HLL typed hashing, batch updates, `clz`, exact inverse powers and one-pass sparse deserialization; t-digest batch quantiles; sparse Roaring iteration. FSST symbol views and the DELTA body-buffer candidate were rejected with measured controls |

The [final benchmark record](NEXT-STEPS.md#final-benchmark-record) and
[scoreboard](scoreboard.md) contain the post-implementation measurements.
Sparse HLL, consumer FSST reuse and I0 are conditional follow-ups in
[Next steps](NEXT-STEPS.md#conditional-work-after-consumer-acceptance).
A negative measured result completes an investigation; it does not justify
changing an oracle.

## Shared delivery requirements

- Keep zero FFI, zero runtime dependencies, typed decoding errors and the current
  scope boundaries. SQL semantics, row identities, file I/O and planner decisions
  remain consumer responsibilities.
- Run `moon info && moon fmt`, inspect the generated interface changes, then
  `moon check --deny-warn` and `moon test` explicitly on native, wasm-gc and js.
  Run the affected byte-diff, property and interop gates named below. Validate
  public API changes with `harness/check_consumer.py` on the packaged artifact.
- Compare the unchanged baseline and candidate with identical input, toolchain,
  target, build mode and answer oracle. Include same-binary controls and alternate
  or counterbalance the order. Record source identity, medians and spread;
  distinguish serialized bytes, retained state and process peak RSS.
- Deliver the contract decision, implementation, relevant correctness results,
  repeatable performance record and remaining limitations together. Keep changes
  separable by task. Publication and release sequencing follow
  [Next steps](NEXT-STEPS.md#release-order-and-ownership).

## K7. Post-release CPU and query measurements

Delivered after 0.1.3 through PR #3, #4 and #5. Every candidate was measured
separately against an unchanged binary; a candidate that regressed a named
control beyond spread is recorded as closed rather than shipped.

- HLL typed values hash their canonical little-endian bits directly, rank uses
  `UInt64::clz`, and `2^-rank` is built from IEEE-754 exponent bits. Against
  `main`, one million updates in one group went 20.14 to 3.93 ms (-80.5%),
  1,000 groups of 1,000 updates 48.41 to 21.69 ms (-55.2%), and a full-sketch
  estimate 134.8 to 7.9 us (-94.2%).
- Five typed batch-update methods take `ArrayView` and keep a caller's hot loop
  inside the package. One million precomputed `Int64` values took 4.77 ms
  through single calls and 4.19 ms through the batch (-12.1%).
- Sparse HLL deserialization collects ordered entries in the first validated
  pass: 16.1 to 12.2 us (-24.2%), with dense `from_bytes` unchanged within
  noise. A small-state linear search was rejected after a 2.7% grouped-update
  regression.
- `TDigest::quantiles` finalizes once and reuses cumulative centers: 99 queries
  took 2.66 us through scalar calls and 1.09 us through the batch (-59.0%).
- Roaring sparse full batched iteration skips an empty lower-bound search:
  1.12 to 0.914 ms (-18.4%), with dense and run controls within 2%.

Two candidates were closed as negative results. FSST symbol-table views gave no
decode win and regressed several cases by 1 to 4%. A DELTA_BYTE_ARRAY continuous
body cut the target encode 9.16 to 5.80 ms (-36.7%), but the unchanged
DELTA_LENGTH_BYTE_ARRAY control regressed 2.78 to 2.97 ms (+6.9%). The
production encoders were left unchanged; `harness/perf families` and
`harness/perf delta` preserve the controls.

All delivered paths kept serialized bytes, hash and rank rules, estimator
contracts and error offsets unchanged. Three-backend tests, the affected
reference rigs and the packaged consumer passed. The published artifact remains
0.1.3, so these changes are unreleased.

## K1. PLAIN word loads

**Entry points:** [plain.mbt](../encoders/plain.mbt),
[bits.mbt](../primitives/bits.mbt), and
[PLAIN tests](../encoders/plain_wbtest.mbt).

The baseline `read_u64_le` assembled eight bytes per value. The isolated
experiment below replaced that loop with `BytesView::unsafe_read_uint64_le`
after range validation, retaining `Array::make(count, 0L)` and filling every
output. The production delivery uses word loads for Int64/Double and
Int32/Float, with a count check against `data.length() / width` before the load.
The full-width bit unpacker, allocation and SIMD were not changed.

*Outcome:* native release, 500k values, interleaved median-of-three comparisons:
Int64 1991 to 236 us, Double 1992 to 236 us, Int32 666 to 152 us and Float
678 to 152 us. wasm-gc also improved. The JS tests retain their existing NaN
class contract rather than claiming NaN payload preservation. Consumer
Parquet/spill measurements remain part of the release follow-through.

**Exit:**

- Preserve decoded values, little-endian layout, trailing-byte behavior and
  typed errors. Validate counts and byte ranges without multiplication overflow
  before any unsafe load. Cover empty and singleton input, short buffers,
  negative and excessive counts, extreme integers, unaligned views and the
  floating-point special values under the existing backend contracts.
- Keep affected property tests green on all three targets, and run the existing
  byte/container gates using their supported targets. Inspect `.mbti`; a
  load-only rewrite should change no public API.
- Repeat the microbenchmark and run PLAIN dataset cases, reader/writer interop
  and moonlake's relevant Parquet/spill workloads. Measure native and wasm-gc
  separately. The exploratory timing is not an end-to-end acceptance result.

## K2. Dictionary budget checked during construction

**Entry points:** [dictionary.mbt](../encoders/dictionary.mbt),
[dictionary tests](../encoders/dictionary_wbtest.mbt),
`harness/check_dict.py` and `harness/perf`.

The baseline built the complete dictionary and indices before checking
`max_dictionary_bytes`. The planners now track the PLAIN payload while adding
new values and return `None` as soon as the next entry would pass the limit.
Fixed-width types use entries times width; byte arrays use a running
`4 + length` total in 64 bits. Accepted dictionaries keep their bytes and order.

*Outcome:* refused columns on native release took 59.8 to 24.7 ms for 500k
distinct Int32 values and 22.3 to 6.9 ms for 200k strings; wasm-gc improved by
65% and 78%. Accepted low-cardinality Int32 results showed layout noise, so a
difference below 15% in that recorded case remains unresolved. The limit still
bounds dictionary payload rather than all input or index allocations.

**Exit:**

- Below or exactly at the limit, preserve insertion order, dictionary bytes,
  bit width and index bytes. Above it, return `None` with the same fallback
  meaning. Preserve negative-limit and unsupported-type errors.
- Test limits zero, exactly sufficient and one byte too small, repeated values,
  signed zero/NaN bit patterns, and long byte arrays. Count payload size without
  overflow. Keep `check_dict.py` and container interop green.
- Measure increasing unique inputs at fixed tiny and default budgets, and retain
  low-cardinality controls. Report time and peak RSS. The limit still bounds the
  dictionary payload, not all allocations or the caller's input array; this task
  does not introduce a streaming dictionary writer or an encoding selector.

## K3. Compact HLL state

**Entry points:** [hll.mbt](../sketches/hll.mbt),
[public sketch API](../sketches/pkg.generated.mbti),
[HLL contract](SKETCHES.md#hll-contract-v1), `harness/check_hll.py`, and
[moonlake's state-cost record](https://github.com/superbigcup325/moonlake/blob/main/docs/sketches.md).
The linked consumer branch may lag the local record.

The released 0.1.1 state used 16,384 Int32 registers at precision 14, or 64 KiB
of payload. The current state uses `FixedArray[Byte]`, or 16 KiB, with the same
precision, hash, rank rule, estimator and v1 bytes. In the library's native
grouped control, peak RSS fell from 96.7 to 25.0 MB for 1000 groups of 1000
values and from 428 to 109 MB for 5000 groups of 10. These are dense-state
results. The consumer measured the crossover those numbers were extrapolated
from: at 1,000 groups the dense sketch crosses the exact set near 200 distinct
values per group, and those figures are in its own record.

The delivery decisions and conditional next stage are:

1. Record how `registers() -> ArrayView[Int32]`, previously a non-copying live
   view, migrates. Do not claim the old cost for the new behavior.
   *Decision (implemented):* the signature is kept so existing callers compile,
   but the result is now a snapshot built per call (O(register_count) time and
   space) that no longer tracks later updates. The allocation-free read is the
   new `register(index)`, which returns an error for an out-of-range index.
   Callers that relied on a live view must re-read. This is documented on the
   accessor and in the changelog.
2. Byte registers are implemented with the same precision, hash, rank,
   estimator and v1 serialized bytes. Keep all precisions and
   merge/serialization identities covered.
3. Consider sparse-to-dense state only if the many-small-groups measurement
   still warrants it. Define promotion, merge combinations, allocation bounds
   and old-byte compatibility before coding. An exact-small-set state is a
   separate estimator/representation decision, not an incidental optimization.
   The measurement arrived and did warrant it: moonlake's H0 refresh found the
   per-group register array, not the sketch's CPU, dominating a grouped
   aggregate, and the two-state sketch shipped in 0.1.3.

The separate CPU experiment is complete: numeric hashing without scratch
buffers, typed batch updates, `UInt64::clz`, exact inverse powers and one-pass
sparse deserialization are delivered in [K7](#k7-post-release-cpu-and-query-measurements).
Each change was measured separately while hashes, registers, estimates and
bytes stayed stable. The kernel already accepts a precision parameter; exposing
one in SQL remains moonlake work.

**Exit:** the existing HLL statistical, algebra and malformed-state groups pass;
all three targets retain the promised bytes and merge ownership. Record update,
estimate, merge, serialized size and RSS separately, using few large groups,
many small groups, duplicates and promotion-boundary cases if sparse state is
selected. The consumer's crossover against exact state was refreshed by H0 and
lives in its own record; the sparse state met that exit in 0.1.3.

## K4. Roaring query APIs

**Entry points:** [roaring.mbt](../encoders/roaring.mbt), its property/whitebox
tests, `harness/check_roaring.py`, `harness/check_roaring_ops.py` and
`harness/perf`. [CRoaring's public API](https://github.com/RoaringBitmap/CRoaring/blob/master/include/roaring/roaring.h)
provides an independent reference for count-only and iterator operations.

`intersection_cardinality` and `intersects` now answer the count and overlap
questions without building the intersection. Counts remain `Int32`, matching
`cardinality`. `intersects` stops at the first shared ID.
`ids_after(after, limit)` returns ascending IDs beyond an Int64 cursor,
starting at `-1L`, and keeps no mutable iterator state. Continue from the last
returned ID; for a positive limit, a short batch means exhaustion. A zero or
negative limit returns an empty array. Each call reads the current bitmap,
and returned arrays do not alias it.

*Outcome:* native release medians of three put bitmap intersection count at
3.45 us against 14.0 us for materializing the result. The first 4096 IDs of a
1M-ID bitmap take 4.3 us against 907 us for expanding all IDs. Full batched
iteration is faster on dense containers but 14% slower on the sparse 1M-ID
array case, because each batch re-locates its key. Do not assume every iterator
workload wins. Engine use still needs I0's ownership and selection contract.

**Exit:** compare counts with materialized intersections and an independent set
oracle, overlap tests with count > 0, and concatenated batches with `to_array`.
Cover empty/disjoint/identical sets, array/bitmap/run container combinations,
4096/4097 boundaries, maximum supported IDs and operand independence. Preserve
portable bytes and existing operation-sequence gates. Measure count, existence,
full iteration and early stop separately across selective and unselective sets.

Tie engine integration to I0's immutable-table workload. Row-selection scans,
stale-index handling and reduced Parquet decoding need the consumer contract;
faster set computation does not establish those gains. AND-NOT/XOR, range
operations and wider IDs remain follow-ups to a demonstrated workload.

## K5. t-digest compression and batch quantiles

**Entry points:** [tdigest.mbt](../sketches/tdigest.mbt),
[t-digest contract](SKETCHES.md#t-digest-contract-v1) and
`harness/check_tdigest.py`.

The original scope was to profile the sorted `(mean, weight)` list, its split
into arrays, the extra arrays on reverse passes, and repeated scale evaluation
in the inner compression loop. It called for trying buffer reuse, merging an
ordered centroid list with the sorted raw buffer, and cached scale values
before altering k1 or compression 100. Retain
tie ordering and alternating sweep behavior; array reuse must not mutate merge
operands or alias the returned digest.

The query API considered was `quantiles(qs)`: finalize once and
walk the centroid weights for several ranks. Specify invalid-q behavior, empty
input, output order and duplicate q values before coding. Compare it with scalar
queries on the same finalized state. Sharing one digest across SQL aggregates
is a separate moonlake change.

*Outcome of the first delivery:* the compression pass now sorts only the raw
buffer and merges it with the ordered centroids, and computes each centroid's
lower scale value once; the centroid list is identical to the old one. On the
perf rig a 1M-value update stream went from 88.5 to 51.9 ms and a merge from
3.7 to 2.5 us (native release, medians of three). `quantiles(qs)` was deferred
at that point because 99 scalar queries took about 2.3 us and no query-bound
consumer had been demonstrated. A later same-binary measurement showed that a
shared finalize and cumulative centers still cut 99 queries from 2.66 to
1.09 us, so the batch API was delivered in K7 with an explicit contract.

**Exit:** retain structural invariants, exact extremes, serialization checks,
the named distribution/order/merge-tree matrix and its existing absolute
rank-error ceilings. Report update, compression, merge, scalar/batch query time,
centroids, bytes and RSS separately. Do not use a throughput win to hide worse
tail accuracy. k2/k3, weighted updates and CDF queries require their own consumer
case and contract; they are not part of this first task.

## K6. Reusable FSST model

**Entry points:** [fsst.mbt](../encoders/fsst.mbt), its snapshot/property tests,
`harness/check_fsst.py` and the string variants in `harness/perf`.

`encode_fsst` still trains a symbol table on its own batch. The new immutable
`FsstModel` and `encode_fsst_with` let callers train once and reuse that table
across batches, retaining the existing frame and raw fallback. Models own their
table; each output frame carries it, so decoding needs no external model.
Equality of compressed strings requires the same table, not just the same
input bytes. Export/import and shared-table frames remain conditional work.

**Exit:** compare one-shot training and reused training on low-cardinality,
prefix-heavy, high-cardinality text and changing distributions. Include training
and table bytes in the amortization calculation and measure held-out batches.
Retain round trips, malformed-input checks, arbitrary byte strings and old-frame
readability on all three targets. FSST remains a colenc-owned format, with no
claim of Parquet-native or upstream byte compatibility. Selected-value decoding
can follow if a consumer can use it; stop if reuse does not pay.

*Outcome of the first delivery:* training dominates small batches, so reuse pays.
On native release, 100 low-cardinality values cost 39.5 us with fresh training,
of which training is 36.6 us and matching 2.8 us. Held-out batches encoded 2.7 to
41 times faster per value with a reused model across low-cardinality,
prefix-heavy and high-cardinality text at 100 to 20000 values (the smallest gain
is high-cardinality text at 20000 values, 2125 to 791 ns per value; the largest
is prefix-heavy text at 1000 values, 1515 to 36 ns). The frame is unchanged and
every batch still carries its table (648 to 1842 bytes here), so `decode_fsst`
and old frames are unaffected and nothing needed a new version. Compressed size
on a held-out batch is data dependent: the reused model was 0.7% to 7.0% larger
at 100 to 1000 prefix-heavy or high-cardinality values, equal on low-cardinality
and 20000 high-cardinality values, and 14% smaller at 20000 prefix-heavy values.
An export/import format for the table, a table shared across frames and
selected-value decoding were not built: they need a consumer that keeps a model
between batches, and the model's lifetime and drift policy belong to that caller.

## Exploratory PLAIN record

The [self-contained record](plain64-probe-2026-10-26.json) preserves the exact
probe source, package imports, hashes, machine/toolchain identity and every
summary emitted by `core/bench`. It depends on no local-only path.

Both variants ran in the same executable per target, in A/B/B/A order, seven
samples per case. The 4,000,000-byte input contains 500,000 varied Int64 values
and signed extremes. Every decoded value was checked against the input and the
other path; empty input was checked too. Both target runs exited zero.

| Target | Bytewise case medians | Word-load case medians | Ratio of mean case medians |
|---|---|---|---|
| native | 1574.137 / 1581.807 us | 251.801 / 253.274 us | 6.25x |
| wasm-gc | 5280.795 / 4949.134 us | 2312.676 / 2206.760 us | 2.26x |

These are resident-memory Int64 kernel timings from a release build, including
equal result-array allocation, not a release scoreboard or a Parquet query.
JavaScript, malformed inputs, full library/consumer acceptance and RSS were not
measured in this probe. CPU affinity, frequency traces and individual trial
observations were not captured. These summaries belong to one final process per
target; speedups must be measured again for a production patch.

To reproduce, use a separate checkout/copy of the baseline library `9fdd252`
with the recorded toolchain. If only a newer toolchain is available, identify
it and remeasure both variants; do not compare that run directly with this table.
Copy the linked record into its `docs/` directory, then create the probe from
the stored files. The candidate is experiment code that aborts on invalid probe
input; it is not the proposed production error API.

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib
import json

record = json.loads(Path("docs/plain64-probe-2026-10-26.json").read_text())
probe = Path("harness/plain64_probe")
assert not probe.exists(), "use a fresh comparison directory"
probe.mkdir(parents=True)
for name, source in record["probe"]["files"].items():
    assert hashlib.sha256(source.encode()).hexdigest() == record["probe"]["sha256"][name]
    (probe / name).write_text(source)
PY
moon run --target native --release harness/plain64_probe
moon run --target wasm-gc --release harness/plain64_probe
```

Use the normal fresh-checkout dependency setup when needed. Compare production
patches against the unmodified baseline; once `decode_int64` itself uses word
loads, this probe's `bytewalk` wrapper is no longer an unchanged control.

## Final reminder: update benchmarks

The colenc scoreboard was regenerated and the affected sketch and bitmap costs
were recorded after K1 to K6 landed, in the
[final record](NEXT-STEPS.md#final-benchmark-record). The moonlake end-to-end
baseline is recorded as well: that project re-ran `harness/bench_release.py` on
the registry dependency against a 0.1.1 control at `4de8077`, three alternating
pairs on a quiet host, and the wide CSV cases came out 6-11% in 0.1.2's favour
with the two Parquet cases unresolved. Keep the exploratory record separate from
those acceptance results.
