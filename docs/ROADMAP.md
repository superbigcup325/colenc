# colpack · Roadmap

> A pure-MoonBit, zero-FFI **columnar encoding kernel**: the column encodings an
> analytical engine needs, packaged as a reusable, verifiable, pluggable library
>
> Peer references: Parquet's `parquet-encoding` crate, DuckDB's built-in encoders
> License: Apache-2.0

**Status (2026-10)**: project scoped, design settled; **P0 through P4 complete in this package** — every v1 encoding family sits behind the facade dispatch, E1 to E6 are byte-identical to the reference, E7 round-trips with its scoreboard measured, and CI runs the three-backend matrix plus the byte-diff and container jobs
**Integration (P5)**: validated against moonlake on a local branch — the Parquet reader routed through colpack, a write path added, and the spill format re-encoded (8.08 → 4.86 MiB on the bake-off workload). It is not merged, and this package is not published yet
**Next step**: publish the package, land the consumer integration, then phase two — bitmap indexes and approximate aggregations

---

## 0. What this is

An analytical engine hands colpack a column of values; colpack produces or restores bytes through pluggable encoding families

The library itself only touches memory buffers (`BytesView` / `Buffer`) — no IO, no file format, no query logic

Three capabilities are why it exists:

- **Value-range narrowing**: pack an Int64 column down to N bits based on its actual range
- **Locality exploitation**: monotonic columns via DELTA, low-cardinality columns via dictionary, floats via byte-plane split
- **Verifiability**: every encoding can be diffed byte-for-byte against a reference implementation and read back in full by DuckDB, and those criteria never regress as the implementation evolves

Terminology: "columnar encoding" in this document always means **intra-column compression** (range narrowing / dictionary / delta / bit packing), never byte-stream compression (the DEFLATE / ZSTD / Snappy / Brotli / LZ4 layer). The two are different layers and can be stacked

## 1. Is / is not

| Is | Is not |
|---|---|
| A columnar encoding kernel (value sequence ⇄ encoded bytes) | A general compression library (bytes in, bytes out) |
| A pluggable set of encoding families behind one interface | A file-format library (no metadata / footer / page directory) |
| Pure MoonBit, zero FFI, identical on native and wasm-gc | A query engine (no planning / execution / optimization) |
| An engineering artifact with objective criteria | An experimental prototype (every encoding must be read back by the judge) |

### The seam with neighbours

| Neighbour | What it does | Where the seam is |
|---|---|---|
| Parquet container library (e.g. `mizchi/parquet`) | file structure, footer, page organization | it owns the container, colpack owns **page-level encoding** — complementary |
| Arrow IPC library (e.g. `MoonArrow`) | inter-process format read/write | IPC is an inter-process format; column encoding is intra-page compression — different layers |
| Byte-stream compressors (DEFLATE / Brotli / ZSTD / gzip family) | compress **bytes** | different layers, composable (column-encode first, then byte-stream compress) |
| Columnar execution engines (e.g. `moonlake`) | planning / execution / optimization | colpack is their storage substrate; the dependency is one-way |

## 2. Encoding family roadmap

Physical types: `Int32` / `Int64` / `Float` / `Double` / `ByteArray` / `Bool`

| # | Family | Applies to | Criteria strength | Status |
|---|---|---|---|---|
| E0 | PLAIN | all | round-trip + container interop | planned |
| E1 | RLE / bit-packed hybrid | Int32/Int64/Bool + levels | round-trip + byte diff | planned |
| E2 | Dictionary | low-cardinality ByteArray/Int | round-trip + byte diff | planned |
| E3 | DELTA_BINARY_PACKED | Int32/Int64 | round-trip + byte diff | planned |
| E4 | DELTA_LENGTH_BYTE_ARRAY | ByteArray | round-trip + byte diff | planned |
| E5 | DELTA_BYTE_ARRAY | ByteArray (shared prefixes) | round-trip + byte diff | planned |
| E6 | BYTE_STREAM_SPLIT | Float/Double | round-trip + byte diff | planned |
| E7 | FSST | ByteArray (high-cardinality short strings) | round-trip + compression scoreboard | planned, see the §4 exception |

E0–E6 follow the Parquet spec; **choice bits align with the reference implementation** (RLE's run-selection heuristic, the dictionary threshold and bit-width derivation, DELTA's block 128 / miniblock 4). If the choice bits drift, byte diffing becomes meaningless — so these rules are spelled out one by one in the README

