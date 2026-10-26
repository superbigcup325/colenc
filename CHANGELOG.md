# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-10-26

### Changed

- `HllSketch` keeps its registers in whichever of two states is cheaper: the dense
  array of `m` bytes, or a sorted array of the live entries (one word each, the
  bucket index above the six-bit rank). A sketch starts sparse and promotes to
  dense once it carries more than `min(128, m / 8)` live registers — 128 at the
  default precision, 64 at precision 9, and never below precision 9, where the
  dense array is small enough that a second state would only add work. Nothing
  observable moves: the v1 serialized stream is the register vector, so the pinned
  bytes and their checksum are identical and `from_bytes` rebuilds whichever state
  the contents justify; the hash, the rank update, the estimator, the merge law
  and the public interface are unchanged, and so is every stored sketch. What
  changes is the resident cost of one sketch per group, which is what a grouped
  aggregate pays: 1000 groups of 10 distinct values drop from 24.5 MB to 12.6 MB
  of peak RSS, 20000 groups of 10 from 404.9 MB to 12.6 MB, and 50000 groups of 10
  from 992.4 MB to 12.6 MB, while the update of 1000 groups that each promote
  costs 23.3% more and a merge, `to_bytes` or a dense update are within noise of
  where they were (native release; the matrix and the operation deltas are in
  `docs/SKETCHES.md`, measured by the new `harness/hll_state.py`)

## [0.1.2] - 2026-10-26

### Migration from 0.1.1

Two changes are observable to code written against 0.1.1; serialized formats
(page encodings, Roaring, HLL, t-digest and FSST frames) are unchanged. They ship
in a 0.1.x release by the maintainer's decision, so a consumer that pins 0.1.1
and upgrades should apply the two items below.

- `encode_column` and `decode_column` refuse `Encoding::Roaring` with
  `Unsupported`. Use `encode_roaring_column` and `decode_roaring_column`, which
  take the same arguments and produce the same payload.
- `HllSketch::registers()` returns a snapshot taken at the call, not a live view
  of the sketch, and costs O(register_count) per call. Re-read it after updates,
  or use `HllSketch::register(index)` to read one rank without copying.

Everything else listed below is additive or an internal speedup with identical
output.

### Added

- `FsstModel`, `FsstModel::train` and `encode_fsst_with` separate training the
  FSST symbol table from encoding with it, so one table can encode many batches.
  `encode_fsst` output is unchanged: it trains a model on its own batch and
  encodes with it. The frame is the same and every batch still carries its table,
  so `decode_fsst` and old frames are unaffected. Training is most of a small
  batch's cost (36.6 of 39.5 us at 100 low-cardinality values, native release);
  encoding a held-out batch with a reused model took 28.5 ns per value there
  against 395 ns, with the same bytes. Across the measured shapes and sizes a
  reused model encoded 2.7 to 41 times faster per value, while the compressed
  size of a held-out batch ranged from 14% smaller to 7.0% larger depending on
  how well the training batch matched it.
- `RoaringBitmap::intersection_cardinality`, `RoaringBitmap::intersects` and
  `RoaringBitmap::ids_after`. The first two answer how many ids two bitmaps share
  and whether they share any without building the intersection, and `intersects`
  stops at the first shared id. `ids_after(after, limit)` returns up to `limit`
  ascending ids greater than `after` (start with `-1L`, continue from the last id
  returned; a short batch means the bitmap is exhausted) and keeps no state, so a
  changing bitmap cannot invalidate it. Portable bytes and existing operations are
  unchanged.
- `HllSketch::register(index)` reads one register's rank without copying and
  reports an out-of-range index as `OutOfRange`.

### Changed

- t-digest compression sorts only the raw buffer and merges it with the already
  ordered centroids instead of sorting every `(mean, weight)` tuple, and
  computes each centroid's lower scale value once. The centroid list is the same
  one the tuple sort produced, so serialized bytes, extremes and accuracy are
  unchanged. Native release, medians of three: 1M updates 88.5 to 51.9 ms, merge
  3.7 to 2.5 us.
- HyperLogLog registers are held as bytes. A precision-14 sketch carries 16 KiB
  of register state instead of 64 KiB; the hash, rank rule, estimator and the v1
  serialized bytes are unchanged. `HllSketch::registers()` keeps its type but
  now returns a snapshot built per call rather than a non-copying view of the
  live state; use `register(index)` to read ranks without that cost. Measured on
  native release (medians of three): 1000 groups of 1000 values 40.7 to 36.0 ms,
  `from_bytes` 10.5 to 7.4 us, `to_bytes` 7.3 to 5.9 us, and peak RSS of that
  grouped state 96.7 to 25.0 MB.
