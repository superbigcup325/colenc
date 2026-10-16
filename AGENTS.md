# colpack — AGENTS.md

This is a [MoonBit](https://docs.moonbitlang.com) project.

colpack is a pure-MoonBit, zero-FFI **columnar encoding kernel** — the Parquet
page-level encoding family as a reusable, verifiable, pluggable library.
moonlake is its first consumer.

Read [`docs/ROADMAP.md`](docs/ROADMAP.md) first: it carries the design, the
milestone plan and the acceptance criteria this repo is built around.

## Status

Design settled; at **P0 (acceptance harness)**. No code yet — do not assume any
package described below exists.

## Layout

Published (tracked) today:

```
AGENTS.md  README.md  CHANGELOG.md  LICENSE
moon.mod                 module manifest
docs/ROADMAP.md          the public roadmap
.githooks/               pre-commit gate
.github/workflows/       CI gate
.gitignore .moonignore .gitattributes
```

Planned — no packages exist yet, so treat this as the target structure the
first commits should land in:

```
primitives/   # L1: varint / zigzag / bit packing and unpacking / bit width / cursors
encoders/     # L2: one file per encoding family, each with its property / battery tests
facade.mbt    # L3: dispatch — Encoding / EncodingStats / column-vector conversion
harness/      # acceptance rig: Python reference generation and diffing, minimal writer
```

- MoonBit packages are organized per directory, one `moon.pkg` each; `moon.mod`
  at the top level
- Blackbox tests are `*_test.mbt`, whitebox tests `*_wbtest.mbt`
- Adding an encoding family touches four places: a new file + its tests + the
  `Encoding` branch in `facade` + a row in the README table

## Tooling

- `moon check` / `moon test` / `moon fmt` / `moon info` / `moon run`
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
   package (test-time `moonbitlang/quickcheck` is fine)
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

(To be filled as work lands; format: symptom → root cause → the fix to reuse)

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

The acceptance rig (`harness/`) does not exist yet; its commands will be added
here as P0 lands.
