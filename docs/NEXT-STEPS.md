# Next steps after 0.1.1

Planning snapshot: 2026-10-26 (Asia/Shanghai), source revision `090548c`.
The next work is consumer adoption and measured follow-through. Roaring, HLL
and t-digest are implemented and released; the former A-through-E development
sequence is complete for the library packages and bitmap rewrites, while its
moonlake bitmap experiment is still pending. It is superseded by the plan here.
The [roadmap](ROADMAP.md) and [sketch contracts](SKETCHES.md) retain their
acceptance definitions.

## Current evidence

| Project | Observed state | Planning implication |
|---|---|---|
| colenc | [0.1.1 is published](https://github.com/superbigcup325/colenc/releases/tag/v0.1.1); remote `main` is `c04d7e1`, where [CI passed](https://github.com/superbigcup325/colenc/actions/runs/40205435645), and local `main` is a documentation commit ahead | Retain the released E0-E8 and sketch contracts. Do not schedule their implementation again |
| Release artifact | Built from `504092a`; the tagged tree adds documentation and sketch coverage to the archive consumer, with identical library code. The release records three-target registry-consumer acceptance | Distinguish the registry artifact from its later documentation. Its older README wording does not mean HLL/t-digest are absent |
| moonlake | Local `bc1a8f5`+ accepts colenc 0.1.1 (`24d983b`), adds `approx_count_distinct` and `approx_quantile` on the sketch API, and passed its own acceptance again; 0.6.0 is unreleased and the live latest release is 0.5.0. No sibling workspace override | Adoption and the HLL/t-digest SQL seams are done on the consumer side. A Roaring engine workload (I0) is still an investigation, and the bitmap now carries a measured consumer cost (see K0 below) |
| Consumer acceptance | moonlake's full local pass is on `3ab2634`; its later Parquet reader fix has targeted evidence. Remote `main` remains `750b98c`, whose latest nightly failed on the locally fixed corpus case | Refresh the final consumer candidate. colenc's green CI and small registry probe do not certify an engine revision |
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

This planning pass inspected source, generated APIs, existing verification
records and live release/CI metadata. It did not rerun library or engine tests,
registry consumers or accuracy rigs. The current engine work order and its
exit criteria are maintained in
[moonlake's roadmap](https://github.com/superbigcup325/moonlake/blob/main/docs/ROADMAP.md).
That public branch may lag the local planning revision until it is pushed.

## Work order and ownership

| Package | Owner and delivery | Exit |
|---|---|---|
| C0 | moonlake consumes the published 0.1.1 dependency; colenc provides the released API and compatibility evidence | Fresh dependency resolution without a sibling override, three-target consumer regression, encoding/writer/spill checks and a fresh-cache archive consumer. New `Encoding` and `EncodingError` variants are checked against consumer matches |
| R2 | moonlake refreshes its final 0.6.0 candidate, including its reader fix | The consumer's full correctness, archive, large-file and browser gates run on one final revision. Its own CI/nightly, registry and deployed-page evidence are recorded when the corresponding release actions are authorized |
| A0/A1 | moonlake records SQL and state-cost decisions, then adds explicit HLL aggregation; colenc documents the typed-byte seam and supports defects exposed by that use | SQL NULL/type/value equivalence is specified before updates are hashed. Compare canonical inputs exactly and estimates statistically; measure state per group. Keep the existing exact distinct aggregate exact |
| A2 | moonlake adds explicit approximate quantiles after HLL; colenc retains the t-digest contract and rig | Exact sorted inputs judge empirical rank error. Input conversion, non-finite values, empty input, q validation and merge/order sensitivity have explicit behavior. Keep exact median available |
| I0 | moonlake investigates one immutable-table Roaring workload; colenc changes APIs only for a demonstrated need | Result equality and query/build/load/memory/size evidence include selective and unselective cases. A useful negative result completes the investigation; automatic or persistent indexes require further engine contracts |
| K0 | colenc evaluates improvements exposed by actual consumer costs; the first case is the bitmap link cost described below | Record the workload and unchanged or revised contract before implementation. Require correctness/statistical gates and reproducible cost evidence; do not add a new sketch family to fill the queue |

The engine packages are proposals rather than already shipped SQL functions.
They do not require another colenc release merely to use the current APIs. No
new release number or date is assigned by this plan.

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
- Start engine adoption with the released precision and API. Consider sparse
  registers, an exact-small-set transition or a precision option only after
  measuring the per-group crossover and recording representation, merge and
  serialization compatibility decisions.
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
selectivity, and stale source detection. Consider iteration, count-only
intersection or wider IDs only if that experiment shows why the existing API
is insufficient. Persistent sidecars and automatic planner selection are
engine work, with a separate contract.

## Scope carried forward

Zero FFI and zero runtime dependencies remain library boundaries. Byte-stream
compression, full nested levels, a public Parquet container API and SIMD remain
deferred under the roadmap. No new kernel is scheduled solely because the
current release is complete.

## Final reminder: update benchmarks

**Pending, after the final code and dependency changes.** This planning pass
did not regenerate any performance or accuracy result.

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