- Fixed-width PLAIN decoding reads one word per value and checks the count
  against the view length without multiplying first, so a count near 2^29 can no
  longer wrap the size check. Native release, 500k values: Int64 1991 to 236 us,
  Int32 666 to 152 us.
- Dictionary encoding stops as soon as the dictionary would pass
  `max_dictionary_bytes` instead of building it in full and comparing afterwards.
  Accepted dictionaries are byte-identical; refused columns return `None` sooner
  (500k distinct Int32 values 59.8 to 24.7 ms).

- The set encoding left the generic dispatch. `encode_column` and
  `decode_column` now refuse `Encoding::Roaring` with `Unsupported` instead of
  routing to the bitmap; `encode_roaring_column` and `decode_roaring_column`
  carry that path, with the same payload, the same errors and the same
  cardinality check. Keeping the bitmap out of the shared entry points costs one
  branch and buys the call graph: a consumer that only ever passes PLAIN, RLE,
  DELTA, the length family, dictionary, BSS or FSST no longer links the 1,137
  lines behind Roaring, so dead-code elimination can drop them. Measured
  downstream, where a spill format calls `encode_column` / `decode_column` for
  page families: wide CSV scans returned from about 10% slower than before the
  bitmap existed to parity (rotating interleaved A/B, ten pairs a side) and the
  consumer binary shrank by 8,248 bytes. Migration: replace
  `encode_column(column, Roaring, out)` with `encode_roaring_column(column, out)`
  and `decode_column(data, Int32, Roaring, count)` with
  `decode_roaring_column(data, Int32, count)`

## [0.1.1] - 2026-10-25

### Added

- Roaring bitmap (E8, phase two): `RoaringBitmap` with `from_ids`, `add`,
  `contains`, `cardinality`, `union`, `intersect`, `run_optimize` and the
  portable serialization (`to_bytes` / `from_bytes`, plus the
  `from_bytes_with_consumed` form for a stream that carries several), and the
  column-shaped path through `Encoding::Roaring`
- The portable layout is byte-identical to CRoaring through pyroaring: array
  containers while a container holds at most 4096 ids and bitmaps above that,
  run containers only when `run_optimize` finds the run form strictly smaller,
  and the offset table written whenever no container is a run and only for four
  or more containers otherwise. Decoding accepts run containers either way
- Two new `EncodingError` variants carry the offset: `OutOfRange` for an id
  outside 0..2^31-1 and `Corrupt` for a malformed bitmap structure
- Harness: `make_roaring_cases.py` (twelve cases, each asserting that its
  reference output really contains the container shapes it names) plus
  `check_roaring.py`, `roaring_probe/`, and pyroaring pinned as the reference
  judge
- Harness: `check_roaring_ops.py` and `roaring_ops_probe/` judge the bitmap
  sequences a byte diff cannot — round trip, container legality re-derived from
  the bytes, operand independence — with the layout pinned separately as a
  regression net rather than as a criterion
- Archive consumer acceptance (`harness/check_consumer.py`, `harness/consumer/`):
  unpacks the release archive into a throwaway module whose only members are the
  archive and a consumer, then runs that consumer on native, wasm-gc and JS
  against a fresh `MOON_HOME`, so the published surface is exercised without the
  working checkout, a local dependency cache or the repository-only harness.
  `--registry-version` checks the registry copy after a publish

- HyperLogLog (`sketches`): `HllSketch` with precisions 4 through 16 (default
  14), a typed entry point per column type, `merge`, `estimate`, and a
  versioned serialization. The hash is MurmurHash3 x64 128 (lower half, seed 0)
  over each value's canonical little-endian bytes, so the registers and the
  serialized form are identical on native, wasm-gc and JS. The estimator is the
  classical one with the linear-counting and large-range corrections; no fitted
  bias tables. The contract, including what the criteria do *not* claim, is
  `docs/SKETCHES.md`
- Harness: `hll_probe/` drives the sketch from the rig, and `check_hll.py` runs
  the four acceptance groups — the error spread over twenty seeds against
  `1.04/sqrt(m)` (bounded from above, because linear counting beats the
  asymptotic bound below `2.5m`), merge as a register algebra, serialization
  with the malformed states rejected, and the boundaries. Apache DataSketches'
  `datasketches` is pinned as the outside opinion on the estimate
