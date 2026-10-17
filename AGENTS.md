# colpack — AGENTS.md

This is a [MoonBit](https://docs.moonbitlang.com) project.

colpack is a pure-MoonBit, zero-FFI **columnar encoding kernel** — the Parquet
page-level encoding family as a reusable, verifiable, pluggable library.
moonlake is its first consumer.

Read [`docs/ROADMAP.md`](docs/ROADMAP.md) first: it carries the design, the
milestone plan and the acceptance criteria this repo is built around.

## Status

Design settled; **P0 is complete**, and **P1 is in progress**: the `primitives`
package (ULEB128 / zigzag varints, bit packing and unpacking, bit width) has
landed with whitebox and property tests. Next are PLAIN, the RLE/bit-packed
hybrid and the dispatch skeleton. Encoder packages do not exist yet.

## Layout

Published (tracked) today:

```
AGENTS.md  README.md  CHANGELOG.md  LICENSE
moon.mod                 module manifest
docs/ROADMAP.md          the public roadmap
primitives/              L1: varint / zigzag / bit packing / bit width
harness/                 acceptance rig: Python judges, fixtures, minimal writer
.githooks/               pre-commit gate
.github/workflows/       CI gate
.gitignore .moonignore .gitattributes
```

Planned — no packages exist yet, so treat this as the target structure the
first commits should land in:

```
encoders/     # L2: one file per encoding family, each with its property / battery tests
facade.mbt    # L3: dispatch — Encoding / EncodingStats / column-vector conversion
```

- MoonBit packages are organized per directory, one `moon.pkg` each; `moon.mod`
  at the top level
- Blackbox tests are `*_test.mbt`, whitebox tests `*_wbtest.mbt`
- Adding an encoding family touches four places: a new file + its tests + the
  `Encoding` branch in `facade` + a row in the README table

## Tooling

- `moon check` / `moon test` / `moon fmt` / `moon info` / `moon run`
- Whitebox tests are `*_wbtest.mbt`, blackbox tests `*_test.mbt`; blackbox
  tests refer to the package under test by alias (`@primitives.bit_pack`), and
  test-only imports live in a `for "test"` block in `moon.pkg`
- Acceptance rig (see `harness/README.md`):
  `python3 harness/make_refs.py [--check]` regenerates or verifies the fixtures,
  `python3 harness/extract_pages.py <parquet> --out <dir>` carves pages,
  `python3 harness/diff_bytes.py ours.bin ref.bin` reports the first divergence,
  `harness/duck_read.sh <parquet> [--values ref.bin]` runs both judges
- `moon run harness/writer_min -- <out.parquet>` writes the minimal container
- **Before committing**, run the quartet:
  `moon info && moon fmt && moon check --deny-warn && moon test`
- `.githooks/pre-commit` enforces the non-mutating half of that gate
  (`moon check --deny-warn`, `moon fmt --check`); enable it once per clone with
  `git config core.hooksPath .githooks`. CI (`.github/workflows/ci.yml`) runs the
  same gate on both wasm-gc and native.
- Backend differences must be tested explicitly: the default local target does
  not cover native, so anything touching bytes or buffers needs
  `moon test --target native`

## Coding convention

- Block style, blocks separated by `///|`
- Hot loops use unchecked access (indices are constructed by the encoder);
  every unchecked path gets a battery guard
- Everything little-endian; no platform branches; no FFI
- Decoding errors are typed errors carrying an offset ("byte N, item M"), never
  a panic

## Hard rules (read before touching code)

1. **Zero FFI**: no C/C++/Rust bindings; DuckDB is a **test-time judge** only,
   never in the runtime
2. **Zero runtime dependencies**: the library itself depends on no third-party
   package (test-time `moonbitlang/quickcheck` is fine). `moonbitlang/x` is
   declared for `harness/writer_min` only: no library package may import it,
   and `harness/` is excluded from the release archive
3. **Not in scope**: byte-stream compression (DEFLATE / ZSTD / Snappy / Brotli /
   LZ4), full nested-type levels, and a public Parquet-container API — all v1
   boundaries, see `docs/ROADMAP.md` §6
4. **Criteria must not be weakened**: a new encoding passes all three layers
   (round-trip + byte diff + container interop); if it cannot, demote it to the
   roadmap and say so in the README — never pass it silently, never move the
   goalposts to fit an implementation
5. **Choice bits must match the reference implementation** (RLE's run-selection
   heuristic, the dictionary threshold and bit-width derivation, DELTA's block
   128 / miniblock 4) — if they drift, byte diffing becomes meaningless
6. **Don't change criteria definitions unilaterally**; when genuinely needed,
   record the decision (who decided, why) before implementing
7. **The acceptance rig is the foundation**: do not pile encodings on top until
   P0 passes (see `docs/ROADMAP.md` §3)

## Keeping the published tree clean

This repository is public: everything tracked here is readable by anyone, and
tracked documents ship in the release archive.

- Write tracked documents and comments in **English**
- Keep local-only working material under a dot-prefixed directory, where it is
  neither tracked nor packaged; never reference such material from a tracked
  file (a cloner will not have it)
- `.gitignore` / `.moonignore` carry only build residue and test data. Git's
  `.git/info/exclude` is never consulted when packaging, so it is not a
  secrecy layer
- Before pushing or publishing, read the archive contents with
  `moon package --list` and confirm nothing local-only is in it

## Known Pitfalls

- **Fixture payload carries definition levels** → pyarrow fields default to
  nullable, so `max_definition_level = 1` and a V1 body starts with a 4-byte
  length plus an RLE level section → declare fixtures as `nullable=False`;
  required flat columns have no level bytes, so the payload is the value stream
- **pyarrow silently falls back to PLAIN** when an encoding cannot be applied →
  a fixture that never exercised its encoding would weaken every byte diff →
  read back `metadata.row_group().column().encodings` and fail the generator
- **`ColumnChunkMetaData.file_offset` is 0** (the field is deprecated) → start
  the page walk at `min(data_page_offset, dictionary_page_offset)` and trust
  `total_compressed_size`; header and body must tile the chunk exactly or the
  Thrift parse desynchronized
- **Reference bytes drift with pyarrow** → run-selection heuristics, dictionary
  thresholds and `created_by` are writer-version dependent → pin pyarrow in
  `harness/requirements.txt` and bump it only together with regenerated
  fixtures
- **V1 level prefix is a length of the section, not the page** → each section
  is `u32le length` + that many bytes, repetition first, and a section is
  absent entirely when its max level is 0
- **A nested Thrift struct must be self-contained** → compact-protocol field
  ids are deltas relative to the enclosing struct, so build each nested struct
  into its own buffer and append its bytes as the struct field payload; a
  struct writer that shares the parent's last-id state corrupts the parent
- **Footer sizes are asymmetric** → `total_compressed_size` and
  `total_byte_size` count the page header plus the body, while
  `PageHeader.uncompressed_page_size` counts the body alone; the footer length
  before the trailing `PAR1` is a plain `u32le`, not a varint
- **`moon fmt --check` arms itself with the first package** → the pre-commit
  hook and CI skip the format half only while no `moon.pkg` exists; run
  `moon fmt` before committing once packages land
- **Prefer prelude and non-deprecated core APIs** → `Buffer()` replaces
  `@buffer.new()`, and `String::to_bytes` is deprecated in favour of
  `@utf8.encode`; `--deny-warn` turns both into build failures

## Command reference

```bash
moon version              # toolchain self-check
moon check                # type-check
moon test                 # test suite
moon test --target native # required for backend-differing paths
moon info && moon fmt     # refresh interfaces, format

# pre-commit gate
moon info && moon fmt && moon check --deny-warn && moon test
```

The acceptance rig's Python side lives in `harness/`; its setup, commands and
the fixture contract are documented in `harness/README.md`.
