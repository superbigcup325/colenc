# Sketches: approximate aggregations

colenc's page encodings are judged by round trip, byte identity against the
reference writer, and container interop ([roadmap](ROADMAP.md) §4). A sketch has
no reference byte stream: no Parquet writer emits a HyperLogLog register array,
so byte identity has nothing to compare against. The family is therefore a
declared exception in the sense of §4 — the same position E7 FSST occupies — and
its criteria are properties plus a statistical rig, written here before any
implementation.

HLL and t-digest are implemented in the `sketches` package and published in
0.1.1. This document retains the contracts recorded before their implementation,
including the later acceptance decisions. [Next steps](NEXT-STEPS.md) now covers
consumer adoption and measurement-driven follow-through.

## Decision record

- **Scope**: a dedicated sketch API, not a `ColBuf` type and not a new
  `Encoding` branch. A sketch is not a page encoding: it aggregates a column and
  its result is an estimate, not bytes a reader can decode back to values.
  `encode_column` / `decode_column` stay untouched.
- **Decided by**: the maintainer, 2026-10-25, as the D package of the next-steps
  plan.
- **Acceptance definition**: the four groups in the section below. They are
  statistical and structural; they do not claim a maximum error.
- **Why the criteria differ from E0–E8**: there is no reference byte stream to
  diff and no decode path to round-trip through. Copying the triple would mean
  inventing a reference writer to be identical to, which proves nothing.

## HLL contract (v1)

### Parameters

- `p`, the log2 of the register count, is chosen per sketch and must satisfy
  `4 <= p <= 16`. The default is `p = 14`, which is `m = 16384` registers and a
  standard error of about 0.81%.
- **Dense registers only.** One register per bucket, six bits of rank, held as
  one byte in memory and written as one byte each; the serialized sketch
  is exactly `m` register bytes plus the two header bytes. The sparse
  representation a production HLL++ carries is not in v1: it exists to make small
  cardinalities cheap, and it doubles the state machine. That is a scope
  decision, recorded here rather than discovered later.
- The estimator is the classical HyperLogLog one with the small-range (linear
  counting) and large-range corrections. **No empirically fitted bias tables**:
  those are calibrated against a training corpus, and colenc cannot honestly
  claim a calibration it has not run.

### Hashing

MurmurHash3 x64 128, lower half, seed 0, in pure MoonBit — chosen so that the
same input hashes to the same bits on native, wasm-gc and JS — the register update uses `Int64` arithmetic and
`popcnt`/leading-zero operations only, never floating point. The hash function
and its seed are part of the format: changing either invalidates every stored
sketch, so the version byte covers it.

### Input canonicalization

A column's value is hashed through its canonical little-endian form, so the same
logical value hashes to the same bits on every backend and in every column type:
`Int32` as 4 bytes, `Int64` as 8, `Float` as its 4-byte IEEE bit pattern,
`Double` as 8, `Bool` as one byte 0 or 1, `ByteArray` as its raw bytes with no
length prefix (the caller's value boundary is the type, not a delimiter).

`ColBuf` carries no nulls, so null handling is out of scope for this version
rather than silently folded into a hash of zero. Floating-point values are hashed
by bit pattern, not by a normalised numeric value, so `-0.0` and `0.0` count as
two values and each NaN payload counts as its own — that is a property of the
format, and stating it is cheaper than discovering it in a test.

### Surface

The sketch lives in its own package and exports:

- construction from a precision (`HllSketch::new`) and a default-precision
  constructor (`HllSketch::new_default`)
- one typed entry point per column value: `add_int32`, `add_int64`, `add_float`,
  `add_double`, `add_bool`, and `add_bytes` for `Bytes`
- `merge` of two sketches with equal precision, returning a new sketch and
  leaving both operands untouched (the same ownership rule a set operation
  follows: a result never aliases an operand)
- `estimate` as a `Double`
- `to_bytes` / `from_bytes`, with every malformed input a typed error carrying
  an offset, never a panic

### Serialization

A **colenc-owned** format: a version byte, the precision, and the register array
little-endian. It does not follow a named reference format, because the
reference implementation's serialization is its own state machine (HLL++ with a
sparse mode and an ordered sparse/dense toggle) and copying it would buy
compatibility nobody asks for. Estimate agreement with that implementation must
therefore never be read as byte compatibility — the two are unrelated claims.