E7 FSST is not a native Parquet encoding, so its criteria are downgraded (§4)

## 3. Stage plan

Every stage has deliverables and an exit criterion, and **no stage starts until the previous one exits**

| Stage | Deliverable | Exit criterion |
|---|---|---|
| **P0** acceptance rig | `harness/`: reference-sample generation, page extraction, byte diffing, a minimal Parquet writer, DuckDB read-back | ① reference extraction is reproducible ② a file we assemble is read back by DuckDB with equal values ③ the extractor can carve out RLE / dictionary / DELTA / BYTE_STREAM_SPLIT pages |
| **P1** framework + E0 + E1 | `primitives/` (varint / zigzag / bit packing / bit width) + PLAIN + RLE hybrid bit packing + the dispatch skeleton | round-trip property and boundary battery all green; E1 byte-identical to the reference implementation; container interop end to end |
| **P2** dictionary | dictionary-page construction + packed indices + threshold fallback | round-trip + byte diff (rules stated explicitly) + a compression ratio for low-cardinality columns |
| **P3** delta family | E3 / E4 / E5 | all three round-trip + byte diff; monotonic-column ratios on the scoreboard |
| **P4** E6 + E7 | BYTE_STREAM_SPLIT + FSST | E6 full criteria; E7 round-trip + scoreboard |
| **P5** integration | consumed by a columnar engine: read-side hookup, write-side additions, spill serialization switched to encodings | consumer regression all green + on-disk size and IO gains recorded |

P0 is the feasibility precondition: if the acceptance rig cannot be made to work, the whole "use a reference implementation as judge" route does not hold, the design needs re-evaluation, and no encodings get piled on top

## 4. The acceptance system

Three layers, each stricter than the last:

| Layer | Means | Exit |
|---|---|---|
| Property | `moonbitlang/quickcheck` round-trip properties (random data covering extremes / empty / all-equal / monotonic / shuffled / very long runs / bit width 0) + a boundary battery | all green, never regressing as the implementation evolves |
| Byte | **byte-level diff** against a reference implementation's output (deterministic encodings; choice-bit rules stated explicitly) | byte-for-byte identical |
| Container | a Parquet file we wrote is read back in full by DuckDB with every value equal (relative tolerance 1e-9); tested in reverse too | provable end to end |

Criteria must not be weakened: a new encoding passes all three layers; if it cannot, it is demoted to the roadmap and declared in this document — the criteria are never bent to fit the implementation

Declared exception:

- **E7 FSST**: Parquet has no native FSST, so the byte and container layers do not apply; downgraded to round-trip properties + a compression-ratio / throughput scoreboard

## 5. Scoreboard definitions

- **Compression ratio**: bytes relative to a PLAIN baseline, broken out by column kind (monotonic integer columns / high-cardinality string columns / dictionary-friendly low-cardinality columns / float columns)
- **Throughput**: encode and decode MB/s, listed **separately for native and wasm-gc**
- **Integration regression**: the consumer's golden tests stay green

## 6. Explicitly deferred

Not in v1 (the boundary is written down to stop scope creep):

- **Byte-stream compression** (GZIP / ZSTD / Snappy / LZ4 / Brotli) — another layer
- **Full definition / repetition levels for nested types** — v1 handles flat columns only; the interface is reserved but not implemented
- **The Parquet container as a public API** — the acceptance rig's minimal writer makes no stability promise
- **SIMD kernels** — scalar + lookup tables to get the criteria passing first; vectorization is phase two
- **Page-level index / Bloom filter / encryption / column statistics**

Phase-two directions: bitmap indexes (Roaring format, cross-checked against the C/Java implementations file by file) and approximate aggregations (HLL / t-digest with property-tested error bounds)

## 7. Engineering conventions

- Zero FFI, zero runtime dependencies (quickcheck allowed at test time; DuckDB is a test-time judge only)
- Everything little-endian, no platform branches; native / wasm-gc / js behave identically
- Decoding errors are typed errors carrying an offset (able to say "byte N, item M"), never a panic
- Pre-commit gate: `moon info && moon fmt && moon check --deny-warn && moon test`

---

*This document is the public roadmap; it is updated as stages progress*
