# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
as a reusable, verifiable, pluggable library. Pure MoonBit, zero FFI, zero
runtime dependencies (quickcheck at test time only).

colpack takes a column of values and produces or restores bytes. It owns
**intra-column** encodings (range narrowing, dictionaries, deltas, bit packing);
it never touches files, containers or query plans, and it is not a byte-stream
compressor.

- Design, milestones and acceptance criteria: [`docs/ROADMAP.md`](docs/ROADMAP.md)
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

Integration with [moonlake](https://github.com/superbigcup325/moonlake) was
validated on a local branch: Parquet decoding routed through colpack, a new
write path, and the spill format re-encoded (40% smaller). The package is not
published to mooncakes yet, so the dependency is a workspace member for now.

## Quick start

```bash
moon run examples/encode_demo
moon run examples/encode_demo | sort -t$'\t' -k4,4n
```

The demo encodes one column with every applicable family, decodes it back, and
prints `encoding/type`, value count, encoded bytes and the ratio to PLAIN.

## API

Three layers, each usable on its own: `primitives/` (varints, zigzag, bit
packing, bit width), `encoders/` (one file per family) and the facade
(`encode_column` / `decode_column`). The neutral `types` package carries
`ColBuf`, `PhysicalType`, `Encoding`, `EncodingStats` and `EncodingError`.

```moonbit
let column = @colpack_types.ColBuf::Int64s([1L, 4L, 9L])
let out = Buffer()
let stats = @colpack.encode_column(
  column, @colpack_types.DeltaBinaryPacked, out,
) catch {
  e => abort(@colpack_types.EncodingError::message(e))
}
let back = @colpack.decode_column(
  out.to_bytes(), @colpack_types.Int64, @colpack_types.DeltaBinaryPacked, 3,
)
```

Dictionary encoding has two output streams (dictionary page plus indices), so it
uses `encode_dictionary` / `decode_dictionary` instead of `encode_column`.
Column buffers are dense value arrays: NULL handling (definition levels) belongs
to the caller, which is what keeps the encoders page-shaped.

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
| E7 | FSST | BYTE_ARRAY | round trip + scoreboard | colpack framing: symbol table, escape 255 |

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

FSST builds its symbol table from a bounded sample (64 KiB) and **stores raw
values when compression does not pay**, so the encoded column never exceeds the
raw size by more than one byte; on repetitive strings it lands at 60–75% of
PLAIN.

Throughput lives in [`docs/scoreboard.md`](docs/scoreboard.md): on this machine
a release build reaches about 2.3 GB/s encoding and 3.2 GB/s decoding for
monotonic INT64 deltas on native, and about 1.1 GB/s / 1.0 GB/s on wasm-gc.

## Boundaries (v1)

- **No byte-stream compression** (DEFLATE / ZSTD / Snappy / Brotli / LZ4): a
  different layer, composable after column encoding
- **Flat columns only**: definition/repetition levels are the caller's job
- **No public container API**: the acceptance rig has a minimal Parquet writer,
  but it is a judge target, not a promise
- **Dictionary fallback is per column** (returns `None`), not parquet-cpp's
  mid-column fallback
- **FSST framing is colpack's own**; Parquet has no native FSST, so no byte
  diff or container check applies, and the framing falls back to stored raw
  values when the table does not pay for itself
- **No SIMD kernels**: scalar + lookup tables first

## Neighbours and the seams

| Neighbour | What it does | The seam |
|---|---|---|
| Parquet container libraries (e.g. `mizchi/parquet`) | file structure, footer, page organization | they own the container, colpack owns page-level encoding |
| Arrow IPC libraries (e.g. `MoonArrow`) | inter-process format | IPC is a format, column encoding is intra-page compression |
| Byte-stream compressors (fzstd, flate, zlib, …) | compress bytes | different layer, usable after column encoding |
| Columnar engines (e.g. `moonlake`) | planning, execution | colpack is their storage substrate; the dependency is one-way |

## Acceptance

Three layers, each stricter than the last: property tests (round trip plus
boundary batteries on every backend), byte-level diffs against parquet-cpp
reference pages, and container interop where files we assemble are read back by
DuckDB **and** pyarrow with equal values.

The rig lives in the source repository under `harness/` and is not shipped in
the package: `make_refs.py --check` regenerates the fixtures, `check_rle.py`,
`check_dict.py`, `check_delta.py` and `check_bss.py` byte-diff each family,
`check_fsst.py` verifies the FSST round trip and ratio, and
`check_container.sh` runs the container interop end to end. CI runs all of them
on every push.

## Layout

```
types/        neutral model: PhysicalType / Encoding / ColBuf / errors
primitives/   L1: varint, zigzag, bit packing, bit width
encoders/     L2: PLAIN, RLE hybrid, dictionary, delta family, BSS, FSST
facade.mbt    L3: encode_column / decode_column + dictionary entry points
examples/     runnable demo
harness/      acceptance rig: fixtures, byte diffs, containers, judges
docs/         public roadmap
```

## License

Apache-2.0. See [LICENSE](LICENSE).
