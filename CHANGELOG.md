# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed

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

[Unreleased]: https://github.com/superbigcup325/colenc/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/superbigcup325/colenc/releases/tag/v0.1.1
[0.1.0]: https://github.com/superbigcup325/colenc/releases/tag/v0.1.0
