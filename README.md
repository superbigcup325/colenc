# colenc

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
as a reusable, verifiable, pluggable library. Pure MoonBit, zero FFI, zero
runtime dependencies (quickcheck at test time only).

colenc takes a column of values and produces or restores bytes. It owns
**intra-column** encodings (range narrowing, dictionaries, deltas, bit packing);
it never touches files, containers or query plans, and it is not a byte-stream
compressor.

- Design, milestones and acceptance criteria: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- Next work packages and exit criteria: [`docs/NEXT-STEPS.md`](docs/NEXT-STEPS.md)
- Sketch contracts and their acceptance criteria: [`docs/SKETCHES.md`](docs/SKETCHES.md)
- Acceptance rig: lives in the source repository under `harness/` (not shipped in
  the package); the summary is below
- Throughput scoreboard: [`docs/scoreboard.md`](docs/scoreboard.md)
- License: [Apache-2.0](LICENSE)

## Status

Every v1 encoding family is in place. E0–E6 are byte-identical to the reference
implementation (parquet-cpp through pyarrow); E7 is measured by round trip and a
compression scoreboard because Parquet has no native FSST. CI runs the
three-backend test matrix (native, wasm-gc, js) plus the acceptance jobs:
fixture reproducibility, byte diffs for every family, and container interop with
DuckDB and pyarrow as judges.

Phase two has started with the bitmap index: a Roaring bitmap (E8) that is
byte-identical to CRoaring, including its container choices and the run
optimisation, judged by pyroaring instead of parquet-cpp.

Phase two also includes HyperLogLog and t-digest in the dedicated `sketches`
package, first published in 0.1.1. Their properties and statistical/empirical accuracy
gates are recorded in [the sketch contracts](docs/SKETCHES.md). Release
follow-through and conditional library work are planned in
[the current next steps](docs/NEXT-STEPS.md).