- t-digest (`sketches`): `TDigest` with k1 scaling at `k = 100`, a raw buffer of
  `8k` values, alternating-direction compression, exact extremes carried through
  the byte stream, and `quantile` interpolating between centroid positions. The
  contract is `docs/SKETCHES.md`; the acceptance rig is
  `harness/check_tdigest.py`, which runs 4 distributions × 3 input orders × 3
  sizes against exact sorted data and gates on the structural layer and the
  absolute ceilings (1% interior, 0.5% tails), reporting the comparison against
  Apache DataSketches' t-digest rather than gating on it
- `EncodingError::InvalidArgument(String)`: a NaN or an infinity has no rank, a
  quantile outside 0..1 has no answer, and two different compression parameters
  cannot be merged; each is now rejected with the reason spelled out

### Changed

- **A bitmap probe searches its key array branchlessly.** Every `contains` walked
  the sorted key array with a branch per step, and a probe's path is not
  predictable. Measured in the rig's new `-- search` section on a 32768-key
  array: the branchy lower bound 36.8 ns per probe, an unchecked spelling 35.6 ns
  (so the bounds check was never the cost), the branchless form 13.1 ns. Probes
  of up to eight keys go linear instead, and the build path keeps the branchy
  search, where ascending inserts make the branch predictable: the same rewrite
  measured 26% to 90% *slower* on `add`. Interleaved pairs on a quiet host:
  `contains` -53% on the sparse column, -49% on the 1M column, -57% on 4096
  containers, -46% on 32768 one-value containers, -44% on misses, and `add`
  unchanged within noise on every case
- **Bitmap set operations merge the shapes they are given.** `union` and
  `intersect` turned both operands into 1024-bitmap-word arrays, ORed or ANDed
  them, and then enumerated the result back into values — even when the result
  was going to stay a bitmap, so a dense container paid to mirror 60k values it
  discarded. Two sorted array containers now merge value by value, an array
  against a bitmap filters the array, and the word path decides the result shape
  by popcount instead of enumerating. Interleaved median-of-three pairs on a
  quiet host: an array-container union 4489 -> 174 us (68.5 -> 2.7 ns per id,
  -96%), the same call on bitmap containers 253 -> 15 us (0.42 -> 0.026 ns per
  id, -94%), the mixed shape -51% to -65%, and the run path -18% to -21% from
  the dropped enumeration. The container shapes, the byte stream and the
  reference diff are unchanged; the operation-sequence checks and both
  container-mode byte diffs pass on all three backends

- Container bodies are no longer zero-filled before they are overwritten: the
  reader and the sorted build create each array with `Array::unsafe_make_uninit`
  and write every slot in the loop that follows. Zeroing a container costs
  about 7.5 ns at 30 values and 186 ns at 8 KB, which is a pass nobody reads.
  On `harness/perf`, four interleaved pairs on a quiet host put the 1M-value
  sparse read at 1519 -> 1371 us (-9.8%), a sparse array container at
  -9.6%, a set of 32768 one-value containers at -7.3% and the sorted build at
  -1.9% to -5.7%; every path this does not touch stayed within +-1%
- `RoaringBitmap::from_ids` builds a sorted id column key run by key run instead
  of one `add` per id, and sizes both container arrays from the key span between
  the first and the last id rather than growing them one push at a time. On
  `harness/perf` the sorted build is 7.3x faster than the incremental path on
  the sparse column (3068 -> 344 us for 100k ids), and reserving the arrays
  takes a wide-key set (32768 one-value containers) down another 16%. The shape
  rule is unchanged: it reads the distinct count of the whole key run, and the
  output stays byte-identical to pyroaring on every boundary case
- Reading a bitmap back now loads each body with the widest bulk read the
  toolchain provides instead of assembling values byte by byte, and the card
  table's value is counted in that same walk rather than by a second pass: one
  `unsafe_read_uint64_le` per 64-bit word, one `unsafe_read_uint16_le` per
  16-bit value. Every body is still range-checked once before the loop, which
  is what makes the loads safe. Measured with `harness/perf` as interleaved
  median-of-three A/B pairs on the same machine (`from_bytes`): a dense bitmap
  container -67.5%, mixed shapes -65.0%, the sparse column -14.2%, a sparse
  array container -19.9%, a wide-key set -3.4%. On wasm-gc the same A/B is
  -40.2% dense, -40.7% sparse-array, -19.8% wide keys and -2.4% on the 1M
  column. In `docs/scoreboard.md` the sparse column is the row that moves most,
  and the 300k-id dense row now decodes at over a hundred gigabytes per second
