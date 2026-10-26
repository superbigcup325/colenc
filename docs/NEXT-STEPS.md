# Release and consumer follow-through after 0.1.1

Planning snapshot: 2026-10-26 (Asia/Shanghai), source revision `f0c6454`.
K0 and the first deliveries of K1 to K6 are implemented on remote `main` and
unreleased. The library scoreboard is updated. The next work is release
preparation, registry verification and moonlake acceptance against that release.
The [implementation record](OPTIMIZATION-PLAN.md) preserves the completed kernel
tasks; do not start them again. The [roadmap](ROADMAP.md) and
[sketch contracts](SKETCHES.md) retain their acceptance definitions.

## Current evidence

| Project | Observed state | Planning implication |
|---|---|---|
| colenc | [0.1.1 is published](https://github.com/superbigcup325/colenc/releases/tag/v0.1.1). Local and remote `main` were both `f0c6454`, 23 commits after that tag, with a clean working tree at inspection. [CI passed on that source](https://github.com/superbigcup325/colenc/actions/runs/40286538784), including the three targets and the full harness; the local recheck also passed 165 tests per target, format and `check --deny-warn` | The kernel changes are implemented and checked, but no registry artifact carries them. A versioned candidate still needs the migration and packaged-surface work below |
| Release artifact | Built from `504092a`; the tagged tree adds documentation and sketch coverage to the archive consumer, with identical library code. The release records three-target registry-consumer acceptance | Distinguish the registry artifact from its later documentation. Its older README wording does not mean HLL/t-digest are absent |
| moonlake | Local `6963e3b` still declares colenc 0.1.1 and module version 0.6.0, without a sibling override. It carries `approx_count_distinct` and `approx_quantile`. Remote `main` is `750b98c`; the latest [release is 0.5.0](https://github.com/superbigcup325/moonlake/releases/tag/v0.5.0) | The completed SQL adoption is not new kernel work. The upstream improvements need a published dependency and a fresh consumer candidate |
| Prior consumer acceptance | R2 accepted `bc1a8f5` with colenc 0.1.1: 361 native / 348 wasm-gc / 348 js tests, golden and differential gates, corpus 17 decoded / 51 refused / 0 failing, the 2.41 GB write, Chromium 16/16 and fresh-cache archive consumers. These are the recorded results, not a new consumer run in this planning update | Changing the dependency requires acceptance again. The older accepted source and the remote branch do not certify the resulting candidate |
| Measurements | The final [scoreboard](scoreboard.md) was regenerated at `26fb9c0`, after K1 to K6. The sketch and bitmap costs are in the [final record](#final-benchmark-record). Worst encode swing was 14% native and 23% wasm-gc | The library benchmark step is complete. The end-to-end registry-consumer baseline is pending; compare candidates with same-session controls |

**K0 has a measurable case now.** moonlake recorded its 0.6.0 candidate beside
same-session controls and found wide CSV scans about 10% slower than before the
upgrade (7–14% by run), where the CSV path never touches colenc. Its bisect puts
the cost on the dependency artifact (a commit that only changes the manifest is
9.4% slower), and two local probes say what carries it: one deletes
`encoders/roaring.mbt` and refuses the facade arms, the other keeps the file and
only refuses the arms; both build the same 1,632,744-byte consumer binary and
both return to the control's speed. So the cost is reachability from the generic
`encode_column` / `decode_column` dispatch that the consumer's spill format
calls, not the bitmap's package. Moving the file would not have helped; taking
the `Roaring` arms out of that dispatch into dedicated functions should, and the
consumer workload is already measurable the way this needs (a rotating
interleaved A/B, not one run). That change is implemented and measured: the downstream
consumer built against it is at control speed (157.9 ms against 163.0 ms median
for the scan, i.e. parity within the run spread) and 8,248 bytes smaller, so the
remaining step is a release decision plus the consumer's re-record, not another
experiment.

The separate Int64 load experiment remains in its
[source and timing record](plain64-probe-2026-10-26.json), with
[reproduction instructions](OPTIMIZATION-PLAN.md#exploratory-plain-record).
It is historical kernel evidence, not registry-consumer acceptance. The engine
work order and its exit criteria are maintained in
[moonlake's roadmap](https://github.com/superbigcup325/moonlake/blob/main/docs/ROADMAP.md).
That public branch may lag the local planning revision until it is pushed.

## Release order and ownership

**Version: 0.1.2, by the maintainer's decision to stay on 0.1.x.** The generic
facade now refuses Roaring, and `HllSketch::registers()` returns a snapshot
rather than a live view. These are observable compatibility changes, even though
the serialized formats stay the same; semantic versioning would call them a
minor bump, so the changelog carries a migration section at the top of the
release. The release is authorized.

Follow L0, L1, L2, C1 and C2 in order. Prepare the source and evidence before
the external release actions. The maintainer authorized push, tag and publish of 0.1.2 and the
moonlake upgrade; a moonlake release stays separate. Keep conditional
investigations out of this candidate.

| Package | Owner and delivery | Exit |
|---|---|---|
| L0 | colenc: complete migration notes and the packaged API coverage | Cover the dedicated Roaring facade and its generic refusal, the new bitmap query methods, HLL `register` and snapshot behavior, and FSST model training/reuse through public imports. The archive consumer passes on native, wasm-gc and JS |
| L1 | colenc: prepare the versioned candidate and its artifact | Set the agreed version in the manifest/changelog, refresh interfaces and format, run the full library and harness gates, inspect `moon package --list`, and run the consumer against the retained archive. Record source, archive SHA-256 and toolchain together |
| L2 | colenc: publish and verify the registry copy after release authorization | The pushed candidate has green CI; tag, release notes and the published package identify the same final source. `python3 harness/check_consumer.py --registry-version <version>` passes with fresh caches on all three targets |
| C1 | moonlake: consume that registry version and repeat candidate acceptance | Fresh dependency resolution without a workspace override; all current release gates pass on the resulting source, including encoding/writer/spill, sketches, corpus, large-file, browser and archive checks. Record the new revision and actual counts |
| C2 | moonlake: record the final consumer baseline and release evidence | Re-record `harness/bench_release.py` and the wide-CSV/fanout interleaved comparison, retain the exact-answer checks and same-session controls, and update `docs/bench-baseline.md`. Re-measure grouped HLL memory and the exact-state crossover. Remote CI/nightly must certify the pushed candidate before its separately authorized release |

L0 has a specific gap to close. The current archive consumer exercises the
dedicated bitmap facade, its generic-dispatch refusal and basic sketch round
trips. It does not call `FsstModel`, `encode_fsst_with`, `HllSketch::register`,
`intersection_cardinality`, `intersects` or `ids_after`. Extend
`harness/consumer/main.mbt` and its checker together. Check a model on its
training batch and a held-out batch, a retained HLL snapshot after later
updates, and concatenated bitmap batches against an independent expected set.
Keep old-format and one-shot byte compatibility under the existing library
tests and judges; the smoke consumer does not replace those gates.

L1 keeps the existing acceptance definitions. Run
`moon info && moon fmt && moon check --deny-warn`, then `moon test` on native,
wasm-gc and JS, plus every harness step in the CI workflow. Preserve the actual
archive used for `python3 harness/check_consumer.py --archive <path>` and
inspect its contents before publication. A changed source or artifact needs
the affected verification again. Do not repeat the 0.1.1 split between the
registry artifact and a later tagged documentation tree.

C2 must show whether the registry build removes the measured CSV cost; the
earlier local workspace probe does not establish that result. Carry forward
the scan, join, gather and spill controls, binary/data identities, output
oracles, RSS and run spread. Report an unresolved regression as such rather
than replacing the control with a more convenient historical record.

## Completed kernel deliveries

The [implementation record](OPTIMIZATION-PLAN.md) retains the original task
scope, compatibility decisions, acceptance rules and exploratory probe. These
deliveries are complete on `main`; publication and consumer evidence follow the
sequence above.

| Task | Implemented delivery | Remaining boundary |
|---|---|---|
| K0 | Dedicated Roaring facade; generic dispatch refuses the set encoding | Migration and registry-consumer confirmation |
| [K1](OPTIMIZATION-PLAN.md#k1-plain-word-loads) | Validated word loads for Int64/Double and Int32/Float, with overflow-safe count checks | Consumer Parquet/spill measurements; no SIMD or unpacker rewrite is implied |
| [K2](OPTIMIZATION-PLAN.md#k2-dictionary-budget-checked-during-construction) | Stop dictionary construction when its payload would exceed the limit | Accepted bytes and `None` fallback remain unchanged |
| [K3](OPTIMIZATION-PLAN.md#k3-compact-hll-state) | Dense byte registers, snapshot accessor and allocation-free `register(index)` | Sparse state and the refreshed SQL crossover remain separate work |
| [K4](OPTIMIZATION-PLAN.md#k4-roaring-query-apis) | Intersection count, overlap predicate and stateless `ids_after` batches | I0 still owns engine integration and selection semantics |
| [K5](OPTIMIZATION-PLAN.md#k5-t-digest-compression-and-batch-quantiles) | Merge the sorted buffer with ordered centroids and cache lower scale values | Batch quantiles were deferred after measurement; k1 and accuracy ceilings remain unchanged |
| [K6](OPTIMIZATION-PLAN.md#k6-reusable-fsst-model) | Immutable reusable model; every batch retains the existing self-contained frame | Caller-owned lifetime and drift policy; no shared-table frame or model export format |

## Conditional work after consumer acceptance

Start with the new consumer baseline. Promote one bounded investigation when
its workload demonstrates the need; no additional kernel blocks L0 to C2.

| Priority | Investigation and owner | Entry evidence | Delivery and stop condition |
|---|---|---|---|
| 1 | Sparse HLL state, colenc with a moonlake workload | Many small groups remain a material memory cost after compact-state adoption. The library's dense control still reaches 109 MB peak RSS for 5000 groups of 10 values | Compare dense state with a sparse representation of the same registers; decide promotion and merge rules before implementation. Preserve hash, rank, estimator and v1 bytes, and measure actual RSS/update/merge costs across group sizes. An exact-small-set estimator is a separate decision; retain dense state if the tradeoff does not pay |
| 2 | FSST model reuse in a consumer, moonlake | Repeated small string batches with a stable enough distribution and training visible in the profile | One opt-in workload with a bounded model lifetime and held-out/drifting batches. Report training amortization, table bytes per frame, encode/decode time, memory and fallback behavior. Keep one-shot behavior available; defer export/shared-table formats unless this caller needs them |
| 3 | I0 immutable-table Roaring experiment, moonlake | A repeated-predicate workload with explicit row-ID ownership and immutable source identity | Compare exact results and build/load/query/memory/size costs across selective and unselective cases; state the reuse needed to amortize the index. A negative result closes I0. Reduced decoding requires a separate selection/gather contract before integration |

HLL CPU rewrites need a profile after the state change. Batch t-digest queries
need a query-bound consumer; 99 scalar queries currently take about 2.3 us.
Wider bitmap IDs, more set operations, shared-table FSST frames and new sketch
algorithms remain workload-driven follow-ups, with contracts recorded before
implementation. A measured negative result completes an investigation.

## HLL consumer seam and conditional library work

Entry points: `sketches/hll.mbt`, `sketches/pkg.generated.mbti`,
`harness/check_hll.py`, and the [HLL contract](SKETCHES.md#hll-contract-v1).

- NULL skipping, numeric widening, DATE representation and string encoding
  belong to moonlake. The kernel hashes typed bytes; signed zero and NaN
  payloads remain distinct under the released format. SQL normalization must
  happen in the adapter and must not silently alter the library hash/version.
- At precision 14 the 16,384 registers are now one byte each in memory (16 KiB
  of payload, previously 64 KiB as machine words), matching the serialized form
  plus its header. Report memory in addition to serialized size; many small
  groups can still make dense HLL more expensive than an exact set, because
  every group pays the full dense state.
- Adoption is complete and the consumer has measured its per-group crossover.
  Compact dense registers are implemented with the v1 bytes unchanged; the
  public `registers()` accessor now returns a snapshot instead of a live view,
  and `register(index)` reads one rank without copying. Sparse registers or an
  exact small-set transition need separate promotion, merge and estimator
  decisions.
  The library already accepts precision; a SQL precision option is consumer work.
- Preserve the distinction between exact register merge laws and statistical
  estimator error. Agreement with another estimator is useful independent
  evidence, not an exact-value oracle or byte-compatibility claim.

## t-digest consumer seam and conditional library work

Entry points: `sketches/tdigest.mbt`, `harness/check_tdigest.py`, and the
[t-digest contract](SKETCHES.md#t-digest-contract-v1).

- Carry forward compression 100 and the recorded empirical acceptance matrix.
  The 1% interior and 0.5% tail rank-error ceilings describe that matrix;
  the independent-reference ratio and merge/order spread remain reported.
- The SQL adapter must decide how Int64 values beyond Double's exact integer
  range are handled, skip NULLs, map empty state to its SQL result, validate
  q independently of data consumption and translate typed update errors.
- Compare direct construction with sequential, balanced and unbalanced merges
  using exact sorted values and the same tie/rank convention. Measure update,
  merge, query and state size separately.
- Investigate k2/k3 scaling, centroid rules or compression tuning only when a
  real query's accuracy or merge spread warrants it. Set the comparison and
  acceptance criteria before changing the implementation. Preserve format
  versioning and the existing invalid-input checks.

## Roaring consumer seam and conditional library work

Entry points: `encoders/roaring.mbt`, `encoders/roaring_query.mbt`,
`harness/perf/main.mbt`, `harness/check_roaring.py` and
`harness/check_roaring_ops.py`.

The sorted builder, container-specific set operations, bulk reads, allocation
changes and branchless probe search have landed. Retain their existing tests
and measurements; a new rewrite starts from the current implementation.

moonlake owns the mapping from immutable source rows to 0..2^31-1 bitmap IDs,
multi-file offsets, invalidation, SQL NULL/duplicate behavior and the scan
contract that can use a selection. Its current `ScanRequest` has projection and
advisory predicates but no row-selection/gather API. Intersecting a bitmap
therefore establishes set computation, not reduced Parquet decoding by itself.

Begin with one opt-in repeated-predicate experiment and its exact scan control.
Account for index construction and reuse, residual filtering, high and low
selectivity, and stale source detection. K4 has measured count-only intersection
and iteration against materialized operations; those kernel results do not
establish an engine scan improvement. Integration still follows I0's selection
contract; wider IDs, persistent sidecars and automatic planner selection require
separate consumer evidence and contracts.

## Scope carried forward

Zero FFI and zero runtime dependencies remain library boundaries. Byte-stream
compression, full nested levels, a public Parquet container API and SIMD remain
deferred under the roadmap. No new kernel is scheduled solely because the
current release is complete.

## Final reminder: update benchmarks

**colenc part done, moonlake part pending.** The scoreboard and the sketch and
bitmap costs were recorded after the kernel tasks landed (see the final record
below). The exploratory K1 probe is a separate kernel measurement; it does not
replace the final scoreboard, sketch accuracy rigs or consumer acceptance.

- colenc (done at `26fb9c0`): run `python3 harness/scoreboard.py` to update `docs/scoreboard.md`;
  retain native/wasm-gc medians, revision/toolchain/data identity and spread.
  Keep Roaring parse, id expansion and combined costs separate, with each
  throughput numerator named. Record HLL/t-digest update, merge, query, memory,
  serialized size and accuracy separately from encoding throughput.
- moonlake (pending, needs a colenc release carrying these changes): use `harness/bench_release.py` for the final release candidate,
  compare against a same-session exact control and update
  `docs/bench-baseline.md`. New SQL or index paths need their own end-to-end
  correctness, memory, accuracy or build-amortization evidence.

**Reminder to the maintainer: update both projects' benchmarks last.**

## Final benchmark record

Recorded on library revision `26fb9c0` after the kernel tasks in the
[implementation record](OPTIMIZATION-PLAN.md) landed (K1 to K6; K0 was already in
place). The host was quiet (load average 0.3 to 0.7). `docs/scoreboard.md` was
regenerated at that revision; its worst round-to-round encode swing was 14% on
native and 23% on wasm-gc, so compare rows within that table only. The numbers
below are native release medians of three rounds from `harness/perf`, not
consumer results. The sketch and bitmap costs are kept apart from encoding
throughput.

| Area | Case | Median |
|---|---|---|
| HLL (p14) | update, one group of 1M Int64 | 18.4 ms |
| HLL | update, 1000 groups of 1000 | 36.0 ms |
| HLL | estimate / merge | 113 us / 52.8 us |
| HLL | `to_bytes` / `from_bytes` (16 KiB + header) | 5.9 us / 7.4 us |
| HLL | peak RSS, 1000 groups of 1000 / 5000 groups of 10 | 25.0 MB / 109 MB |
| t-digest (k100) | update, 1M values / 20k values | 51.9 ms / 1.02 ms |
| t-digest | merge of two 1M-value digests | 2.5 us |
| t-digest | 99 scalar quantile queries | 2.3 us |
| t-digest | `to_bytes` / `from_bytes` | 0.5 us / 1.2 us |
| Roaring | intersection count, array partial overlap / bitmap partial overlap | 37 us / 3.45 us |
| Roaring | intersection count, run containers | 0.02 us |
| Roaring | first 4096 ids of a 1M-id bitmap, batched / `to_array` of all | 4.3 us / 907 us |
| Roaring | full batched walk vs `to_array`, dense bitmap / sparse 1M-id array | 282 us vs 486 us / 1035 us vs 907 us |
| FSST | encode, 100 low-cardinality values, fresh training / reused model | 39.5 us / 2.8 us |
| PLAIN decode, 500k values | Int64 / Int32 | 236 us / 152 us |

Not recorded here: moonlake's end-to-end baseline. It needs the consumer's own
`harness/bench_release.py` run against the registry dependency and a
same-session control, and no colenc release carrying these changes exists yet.