Version 0.1.2 adds the bitmap dispatch separation, PLAIN and dictionary
optimizations, compact HLL state, bitmap query methods, t-digest compression
work and reusable FSST models. The [changelog](CHANGELOG.md#012---2026-10-26)
records the migration from 0.1.1.

Integration with [moonlake](https://github.com/superbigcup325/moonlake) is
merged on its `main`: Parquet decoding routed through colenc, a new write path,
and the spill format re-encoded (40% smaller). The package is published as
`superbigcup325/colenc@0.1.2` on mooncakes, so a consumer resolves it from the
registry by version.

## Quick start

```bash
moon run examples/encode_demo
moon run examples/encode_demo | sort -t$'\t' -k4,4n
```

The demo encodes one column with every applicable family, decodes it back, and
prints `encoding/type`, value count, encoded bytes and the ratio to PLAIN.

## Build and test

```bash
moon check --deny-warn        # type-check, warnings are errors
moon test                     # wasm-gc, the default target
moon test --target native     # and js: backend-differing paths need both
moon package --list           # what a release archive would contain
```

## API

Three layers, each usable on its own: `primitives/` (varints, zigzag, bit
packing, bit width), `encoders/` (one file per family) and the facade
(`encode_column` / `decode_column`). The neutral `types` package carries
`ColBuf`, `PhysicalType`, `Encoding`, `EncodingStats` and `EncodingError`.

```moonbit
let column = @colenc_types.ColBuf::Int64s([1L, 4L, 9L])
let out = Buffer()
let stats = @colenc.encode_column(
  column, @colenc_types.DeltaBinaryPacked, out,
) catch {
  e => abort(@colenc_types.EncodingError::message(e))
}
let back = @colenc.decode_column(
  out.to_bytes(), @colenc_types.Int64, @colenc_types.DeltaBinaryPacked, 3,
)
```

Dictionary encoding has two output streams (dictionary page plus indices), so it
uses `encode_dictionary` / `decode_dictionary` instead of `encode_column`.
Column buffers are dense value arrays: NULL handling (definition levels) belongs
to the caller, which is what keeps the encoders page-shaped.

The bitmap index has its own type, because a bitmap index is queried, not just
decoded:

```moonbit
let left = @colenc_encoders.RoaringBitmap::from_ids([1, 2, 3, 100000])
let right = @colenc_encoders.RoaringBitmap::from_ids([3, 4, 100000])
let both = left.intersect(right)          // {3, 100000}
let bytes = left.to_bytes()               // portable Roaring
let back = @colenc_encoders.RoaringBitmap::from_bytes(bytes)
```

`encode_roaring_column` / `decode_roaring_column` are the column-shaped path.
They are deliberately not cases inside `encode_column` / `decode_column`: those
entry points refuse `Encoding::Roaring`, so a consumer that only ever passes a
page family never links the bitmap. `run_optimize` turns few-run containers into
runs first.

## Encodings

| # | Family | Applies to | Criteria | Choice bits aligned with the reference |
|---|---|---|---|---|
| E0 | PLAIN | all six physical types | round trip + container | length prefixes, LSB-first booleans |
| E1 | RLE / bit-packed hybrid | boolean values, dictionary indices | round trip + byte diff | eight-value buffering, 63-group literal cap |
| E2 | Dictionary | INT32/INT64/FLOAT/DOUBLE/BYTE_ARRAY | round trip + byte diff | first-appearance order, `max(1, bit_width_for(size-1))` |
| E3 | DELTA_BINARY_PACKED | INT32/INT64 | round trip + byte diff | block 128 (INT32) / 256 (INT64), four miniblocks |
| E4 | DELTA_LENGTH_BYTE_ARRAY | BYTE_ARRAY | round trip + byte diff | lengths as E3, then concatenated bytes |
| E5 | DELTA_BYTE_ARRAY | BYTE_ARRAY | round trip + byte diff | prefix lengths as E3, suffixes as E4 |
| E6 | BYTE_STREAM_SPLIT | FLOAT/DOUBLE | round trip + byte diff + container | one plane per byte position, little-endian |
| E7 | FSST | BYTE_ARRAY | round trip + scoreboard | colenc framing: symbol table, escape 255 |
| E8 | Roaring bitmap | INT32 ids (set semantics) | round trip + byte diff | array ≤ 4096 ids else bitmap; runs only when strictly smaller; offset-table rule |

E8 is the start of phase two: a bitmap index rather than a page encoding, so its
reference judge is CRoaring (through pyroaring) and not parquet-cpp.

## Scoreboard

Compression ratio against the PLAIN baseline on the fixture columns
(`harness/check_*.py` prints these, `examples/encode_demo` shows the same shape
live):

| Column | Encoding | Ratio to PLAIN |
|---|---|---|
| 1000 monotonic INT64 | DELTA_BINARY_PACKED | 0.3% |
| 1000 varied INT32 | DELTA_BINARY_PACKED | 27.0% |
| 8 distinct INT32 | Dictionary | 10.3% |
| 4 distinct strings | Dictionary | 3.4% |
| length-varied strings | DELTA_LENGTH_BYTE_ARRAY | 67.3% |
| shared-prefix strings | DELTA_BYTE_ARRAY | 9.0% |
| float/double columns | BYTE_STREAM_SPLIT | 100% (size neutral by design) |
| repetitive strings | FSST | 60.4% – 74.5% |
| 5000 dense INT32 ids | Roaring bitmap | 41.0% (15 bytes with runs) |
| 14198 ids across four containers | Roaring bitmap | 28.9% (61 bytes with runs) |
| a handful of ids | Roaring bitmap | over 100% — the header dominates |

FSST builds its symbol table from a bounded sample (64 KiB) and **stores raw
values when compression does not pay**, so the encoded column never exceeds the
raw size by more than one byte; on repetitive strings it lands at 60–75% of
PLAIN.

The demo encodes a different, smaller set of columns than the acceptance
fixtures, so its ratios differ from the table above while showing the same
shape.

Throughput lives in [`docs/scoreboard.md`](docs/scoreboard.md): on this machine
a release build reaches about 2.5 GB/s encoding and 3.6 GB/s decoding for
monotonic INT64 deltas on native, and about 1.2 GB/s / 1.4 GB/s on wasm-gc. The
scoreboard also carries the bitmap rows, where the set replaces a raw INT32 id
stream: a million sparse ids encode at 872 MB/s into 2.25 MB (56% of the id
stream), the same million consecutive ids take 131 KB as bitmap containers and
230 bytes once run-optimised, and reading a set back costs about 2.9 GB/s of
input ids. A sorted id column — the usual arrival order — is built container by
container in a single walk that also counts the distinct values of the key run,
and the two container arrays are sized from the key span up front; together
they lifted the sparse encode from 115 MB/s and the bitmap-container encode
from 1.0 to 1.6 GB/s.

## Boundaries (v1)

- **No byte-stream compression** (DEFLATE / ZSTD / Snappy / Brotli / LZ4): a
  different layer, composable after column encoding
- **Flat columns only**: definition/repetition levels are the caller's job
- **No public container API**: the acceptance rig has a minimal Parquet writer,
  but it is a judge target, not a promise
- **Dictionary fallback is per column** (returns `None`), not parquet-cpp's
  mid-column fallback
- **FSST framing is colenc's own**; Parquet has no native FSST, so no byte
  diff or container check applies, and the framing falls back to stored raw
  values when the table does not pay for itself
- **The Roaring bitmap is a set encoding**: a column is the set of its ids, so
  order and duplicates do not survive a round trip and a decode returns them
  ascending. Ids are non-negative INT32 (0..2^31-1); the format's upper u32 half
  needs a column type this model does not have yet and is rejected rather than
  truncated. Run containers are written only when `run_optimize` is asked for,
  matching the reference's incremental path, and decoding accepts them either
  way. It is a bitmap index, not a Parquet page encoding, so the container
  interop layer does not apply
- **Set operations return bitmaps that own their containers**: mutating a union
  or intersect result never rewrites an operand, and mutating an operand never
  rewrites an existing result
- **An `add` after `run_optimize` de-optimises the run container** into an array
  or bitmap, so that sequence is not byte-identical to CRoaring (which keeps the
  run); the criteria there are round trip plus the container invariants, not the
  byte diff. Call `run_optimize` again after a batch of adds to re-adopt runs
- **No SIMD kernels**: scalar + lookup tables first

## Neighbours and the seams

| Neighbour | What it does | The seam |
|---|---|---|
| Parquet container libraries (e.g. `mizchi/parquet`) | file structure, footer, page organization | they own the container, colenc owns page-level encoding |
| Arrow IPC libraries (e.g. `MoonArrow`) | inter-process format | IPC is a format, column encoding is intra-page compression |
| Byte-stream compressors (fzstd, flate, zlib, …) | compress bytes | different layer, usable after column encoding |
| Columnar engines (e.g. `moonlake`) | planning, execution | colenc is their storage substrate; the dependency is one-way |

## Acceptance

Three layers, each stricter than the last: property tests (round trip plus
boundary batteries on every backend), byte-level diffs against parquet-cpp
reference pages, and container interop where files we assemble are read back by
DuckDB **and** pyarrow with equal values.

The rig lives in the source repository under `harness/` and is not shipped in
the package: `make_refs.py --check` regenerates the fixtures, `check_rle.py`,
`check_dict.py`, `check_delta.py`, `check_bss.py` and `check_roaring.py`
byte-diff each family, `check_fsst.py` verifies the FSST round trip and ratio,
and `check_container.sh` runs the container interop end to end. CI runs all of
them on every push.

## Layout

```
types/        neutral model: PhysicalType / Encoding / ColBuf / errors
primitives/   L1: varint, zigzag, bit packing, bit width
encoders/     L2: PLAIN, RLE hybrid, dictionary, delta family, BSS, FSST, Roaring
sketches/     approximate aggregations: HyperLogLog and t-digest
facade.mbt    L3: encode_column / decode_column + dictionary entry points
examples/     runnable demo
harness/      acceptance rig: fixtures, byte diffs, containers, judges
docs/         public roadmap, and the throughput scoreboard
```

## License

Apache-2.0. See [LICENSE](LICENSE).