- Serializing a bitmap now plans before it writes: one walk over the containers
  collects each card, each body size and the run flags, adds up the exact byte
  count, and the buffer is created at that size, so nothing is re-derived and
  nothing is regrown. Measured with `harness/perf` (median of 7, `to_bytes`):
  dense container -22.8%, a set of 32768 one-value containers -19.5%, mixed
  shapes -28.3%, a 1M-value sparse column -7.2%. The same A/B on wasm-gc, run
  with the same binary before and after the change, is -13.8% to -33.1%
- Reading a bitmap back no longer pays a `roaring_read_u16` call and a length
  check per value: the key/card table, the offset table and each container body
  are each validated once and then walked with cursor arithmetic. On
  `harness/perf` `from_bytes` drops 37.9% on the sparse column (324 -> 202 us)
  and 26.3% on a wide-key set, and the scoreboard's sparse decode row went from
  1089 to 1889 MB/s on that change alone
- The sorted build now counts the distinct values of a key run in the same walk
  that finds the run, instead of a second pass over the ids: on `harness/perf`
  `from_ids` drops 13.4% on the sparse column (314 -> 272 us), 9.4% on the dense
  one and 9.3% on a wide-key set. The serialization path was measured as well
  and left alone — the per-value buffer writes are already near the floor of
  `Buffer::write_byte`, and sizing the buffer exactly from a computed length
  helped the dense cases but cost 6.5% on a 32768-container set, so it is not
  there
- Verified against MoonBit toolchain `0.1.20261016`: the library output is
  unchanged (all five byte-diff harness checks still match the reference byte
  for byte, the fixture manifest is still reproducible, and the encoded sizes
  in the scoreboard are identical), and `docs/scoreboard.md` was regenerated on
  it
- `python3 harness/scoreboard.py` now reports the median of three rounds per
  phase instead of one round, and its header says how noisy a single round is:
  on the small cases the same binary swings by 10-20% run to run, which is
  enough to invent a 20% "regression" when comparing two toolchains
- `moonbitlang/x` 0.5.5 → 0.5.6 (the harness-only dependency)

### Fixed

- `RoaringBitmap::union` no longer shares a container with either operand: the
  result owns a copy of every container it carries, so adding to the result
  cannot rewrite an input, and mutating an input cannot rewrite a result. The
  aliasing reached array, bitmap and run containers alike
- Adding an id to a run container whose cardinality already exceeded the
  4096-value array range produced an *array* container above that range. The
  writer serializes by container shape while the reader picks the shape from
  the cardinality, so the output could not be read back (a 5001-id bitmap
  serialized to 10018 bytes that no parse accepted). `add` now chooses the shape
  from the cardinality it produces, and a whitebox invariant checker (arrays at
  most 4096, bitmaps above, runs strictly smaller and disjoint) runs after mixed
  add / union / intersect / `run_optimize` sequences

## [0.1.0] - 2026-10-19

### Added

- Repository scaffold: `moon.mod`, `README.md`, `CHANGELOG.md` and the public
  roadmap in `docs/ROADMAP.md`
- Apache-2.0 license
- Pre-commit hook (`.githooks/`) and a CI gate (`.github/workflows/ci.yml`)
- Acceptance rig, Python half (`harness/`): reference sample generator with
  reproducibility check (`make_refs.py`), Thrift-compact page extractor
  (`parquet_pages.py`, `extract_pages.py`), byte differ with first-divergence
  reporting (`diff_bytes.py`), pinned judge versions and the reference samples covering
  PLAIN, RLE_DICTIONARY, DELTA_BINARY_PACKED, BYTE_STREAM_SPLIT and RLE
- Minimal Parquet writer in MoonBit (`harness/writer_min/`): Thrift compact
  metadata, one V1 data page, `PAR1` container; writes a required int32 column
  that DuckDB and pyarrow both read back with equal values
- Dual-judge read-back (`harness/read_back.py`, `harness/duck_read.sh`) so the
  container layer is checked by both readers and, when given, the expected
  PLAIN bytes
- `primitives` package: ULEB128 and zigzag varints with offset-carrying decode
  errors, contiguous LSB-first bit packing and unpacking, bit width from a
  maximum value; whitebox byte-level tests plus quickcheck round-trip
  properties for every width from 0 to 64
- `primitives` is the first library package; `moonbitlang/quickcheck` is a
  test-only dependency
