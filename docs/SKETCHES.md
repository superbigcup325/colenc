# Sketches: approximate aggregations

colenc's page encodings are judged by round trip, byte identity against the
reference writer, and container interop ([roadmap](ROADMAP.md) §4). A sketch has
no reference byte stream: no Parquet writer emits a HyperLogLog register array,
so byte identity has nothing to compare against. The family is therefore a
declared exception in the sense of §4 — the same position E7 FSST occupies — and
its criteria are properties plus a statistical rig, written here before any
implementation.

Which sketches and in what order is recorded in [next steps](NEXT-STEPS.md):
HLL first, t-digest after it. This document carries the HLL contract; the
t-digest section is added when that package starts.

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
- **Dense registers only.** One register per byte, `m` bytes. The sparse
  representation a production HLL++ carries is not in v1: it exists to make small
  cardinalities cheap, and it doubles the state machine. That is a scope
  decision, recorded here rather than discovered later.
- The estimator is the classical HyperLogLog one with the small-range (linear
  counting) and large-range corrections. **No empirically fitted bias tables**:
  those are calibrated against a training corpus, and colenc cannot honestly
  claim a calibration it has not run.

### Hashing

A 64-bit hash, pure MoonBit, chosen so that the same input hashes to the same
bits on native, wasm-gc and JS — the register update uses `Int64` arithmetic and
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

- construction from a precision, and a default-precision constructor
- `add` for the scalar types a column carries, and `add_bytes` for `ByteArray`
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

1. **Error at the default precision.** Cardinalities 1, 10, 1k, 100k, 1M and
   10M, each with several fixed seeds, asserting the relative error is inside
   `1.96 * 1.04 / sqrt(m)` and reporting the worst deviation observed. The
   bound is a confidence interval, not a guarantee; the worst case is reported
   so a reader can see the spread rather than only the pass.
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

### Explicitly not claimed

- A maximum relative error for a single sample. The standard error is an
  expectation over hashes, not a bound.
- `1.04 / sqrt(m)` as a limit. It is the asymptotic standard error, and the
  measured spread near the small/large correction boundaries is wider.
- Anything about cardinalities far beyond 10M, or about adversarial inputs
  designed against the chosen hash.