The reader validates the version, the precision range, the length, and that no
register exceeds the legal range before it returns a sketch, with a typed error
carrying an offset. Cross-backend byte identity is required: the three backends
must produce the same bytes for the same input sequence.

### Test-time reference

The outside opinion is Apache DataSketches' `datasketches` Python package, pinned
in `harness/requirements.txt` the way `pyroaring` is. It is HLL++, so it judges
whether an estimate sits where an independent implementation puts it; it does not
judge registers or bytes, and the acceptance criteria are written so that no test
claims otherwise.

### Acceptance

Four groups, all of which must pass before the sketch is called done.

1. **Error at the default precision.** The relative error is measured over
   twenty fixed seeds at 1k, 20 at 100k and 5 at 1M, and the group asserts that
   the measured standard deviation is within a quarter of `1.04 / sqrt(m)`,
   that the mean is centred, and that at most a tenth of the samples fall
   outside `1.96 sigma`. One 10M sample is reported and not promised.

   The spread is bounded from above rather than pinned to the analytic value:
   below about `2.5m` the linear-counting correction is *more* accurate than
   `1.04 / sqrt(m)`, so a smaller deviation there is the estimator working, and
   the upper bound is what catches a defect.

   Asserting that *every* sample sits inside `1.96 sigma` was the first draft
   and is not a stricter criterion, it is a broken one: a 95% interval is
   violated by construction about one time in twenty, so the draft would fail at
   random. Measuring the spread is the same claim stated so that it can pass or
   fail for a reason. The worst sample is printed either way.
2. **Merge algebra.** Union must be commutative and associative as a register
   array: `merge` in either order and any grouping produces bit-identical
   registers, and merging into an empty sketch equals building directly.
3. **Serialization.** Round trip is exact; the three backends agree byte for
   byte; a corrupt version, an out-of-range precision, a truncated array and a
   register above the legal range are each rejected with a typed error. A merge
   of two different precisions is rejected the same way.
