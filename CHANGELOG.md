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
  reporting (`diff_bytes.py`), pinned judge versions and six reference samples
  covering PLAIN, RLE_DICTIONARY, DELTA_BINARY_PACKED, BYTE_STREAM_SPLIT and
  RLE
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

PLAIN and the RLE/bit-packed hybrid are next. — the project is at P0, with the MoonBit minimal writer
still to land.