- `types` package: the neutral column model (`PhysicalType`, `Encoding`,
  `ColBuf`, `EncodingStats`) and `EncodingError` with byte offsets
- PLAIN encoding and decoding for all six physical types (`encoders/plain.mbt`),
  with little-endian fixed-width values, length-prefixed byte arrays and
  LSB-first bit-packed booleans
- `facade.mbt`: `encode_column` / `decode_column`, keyed by `ColBuf`, reporting
  value count and bytes appended; unimplemented families raise `Unsupported`
- The minimal Parquet writer gains a `--library` mode that wraps the body
  produced by `encode_column`, and both modes produce identical files that
  DuckDB and pyarrow read back

- RLE / bit-packed hybrid (`encoders/rle.mbt`) with the reference implementation's
  run-selection heuristic: eight-value buffering, repeated runs from eight
  values, literal runs capped at 63 groups, end-flush padding. Byte-identical
  to parquet-cpp on boolean streams and dictionary indices
- Boolean RLE values carry the spec's 4-byte length prefix; the facade wires
  `Encoding::Rle` for boolean columns and reports `TypeMismatch` elsewhere
- Harness: `make_rle_cases.py` + `check_rle.py` + `rle_probe/` diff the
  library's stream against the reference, and `writer_min --rle` proves the
  container path with both judges

- CI: the test matrix now covers native, wasm-gc and js; a harness job checks
  fixture reproducibility, the RLE byte diff and container interop end to end

- Dictionary encoding (`encoders/dictionary.mbt`): first-appearance dictionary
  order, the reference bit-width rule, a PLAIN dictionary page and the hybrid
  index stream behind a one-byte width; per-column threshold fallback to PLAIN
- Harness: `make_dict_cases.py` + `check_dict.py` + `dict_probe/` byte-diff the
  dictionary page and the index stream; `writer_min --dict` proves the two-page
  container path with both judges
- First scoreboard numbers: the int32 fixture encodes to 10.25% of PLAIN and
  the string fixture to 3.38%

- Delta family (`encoders/delta.mbt`): DELTA_BINARY_PACKED with the reference
  block sizes (INT32 128, INT64 256, four miniblocks each), frame-of-reference
  deltas and per-miniblock widths; DELTA_LENGTH_BYTE_ARRAY and
  DELTA_BYTE_ARRAY built on it
- Harness: `make_delta_cases.py` + `check_delta.py` + `delta_probe/` cover both
  integer widths and both string encodings; `writer_min --delta` proves the
  container path with both judges
- Scoreboard: delta-packed int64 0.33% of PLAIN, int32 26.98%, delta length
  67.25%, delta byte array 9.03% on the fixtures

- BYTE_STREAM_SPLIT (`encoders/byte_stream_split.mbt`) for float and double:
  one plane per byte position, byte-identical to the reference and read back by
  both judges through the container
- FSST-style string compression (`encoders/fsst.mbt`): deterministic symbol
  table built from the column, greedy longest match, escape literals. Parquet
  has no native FSST, so the criteria are round trip and the scoreboard
- Harness: `make_bss_cases.py` + `check_bss.py` + `bss_probe/` for the byte
  diff, `check_fsst.py` + `fsst_probe/` for round trip and ratio
- Scoreboard: BYTE_STREAM_SPLIT is size-neutral by design; FSST reaches 60.38%
  and 74.51% of PLAIN on the two string fixtures

- A runnable demo (`examples/encode_demo`): encodes one column with every
  applicable family, decodes it back and prints bytes against the PLAIN
  baseline; the README now carries the encoding table, fixture scoreboard,
  boundaries and seam table
- FSST stores raw values when compression does not pay (never larger than the
  raw size by more than a byte) and builds its symbol table from a bounded
  sample, so high-entropy and large inputs stay cheap
- A throughput bench (`harness/bench`, `harness/scoreboard.py`) and
  `docs/scoreboard.md`: on the reference machine native reaches 2.3 GB/s
  encoding and 3.2 GB/s decoding for monotonic INT64 deltas; wasm-gc 1.1 and
  1.0 GB/s
- First consumer integration, on moonlake's `main` (read side, write path,
  spill re-encoding); it stays out of this package, which keeps a stable
  version-numbered surface

P0 through P4 are complete, and this is the first published release.

[Unreleased]: https://github.com/superbigcup325/colenc/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/superbigcup325/colenc/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/superbigcup325/colenc/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/superbigcup325/colenc/releases/tag/v0.1.1
[0.1.0]: https://github.com/superbigcup325/colenc/releases/tag/v0.1.0
