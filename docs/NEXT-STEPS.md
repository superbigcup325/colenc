# Next steps after 0.1.1

Planning snapshot: 2026-10-26 (Asia/Shanghai), library revision `9fdd252`.
Roaring, HLL and t-digest are released in 0.1.1; moonlake has consumed that
version, implemented both SQL sketch functions and accepted its local 0.6.0
candidate. The bitmap dispatch fix is implemented locally and awaits release
follow-through. The next kernel work is recorded as six tasks in the
[optimization handoff](OPTIMIZATION-PLAN.md), starting with PLAIN word loads and
dictionary budget checks. The [roadmap](ROADMAP.md) and
[sketch contracts](SKETCHES.md) retain their acceptance definitions.

## Current evidence

| Project | Observed state | Planning implication |
|---|---|---|
| colenc | [0.1.1 is published](https://github.com/superbigcup325/colenc/releases/tag/v0.1.1); remote `main` is `c04d7e1`, where [CI passed](https://github.com/superbigcup325/colenc/actions/runs/40205435645). Local `main` is `9fdd252`, three commits ahead, including the bitmap dispatch change | The new dedicated bitmap entry points and generic-dispatch refusal are implemented but unreleased. The older green CI does not certify that change |
| Release artifact | Built from `504092a`; the tagged tree adds documentation and sketch coverage to the archive consumer, with identical library code. The release records three-target registry-consumer acceptance | Distinguish the registry artifact from its later documentation. Its older README wording does not mean HLL/t-digest are absent |
| moonlake | Local `6963e3b` carries the colenc 0.1.1 upgrade (`24d983b`), `approx_count_distinct` and `approx_quantile`; full local acceptance ran on `bc1a8f5`. 0.6.0 is unreleased and the latest published version is 0.5.0. No sibling workspace override | C0 and A0/A1/A2 are completed consumer work. I0 is still an investigation; the current registry dependency still carries the measured link cost described below |
| Consumer acceptance | R2 ran the full list again on `bc1a8f5`: 361 native / 348 wasm-gc / 348 js tests, the golden and differential gates, corpus 17 decoded / 51 refused / 0 failing, the 2.41 GB write, Chromium 16/16 and fresh-cache archive consumers. Remote `main` remains `750b98c`, whose latest nightly failed on the locally fixed corpus case | Local acceptance is complete for that source and colenc 0.1.1. Changing the library dependency requires acceptance again; the final source has no remote CI/nightly evidence yet |
| Measurements | `docs/scoreboard.md` was regenerated on 2026-10-26 at `090548c`. The host measured about 14% below the 2026-10-25 record on identical code (re-running `0cb57e9` today: 1941 MB/s against the recorded 2247.2 for `int64-monotonic`/PLAIN), so the new table sits lower across the board | Compare rows within one table, never across records taken in a different power state. On that same row the 0.1.1 code itself is −1.8% (1907 MB/s) |

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

The source and status check used generated APIs, existing verification logs
and read-only registry/GitHub queries. A separate Int64 load experiment ran on
native and wasm-gc; its [source and complete timing summaries](plain64-probe-2026-10-26.json)
are preserved with the [task and reproduction instructions](OPTIMIZATION-PLAN.md#exploratory-plain-record).
That probe did not rerun full library/engine suites, registry consumers or
sketch accuracy rigs, and it is not a new release scoreboard. The current engine
work order and its exit criteria are maintained in
[moonlake's roadmap](https://github.com/superbigcup325/moonlake/blob/main/docs/ROADMAP.md).
That public branch may lag the local planning revision until it is pushed.

## Work order and ownership

| Package | Owner and delivery | Exit |
|---|---|---|
| C0 | **Done locally**: moonlake consumes the published 0.1.1 dependency | Fresh dependency resolution without a sibling override, three-target suites, encoding/writer/spill checks and fresh-cache archive consumers passed; the added variants required no consumer match changes |
| R2 | **Done locally** on `bc1a8f5`, including the reader fix, dependency upgrade and both SQL sketch functions | Full correctness, archive, large-file and browser gates passed on that revision. Repeat on any changed candidate; remote CI/nightly and registry/deployed-page checks follow the corresponding release actions |
| A0/A1 | **Done locally**: moonlake records SQL/state costs and implements explicit `approx_count_distinct` | SQL normalization, NULL/empty behavior and per-group memory are documented and tested; exact distinct remains exact. Compact state is new K3 work, not unfinished HLL adoption |
| A2 | **Done locally**: moonlake implements explicit `approx_quantile`; colenc retains its t-digest contract and rig | Numeric conversion, non-finite values, NULL/empty behavior and bind-time q validation have explicit behavior and tests. Exact median remains available |
| I0 | moonlake investigates one immutable-table Roaring workload; colenc changes APIs only for a demonstrated need | Result equality and query/build/load/memory/size evidence include selective and unselective cases. A useful negative result completes the investigation; automatic or persistent indexes require further engine contracts |
| K0 | **Implemented, unreleased** in `9fdd252`: keep Roaring out of generic dispatch | Dedicated Roaring entry points retain the payload; generic encode/decode now refuse Roaring. The migration is in CHANGELOG. Complete candidate/packaged-consumer acceptance, then follow the authorized release sequence and re-record the registry consumer |

C0, R2 and A0/A1/A2 are implemented and accepted locally, but moonlake 0.6.0
is not published. I0 and the six new kernel tasks remain proposals. K0 needs a
new colenc release before the normal registry dependency can consume its fix;
no release number or date is assigned here.

## Kernel implementation handoff

The [optimization plan](OPTIMIZATION-PLAN.md) is the task specification for the
next implementer. Start with K1, then K2. Each task names source files, behavior
that must remain stable, relevant gates and the measurement needed to finish.
The PLAIN probe is preserved in the linked record, including its exact code;
other tasks have no new measured performance result.

| Task | Delivery | Start condition |
|---|---|---|
| [K1](OPTIMIZATION-PLAN.md#k1-plain-word-loads) | Validated bulk loads in PLAIN decoding, then affected full-width paths | Reproduce the isolated control; preserve errors, byte layout and allocation in the first comparison |
| [K2](OPTIMIZATION-PLAN.md#k2-dictionary-budget-checked-during-construction) | Stop dictionary planning as soon as its encoded payload exceeds the budget | Keep under-limit bytes and the existing `None` fallback identical |
| [K3](OPTIMIZATION-PLAN.md#k3-compact-hll-state) | Compact dense registers first; sparse state and CPU experiments separately | Record compatibility for the public non-copying `registers()` accessor and v1 bytes |
| [K4](OPTIMIZATION-PLAN.md#k4-roaring-query-apis) | Count-only intersection, overlap testing and ordered batch iteration | Name the workload, ownership/lifecycle and count-width contract; engine integration follows I0 |
| [K5](OPTIMIZATION-PLAN.md#k5-t-digest-compression-and-batch-quantiles) | Reduce compression work under k1; evaluate a batch quantile API | Preserve the existing structure, rank convention and accuracy matrix |
| [K6](OPTIMIZATION-PLAN.md#k6-reusable-fsst-model) | Measure and, if useful, expose reusable training state | Demonstrate amortization on held-out batches and record frame compatibility |

## HLL consumer seam and conditional library work

Entry points: `sketches/hll.mbt`, `sketches/pkg.generated.mbti`,
`harness/check_hll.py`, and the [HLL contract](SKETCHES.md#hll-contract-v1).

- NULL skipping, numeric widening, DATE representation and string encoding
  belong to moonlake. The kernel hashes typed bytes; signed zero and NaN
  payloads remain distinct under the released format. SQL normalization must
  happen in the adapter and must not silently alter the library hash/version.
- At precision 14, the 16,384 registers are machine words in memory, about
  64 KiB of payload, although serialization uses one byte per register plus
  its header. Report memory in addition to serialized size; many small groups
  can make dense HLL more expensive than an exact set.
- Adoption is complete and the consumer has measured its per-group crossover.
  K3 evaluates compact dense registers first, with public-accessor and v1-byte
  compatibility recorded before implementation. Sparse registers or an exact
  small-set transition need separate promotion, merge and estimator decisions.
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

Entry points: `encoders/roaring.mbt`, `harness/perf/main.mbt`,
`harness/check_roaring.py` and `harness/check_roaring_ops.py`.

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
selectivity, and stale source detection. K4 can benchmark count-only intersection
and iteration against today's materialized operations without claiming an
engine scan improvement. Integrating them still follows I0's selection contract;
wider IDs, persistent sidecars and automatic planner selection require separate
consumer evidence and contracts.

## Scope carried forward

Zero FFI and zero runtime dependencies remain library boundaries. Byte-stream
compression, full nested levels, a public Parquet container API and SIMD remain
deferred under the roadmap. No new kernel is scheduled solely because the
current release is complete.

## Final reminder: update benchmarks

**Pending, after the final code and dependency changes.** The exploratory K1
probe is a separate kernel measurement; it does not replace the final scoreboard,
sketch accuracy rigs or consumer acceptance.

- colenc: run `python3 harness/scoreboard.py` to update `docs/scoreboard.md`;
  retain native/wasm-gc medians, revision/toolchain/data identity and spread.
  Keep Roaring parse, id expansion and combined costs separate, with each
  throughput numerator named. Record HLL/t-digest update, merge, query, memory,
  serialized size and accuracy separately from encoding throughput.
- moonlake: use `harness/bench_release.py` for the final release candidate,
  compare against a same-session exact control and update
  `docs/bench-baseline.md`. New SQL or index paths need their own end-to-end
  correctness, memory, accuracy or build-amortization evidence.

**Reminder to the maintainer: update both projects' benchmarks last.**