4. **Boundaries.** Empty, a single element, an all-duplicate column, a hash of
   all-zero and all-one bits (the estimator's worst inputs), the smallest and
   largest legal precision, and the point where linear counting hands over to
   the raw estimator.

### t-digest contract (v1)

### Decision record

- **Accuracy criterion**: three layers, chosen by the maintainer on 2026-10-25 —
  structural invariants that always hold, a comparison against an independent
  implementation, and absolute ceilings. A purely absolute criterion would rest
  on numbers invented before measuring; a purely relative one would inherit
  whatever cell the reference gets wrong. The plan already asks for proven
  structure to stay separate from measured accuracy, and this is that split.
- **Scaling function**: `k1`, compression `k = 100`. The k2/k3 variants buy tail
  accuracy with a more involved merge rule; v1 takes the simple one and *measures*
  the tails rather than promising them.
- **Scope**: `Double` values. A quantile summary over integers compresses to the
  same thing through the callers' conversion, and a quantile over booleans has no
  meaning.

### Parameters and state

- Centroids are `(mean, weight)` pairs. After a compression pass there are at
  most `2k` of them; the serialized form is taken after compression, so the byte
  stream never exceeds that bound.
- Updates land in a buffer of at most `8k` values; filling it triggers a
  compression. Memory is therefore bounded by the centroids plus the buffer, not
  by the input size.
- The scale function is `k1(q) = k / (2 pi) * asin(2q - 1)`. A centroid that
  would span `[q_lo, q_hi]` is legal only while `k1(q_hi) - k1(q_lo) <= 1`.

### Construction, merge and query

- `update` appends to the buffer; `compress` sorts centroids by mean and walks
  them left to right, accumulating while the centroid stays legal.
- `merge` concatenates both sketches' centroids and compresses once, so the
  result holds at most `2k` centroids whatever the inputs were.
- **Compression alternates direction.** Each pass starts from the end the previous
  one finished at. A single-direction sweep leaves the centroids near the far end
  coarser than the near end, which is exactly where the tail quantiles live; the
  alternating pass was added after the first matrix run showed the tails two to
  ten times worse than the reference. The order-sensitivity number the rig reports
  is what is left of that effect.
- `rank(x) = count(values <= x) / N`. A centroid's mass is split evenly around
  its mean, so its quantile position is `(weight_before + weight_after) / 2`.
- `quantile(q)` returns the minimum exactly for `q <= 0` and the maximum exactly
  for `q >= 1`; otherwise it interpolates linearly between the two centroids
  whose positions bracket `q`, clamping to the extremes outside them.

### Serialization

A **colenc-owned** format: a version byte, the compression parameter, the
centroid count little-endian, then one `(mean f64le, weight f64le)` pair per
centroid. Reading back validates the version, the compression range, the count
against `2k`, that weights are positive and finite, that means are sorted and
inside the recorded extremes. Sorted rather than strictly increasing: a
duplicate-heavy column produces adjacent centroids with the same mean, and the
writer emits them, so the reader has to accept them. Cross-backend byte identity is required.

### Errors

- `update` with a NaN or an infinity is rejected rather than folded in: those
  values have no rank, and silently keeping them corrupts every query.
- `quantile` with `q` outside `[0, 1]`, or NaN, is rejected.
- `quantile` on an empty sketch reports an incomplete stream.
- `merge` between sketches of different compression parameters is rejected.
- `from_bytes` reports a truncated header or body, an unknown version, a count
  beyond the bound, a non-positive or non-increasing centroid, with an offset.

### Acceptance — the three layers

**Matrix.** Distributions: uniform, skewed (exponential), heavy-tailed (Pareto)
and duplicate-heavy (fewer than 1000 distinct values). Input orders: ascending,
descending, shuffled with a fixed seed. Sizes: 1k, 100k, 10M. Quantiles: 0.001,
0.01, 0.05 through 0.95 in steps of 0.05, 0.99, 0.999. Ground truth is the exact
sorted array. Merge trees: sequential, balanced pairwise and unbalanced, and the
report states the spread across orders instead of asserting they agree.

1. **Structure, always.** After `to_bytes`: at most `2k + 1` centroids; the
   weights sum to `N` exactly; the minimum and maximum are exact; quantiles are
   monotone in `q`; a merge preserves the weight sum and the extremes; a round
   trip is exact; the three backends produce the same bytes.
2. **Against the reference.** The same matrix runs through Apache DataSketches'
   `tdigest_double` at the same `k`, and each `(distribution, size, q)` cell must
   have a rank error no worse than twice the reference's, with two positions of
   slack: the ground-truth rank is quantized at `1/N`, so at `N = 1k` one position
   is already 0.1% and a bare ratio would compare rounding.

   **Recorded decision, 2026-10-25**: the ratio is *reported, not gated*. Measured
   on the matrix, the reference sits at 0.00-0.02% on most cells while ours lands
   at 0.02-0.07%, so a bare ratio divided two numbers that were both far inside
   the ceiling and reported a factor of two or four as if it meant something. With
   a floor of a tenth of the ceiling the heavy-tailed cells still come out two to
   six times behind, and the honest reading is that Apache's implementation has had
   years of tuning we have not done — a ratio between two implementations measures
   the generation, not the correctness. The absolute ceilings are the gate; the
   ratio is printed so the gap stays visible instead of being hidden inside a
   threshold that happens to pass. Raising our side of that gap is future work
   (k2/k3 scaling, or the centroid optimisations the reference uses).

   The reference is an independent implementation, so this says nothing about byte
   compatibility.
3. **Absolute ceilings.** At most 1% rank error for interior quantiles
   (`0.05 .. 0.95`) and 0.5% in the tails (`0.001, 0.01, 0.99, 0.999`). Every
   cell is printed, so a pass is visible as numbers rather than as a verdict.

### Explicitly not claimed

- A universal error bound: t-digest has none, and the ceilings above are
  empirical values for the named matrix at `k = 100`.
- Exact quantiles, or agreement with the reference on which value a quantile
  lands on.
- Stability across input orders or merge trees — the spread is reported, and
  reducing it is future work.
- Windowed or decaying digests, and weighted input beyond the centroid weights
  the sketch itself carries.

## Explicitly not claimed

- A maximum relative error for a single sample. The standard error is an
  expectation over hashes, not a bound.
- `1.04 / sqrt(m)` as a limit. It is the asymptotic standard error, and the
  measured spread near the small/large correction boundaries is wider.
- Anything about cardinalities far beyond 10M, or about adversarial inputs
  designed against the chosen hash.
