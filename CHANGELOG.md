# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- P5 was validated against moonlake in an unmerged branch (read side, write path,
  spill re-encoding); it is not part of this package and is not merged

P0 through P4 are complete; the package is ready to publish once the repository
link and the release are in place.
