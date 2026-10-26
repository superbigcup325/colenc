# Release and consumer follow-through: 0.1.3 is released

Status: 2026-10-26 (Asia/Shanghai). **Version 0.1.3 is published** from `a97c230`,
tagged `v0.1.3`, with green CI on that source and the packaged surface verified
from the registry on three backends. It carries the sparse HyperLogLog state.
moonlake consumes 0.1.2; upgrading it to 0.1.3 is that project's decision and its
own gate, so nothing here implies consumer behavior beyond the matrix 0.1.3 was
justified by. L0 through C2 are complete. What remains is the conditional work
that waits on a consumer workload, and moonlake's own release, which is that
project's decision. The [implementation record](OPTIMIZATION-PLAN.md) preserves
the completed kernel tasks; the [roadmap](ROADMAP.md) and
[sketch contracts](SKETCHES.md) retain their acceptance definitions.

## Current work order (2026-10-26)

The upstream check found colenc `main` at `e08396e` with
[CI passing](https://github.com/superbigcup325/colenc/actions/runs/40332052995)
and moonlake `main` at `a0c7628` with
[CI passing](https://github.com/superbigcup325/moonlake/actions/runs/40330396420).
The dependency pair at `4de8077` also passed a
[dispatched nightly](https://github.com/superbigcup325/moonlake/actions/runs/40329274231)
and its pages workflow deployed. Neither repository has an open issue or pull
request at this snapshot. These are source and workflow checks; moonlake's
latest release remains 0.5.0, and its 0.6.0 registry consumer and hosted-page
acceptance are still separate release checks.

| Order | Owner and delivery | Exit |
|---|---|---|
| 1 | moonlake: finish the 0.6.0 release preparation | Keep the accepted scope frozen, reconcile current documentation, inspect the final archive and record its source/toolchain identity. Tagging, publication and the release dry run follow that project's release authorization; the registry consumer and hosted-version check follow the relevant external action. No new colenc release is a prerequisite |
| 2 | moonlake H0: refresh grouped HLL costs against colenc 0.1.2 | Record SQL peak RSS and time against decode-only and exact-count controls, using few large groups and many small groups, including duplicates and NULLs. The current register payload is 16 KiB per p14 sketch; the 0.1.1 consumer's 64 KiB payload and approximately 750-value crossover are historical. Measure the new crossover rather than dividing the old one by four |
| 3 | moonlake E5: remove input collection before budgeted GROUP BY | First record partition-buffer accounting, skew behavior, ownership and the policy for a group whose exact state exceeds the budget. Then feed scan batches into bounded partition buffers and verify exact answers, cleanup and resource use. This is the next proposed implementation after 0.6.0, with no kernel dependency |
| 4 | colenc: promote one conditional investigation only when its entry evidence exists | H0 showed the remaining state cost and the sparse HLL state is now in the tree, awaiting a release decision rather than a measurement; FSST reuse waits for repeated small batches with measurable training cost; I0 waits for immutable row identity and a repeated-predicate workload. A measured negative result closes the investigation |

The consumer owns the detailed
[delivery sequence](https://github.com/superbigcup325/moonlake/blob/main/docs/ROADMAP.md#next-delivery-after-colenc-012).
H0 and E5 address different costs: compact sketch state cannot remove retained
scan input, and streaming scan input cannot bound the number or size of group
states. Do not bundle speculative kernels into moonlake's accepted release.

## Final evidence

| Item | State |
|---|---|
| colenc 0.1.3 | [Published](https://github.com/superbigcup325/colenc/releases/tag/v0.1.3) from `a97c230` on 2026-10-26, tagged `v0.1.3`, [CI green on that source](https://github.com/superbigcup325/colenc/actions/runs/40347165504) (check, harness and three test jobs). Archive SHA-256 `9dc5b38f01929f62a8d2c6d7868553114cf7bd3c78e7742c4fa83732a90c5d44`, built with moon 0.1.20261023 (3778465 2026-10-23) |
| Gate before publication (0.1.3) | `moon info` (no interface change), `moon fmt --check` and `moon check --deny-warn` clean; 172 tests per target on native, wasm-gc and js; every fixture regenerator in `--check` mode; all byte-diff, round-trip and property harnesses; the container check; the archive consumer on three targets; a clean package archive; and `moon publish --dry-run` returning 202 Accepted |
| Registry copy (0.1.3) | `moon view superbigcup325/colenc` reports 0.1.3 as latest, and `python3 harness/check_consumer.py --registry-version 0.1.3` passes on native, wasm-gc and js with a fresh registry and dependency cache |
| colenc 0.1.2 (previous) | Published 2026-10-26 from `b1b2b7f`, tagged `v0.1.2`, [CI green on that source](https://github.com/superbigcup325/colenc/actions/runs/40302072598). Archive SHA-256 `ad0d5fb0b49c2a729257c0f3afacdb4e93c9b964c3854df26999d00f3ed1ea1e`, built with moon 0.1.20261016 (1af328f 2026-10-16); 165 tests per target then |
| Gate before 0.1.2 | `moon info`, `moon fmt --check` and `moon check --deny-warn` clean; 165 tests per target on native, wasm-gc and js; every fixture regenerator in `--check` mode; all byte-diff, round-trip and property harnesses; the container check; and the archive consumer on three targets |
| Registry copy (0.1.2) | `moon view superbigcup325/colenc` reported 0.1.2 as latest, and `python3 harness/check_consumer.py --registry-version 0.1.2` passed on native, wasm-gc and js with a fresh registry and dependency cache |
| moonlake | `95c42c6` consumes 0.1.2 with no workspace override, with the acceptance record and the performance pair in `4de8077` and the closing note in `a0c7628`; `main` is pushed, its CI is green and a dispatched nightly passed. It needed no source change: the engine reaches the bitmap through the dedicated entry points and reads HLL registers through `register(index)` |
| The cost K0 was measured on | **Closed.** The 0.1.1 artifact cost about 10% on moonlake's wide CSV scans because the generic dispatch kept the bitmap reachable. Against a 0.1.1 control built in its own worktree, three alternating pairs on a quiet host put the CSV cases 6-11% in 0.1.2's favour in every round: `count(*)` 171.3 to 153.0 ms, the filtered count 188.5 to 170.0, the two-table join 235.4 to 214.8, Q3 266.7 to 249.6 and the fanout join 383.2 to 348.4. The two Parquet cases stay unresolved at 4 ms and 11 ms with in-record spreads up to 73% |
| Library measurements | The final [scoreboard](scoreboard.md) from `26fb9c0` is unchanged by the release; the release carries the same library code it recorded. Worst encode swing was 14% native and 23% wasm-gc |

**K0 has its answer.** The 0.1.1 artifact moved the consumer's hot CSV loops
because `encode_column` / `decode_column` reached `encoders/roaring.mbt` from
every Parquet caller, so dead-code elimination could not drop it. Two probes had
already bracketed the cause — deleting the file and refusing the facade arms both
returned the consumer to control speed at 8,248 fewer bytes — and the shipped fix
is the narrower one: the `Roaring` arms left the generic dispatch for
`encode_roaring_column` / `decode_roaring_column`, so a caller that only passes
PLAIN, DELTA, the length family, dictionary or FSST never links a bitmap. The
consumer re-record above is the confirmation the probe could not give.

## Release order and ownership

**Version: 0.1.2, by the maintainer's decision to stay on 0.1.x.** The generic
facade now refuses Roaring, and `HllSketch::registers()` returns a snapshot
rather than a live view. These are observable compatibility changes, even though
the serialized formats stay the same; semantic versioning would call them a
minor bump, so the changelog carries a migration section at the top of the
release. The release is authorized.

L0, L1, L2, C1 and C2 ran in order and are done. A moonlake release of 0.6.0
stays separate and needs its own authorization; conditional investigations stay
out of this candidate.

| Task | Delivery | State |
|---|---|---|
| L0 | colenc: migration notes and packaged API coverage | **Done** at `8a843ff` and `70b267d`. The archive consumer now trains a model and encodes a held-out batch with it, checks that a retained HLL snapshot does not follow later updates, concatenates bitmap id batches and compares them with an independent expected set, and exercises the generic dispatch's refusal. The migration section heads the changelog |
| L1 | colenc: versioned candidate and artifact | **Done** at `b1b2b7f`. Manifest, changelog, README, AGENTS.md, roadmap and this document name 0.1.2; the quartet, three targets, every harness and the archive consumer passed; `moon package --list` carries no local-only path; source, archive SHA-256 and toolchain are in the table above |
| L2 | colenc: publish and verify the registry copy | **Done**. CI green before the tag, `moon publish --dry-run` returned `202 Accepted`, the publish returned `Server status: 200 OK`, tag `v0.1.2` and its release notes identify `b1b2b7f`, and the registry consumer passed on three targets with fresh caches |
| C1 | moonlake: consume the registry version, repeat acceptance | **Done** at `95c42c6`, verification §41 there. Registry resolution without an override; 348 wasm-gc / 361 native / 348 js tests, the 33 goldens on three paths, the window and correlation differentials, the pushdown fuzz, page fixtures, CLI, spill, writer interop, corpus 17 decoded / 51 refused / 0 failing, 75 unit tests, the 2.41 GB write, Chromium 16/16 and the archive consumer |
| C2 | moonlake: final consumer baseline and release evidence | **Done** at `4de8077`, verification §41 there. Three alternating candidate/control pairs with the oracles green and identical output hashes, both records committed under `harness/baseline/`, the table in `docs/bench-baseline.md`, and the unresolved Parquet cases reported as unresolved rather than picked. Those cases do not re-measure grouped SQL HLL memory or its crossover against exact state; H0 owns that refresh |

The acceptance definitions L1 carried are unchanged: `moon info`, `moon fmt`,
`moon check --deny-warn`, `moon test` on native, wasm-gc and js, every harness
step in the CI workflow, and the archive consumer before publication. The 0.1.1
split between the registry artifact and a later tagged documentation tree was
not repeated: the tagged source and the published archive are the same revision.

## Completed kernel deliveries

The [implementation record](OPTIMIZATION-PLAN.md) retains the original task
scope, compatibility decisions, acceptance rules and exploratory probe. These
deliveries shipped in 0.1.2.

| Task | Implemented delivery | Remaining boundary |
|---|---|---|
| K0 | Dedicated Roaring facade; generic dispatch refuses the set encoding | Migration and registry-consumer confirmation are complete; retain the dedicated-entry-point contract |
| [K1](OPTIMIZATION-PLAN.md#k1-plain-word-loads) | Validated word loads for Int64/Double and Int32/Float, with overflow-safe count checks | The consumer's short Parquet pair is unresolved; no SIMD or unpacker rewrite is implied |
| [K2](OPTIMIZATION-PLAN.md#k2-dictionary-budget-checked-during-construction) | Stop dictionary construction when its payload would exceed the limit | Accepted bytes and `None` fallback remain unchanged |
| [K3](OPTIMIZATION-PLAN.md#k3-compact-hll-state) | Dense byte registers, snapshot accessor and allocation-free `register(index)` | Sparse state shipped in 0.1.3 (see [the delivery record](#sparse-hll-state-delivery-record)); the refreshed SQL crossover stays with H0 |
| [K4](OPTIMIZATION-PLAN.md#k4-roaring-query-apis) | Intersection count, overlap predicate and stateless `ids_after` batches | I0 still owns engine integration and selection semantics |
| [K5](OPTIMIZATION-PLAN.md#k5-t-digest-compression-and-batch-quantiles) | Merge the sorted buffer with ordered centroids and cache lower scale values | Batch quantiles were deferred after measurement; k1 and accuracy ceilings remain unchanged |
| [K6](OPTIMIZATION-PLAN.md#k6-reusable-fsst-model) | Immutable reusable model; every batch retains the existing self-contained frame | Caller-owned lifetime and drift policy; no shared-table frame or model export format |

## Conditional work after consumer acceptance

Start with the new consumer baseline. Promote one bounded investigation when
its workload demonstrates the need; no additional kernel blocks L0 to C2.

| Priority | Investigation and owner | Entry evidence | Delivery and stop condition |
|---|---|---|---|
| 1 | Sparse HLL state, colenc with a moonlake workload | H0 met it: grouped `approx_count_distinct` over 20,000 ten-value groups peaked at about 400 MB against about 20 MB for the exact count, and the library's dense control reached about 110 MB for 5000 groups of 10 values | **Shipped in 0.1.3** — see [the delivery record](#sparse-hll-state-delivery-record). Dense state stayed the fallback above the promotion limit; an exact-small-set estimator is still a separate decision |
| 2 | FSST model reuse in a consumer, moonlake | Repeated small string batches with a stable enough distribution and training visible in the profile | One opt-in workload with a bounded model lifetime and held-out/drifting batches. Report training amortization, table bytes per frame, encode/decode time, memory and fallback behavior. Keep one-shot behavior available; defer export/shared-table formats unless this caller needs them |
| 3 | I0 immutable-table Roaring experiment, moonlake | A repeated-predicate workload with explicit row-ID ownership and immutable source identity | Compare exact results and build/load/query/memory/size costs across selective and unselective cases; state the reuse needed to amortize the index. A negative result closes I0. Reduced decoding requires a separate selection/gather contract before integration |

HLL CPU rewrites need a profile after the state change. Batch t-digest queries
need a query-bound consumer; 99 scalar queries currently take about 2.3 us.
Wider bitmap IDs, more set operations, shared-table FSST frames and new sketch
algorithms remain workload-driven follow-ups, with contracts recorded before
implementation. A measured negative result completes an investigation.

## Sparse HLL state: delivery record

The condition in priority 1 was met by moonlake's H0 refresh: the per-group 16 KiB
register array, not the sketch's CPU, was what made a grouped
`approx_count_distinct` expensive. `sketches/hll.mbt` now holds either a dense
register array or a sorted array of live entries, and promotes once a sketch
carries more than `min(128, m / 8)` live registers. What stayed fixed is the part
that belongs to the format: the hash, the rank update, the estimator, the merge
law and the v1 byte stream. The pinned byte stream and its checksum
(`-541558647`) are unchanged, and `from_bytes` gives a deserialized sketch the
state its contents justify.

What moved is memory, and [the cost table](SKETCHES.md#state-cost) carries dense
against sparse over eleven group shapes: 1000 × 10 drops 24.5 → 12.6 MB,
5000 × 10 106.5 → 12.5 MB, 20000 × 10 404.9 → 12.6 MB, 50000 × 10 992.4 →
12.6 MB, and 20000 × 1 405.0 → 12.6 MB, while a shape whose groups all promote
(1000 × 1000) is unchanged at 24.4 MB in both. The same table reports the
operation deltas: +23.3% on the update of 1000 groups that each promote, +3.5% on
a million values in one group, −4.1% merge, −6.0% `to_bytes` and +23.1%
`from_bytes`, which pays one extra branch per register to count the live ones.

Two repeatable rigs cover it: `harness/hll_state.py` measures peak RSS and wall
time of an isolated child across the group shapes, `--control` against a second
build, so the dense comparison can be reproduced rather than quoted; and
`harness/check_hll.py` keeps judging the estimator against datasketches. The
gates: `moon check --deny-warn`, `moon info` (no public interface change),
`moon fmt`, 172 tests on wasm-gc, native and js, the acceptance rig's four groups,
and the new insertion-order, representation-invariance, promotion, sparse-merge,
deserialization and precision-floor tests in `sketches/hll_wbtest.mbt`. The
end-to-end SQL effect was measured in the consumer through an untracked
`moon.work`; that record belongs to moonlake.

**0.1.3 is that release, and it is published.** The sparse state is in the
artifact the registry serves, with the byte stream, the interface and the
estimator unchanged, so a consumer that pins 0.1.2 and upgrades gets the memory
behavior and nothing else to port. moonlake's upgrade is its own decision and its
own gate; the final-evidence table records how this version was verified and
published, and `moon view superbigcup325/colenc` is the live check.

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
- Adoption is complete, and the sparse state ships in 0.1.3: a sketch
  holds either the dense array or a sorted array of live entries and promotes
  above `min(128, m / 8)` live registers, with the estimator, the merge law and
  the v1 bytes unchanged. The public `registers()` accessor still returns a
  snapshot rather than a live view, and `register(index)` reads one rank without
  copying, in both states. An exact small-set transition remains a separate
  decision, and a consumer picks the state up only through a new release.
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

**Both parts are done.** The scoreboard and the sketch and bitmap costs were
recorded after the kernel tasks landed (see the final record below), and the
consumer's baseline was re-recorded against the published dependency. The
exploratory K1 probe is a separate kernel measurement; it does not replace the
final scoreboard, sketch accuracy rigs or consumer acceptance.

- colenc (done at `26fb9c0`): run `python3 harness/scoreboard.py` to update `docs/scoreboard.md`;
  retain native/wasm-gc medians, revision/toolchain/data identity and spread.
  Keep Roaring parse, id expansion and combined costs separate, with each
  throughput numerator named. Record HLL/t-digest update, merge, query, memory,
  serialized size and accuracy separately from encoding throughput.
- moonlake (done at `4de8077`): `harness/bench_release.py` measured the
  published dependency against a 0.1.1 control built in its own worktree, three
  alternating pairs on a quiet host, with the oracles green and identical output
  hashes. The pair is in that project's `docs/bench-baseline.md`; the wide CSV
  cases came out 6-11% faster in every round, and the two Parquet cases are
  reported as unresolved rather than resolved in either direction. New SQL or
  index paths still need their own end-to-end correctness, memory, accuracy or
  build-amortization evidence.

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

moonlake's end-to-end baseline is recorded separately at `4de8077`, in its
`docs/bench-baseline.md` and verification §41, against the published 0.1.2
dependency and a same-session 0.1.1 control. The library medians above and that
consumer pair answer different questions. The SQL grouped-HLL crossover still
needs H0; the library RSS rows do not supply it.
