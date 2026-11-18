# colenc · Roadmap

> A pure-MoonBit, zero-FFI **columnar encoding kernel**: the column encodings an
> analytical engine needs, packaged as a reusable, verifiable, pluggable library
>
> Peer references: Parquet's `parquet-encoding` crate, DuckDB's built-in encoders
> License: Apache-2.0

**Status (2026-10)**: project scoped, design settled; **P0 through P4 complete in this package** — every v1 encoding family sits behind the facade dispatch, E1 to E6 are byte-identical to the reference, E7 round-trips with its scoreboard measured, and CI runs the three-backend matrix plus the byte-diff and container jobs
**Integration (P5)**: merged into moonlake's `main` — the Parquet reader routed through colenc, a write path added, and the spill format re-encoded (8.08 → 4.86 MiB on the bake-off workload)
**Release**: `superbigcup325/colenc@0.1.4` is published on mooncakes (2026-11-09, tagged `v0.1.4`). It carries the Roaring portable-stream fixes, measured HLL CPU work, additive typed batch updates and `TDigest::quantiles`, with no serialized format or encoding choice bit changed. **0.1.3** (2026-10-26) added the sparse HyperLogLog state, and **0.1.2** (2026-10-26) shipped the Phase two surface: the Roaring index, the bitmap and key-search rewrites, the `sketches` package (HyperLogLog and t-digest), the bitmap dispatch separation and the K1 to K6 kernel work. The archive consumer check exercises the packaged surface — both sketches, the reusable FSST model, the bitmap query APIs and the generic refusal — on all three backends before and after a publication
**Phase two (P6)**: the bitmap index landed — E8 Roaring is byte-identical to CRoaring, container shapes and the run-optimisation rule included, judged by pyroaring
**Follow-through (2026-10-27)**: moonlake consumes the released 0.1.3 at `344d739` and published its accepted scope as 0.5.1 on 2026-10-27. The grouped-HLL cost refresh, sparse-state adoption and budgeted-GROUP-BY input work are complete. The scope previously called 0.6.0 was renumbered by that project's owner; no 0.6.0 publication remains pending. [The follow-through record](NEXT-STEPS.md) carries the current evidence and the join-to-aggregation delivery in 0.6.4, and [the implementation record](OPTIMIZATION-PLAN.md) retains the completed kernel scope and results. Sparse HLL shipped in 0.1.3 ([delivery record](NEXT-STEPS.md#sparse-hll-state-delivery-record), [cost table](SKETCHES.md#state-cost)); consumer FSST reuse and the Roaring index experiment retain their workload triggers. The engine work used the existing kernel
**Release follow-through (2026-11-09)**: 0.1.4 is published from `d7d0579`, tagged `v0.1.4`, and verified from the registry on all three backends. Issue #7 is closed. PR #2 through #10 are merged and issue #1 is closed. No serialized format or encoding choice bit changed. Issues #8 and #9 remain the consumer-led evidence gates for FSST model reuse and immutable-table Roaring. [Follow-through](NEXT-STEPS.md#post-release-status-2026-11-09) and the [K7 implementation record](OPTIMIZATION-PLAN.md#k7-post-release-cpu-and-query-measurements) carry the evidence and remaining triggers.

**Next work** follows the [post-0.1.4 plan](#8-work-after-014).

---

## 0. What this is

An analytical engine hands colenc a column of values; colenc produces or restores bytes through pluggable encoding families

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
| Parquet container library (e.g. `mizchi/parquet`) | file structure, footer, page organization | it owns the container, colenc owns **page-level encoding** — complementary |
| Arrow IPC library (e.g. `MoonArrow`) | inter-process format read/write | IPC is an inter-process format; column encoding is intra-page compression — different layers |
| Byte-stream compressors (DEFLATE / Brotli / ZSTD / gzip family) | compress **bytes** | different layers, composable (column-encode first, then byte-stream compress) |
| Columnar execution engines (e.g. `moonlake`) | planning / execution / optimization | colenc is their storage substrate; the dependency is one-way |

## 2. Encoding family roadmap

Physical types: `Int32` / `Int64` / `Float` / `Double` / `ByteArray` / `Bool`

| # | Family | Applies to | Criteria strength | Status |
|---|---|---|---|---|
| E0 | PLAIN | all | round-trip + container interop | done — container interop |
| E1 | RLE / bit-packed hybrid | Int32/Int64/Bool + levels | round-trip + byte diff | done — byte-identical |
| E2 | Dictionary | low-cardinality ByteArray/Int | round-trip + byte diff | done — byte-identical, per-column fallback |
| E3 | DELTA_BINARY_PACKED | Int32/Int64 | round-trip + byte diff | done — byte-identical |
| E4 | DELTA_LENGTH_BYTE_ARRAY | ByteArray | round-trip + byte diff | done — byte-identical |
| E5 | DELTA_BYTE_ARRAY | ByteArray (shared prefixes) | round-trip + byte diff | done — byte-identical |
| E6 | BYTE_STREAM_SPLIT | Float/Double | round-trip + byte diff | done — byte-identical |
| E7 | FSST | ByteArray (high-cardinality short strings) | round-trip + compression scoreboard | done — round trip + scoreboard, no byte diff (§4 exception) |
| E8 | Roaring bitmap | Int32 ids (a set, not a sequence) | round-trip + byte diff | done — byte-identical to CRoaring, both container modes |

E0–E6 follow the Parquet spec; **choice bits align with the reference implementation** (RLE's run-selection heuristic, the dictionary threshold and bit-width derivation, DELTA's blocks of 128 for INT32 and 256 for INT64, with four miniblocks each). If the choice bits drift, byte diffing becomes meaningless, so these rules are spelled out one by one in the README

E7 FSST is not a native Parquet encoding, so its criteria are downgraded (§4)

E8 is the first phase-two family: a bitmap index rather than a page encoding. It keeps the byte layer by aligning to CRoaring through pyroaring — container shape (array while a container holds 4096 ids, bitmap above), the run-optimisation rule (a run form only when strictly smaller) and the offset-table rule. It has no container-interop layer, because a bitmap index is not a Parquet page encoding, and no slot in the generic `encode_column` / `decode_column` dispatch: its own `encode_roaring_column` / `decode_roaring_column` entry points keep the bitmap out of the call graph of a consumer that only decodes page families

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
| **P6** bitmap index (phase two) | E8 Roaring: container shapes, run optimisation, portable serialization, set operations | round-trip properties green; every container shape byte-identical to CRoaring through pyroaring; the fixture generator proves each case still exercises the shape it names |
| **P7** sketches (phase two, implemented in 0.1.1) | Dedicated `sketches` package: HyperLogLog followed by t-digest | Recorded contracts in [SKETCHES.md](SKETCHES.md), register/serialization properties and the HLL statistical rig, then the t-digest structural and empirical-accuracy gates. Independent reference comparisons do not imply byte compatibility |

P0 is the feasibility precondition: if the acceptance rig cannot be made to work, the whole "use a reference implementation as judge" route does not hold, the design needs re-evaluation, and no encodings get piled on top

## 4. The acceptance system

Three layers, each stricter than the last:

| Layer | Means | Exit |
|---|---|---|
| Property | `moonbitlang/quickcheck` round-trip properties (random data covering extremes / empty / all-equal / monotonic / shuffled / very long runs / bit width 0) + a boundary battery | all green, never regressing as the implementation evolves |
| Byte | **byte-level diff** against a reference implementation's output (deterministic encodings; choice-bit rules stated explicitly) | byte-for-byte identical |
| Container | a Parquet file we wrote is read back in full by DuckDB with every value equal (relative tolerance 1e-9); tested in reverse too | provable end to end |

Criteria must not be weakened: a new encoding passes all three layers; if it cannot, it is demoted to the roadmap and declared in this document — the criteria are never bent to fit the implementation

Declared exceptions:

- **E7 FSST**: Parquet has no native FSST, so the byte and container layers do not apply; downgraded to round-trip properties + a compression-ratio / throughput scoreboard
- **Approximate aggregations (HLL, t-digest)**: no Parquet writer emits a sketch, so there is no reference byte stream to diff and no decode path to round-trip through. Criteria are properties plus a statistical rig, recorded in [sketches](SKETCHES.md) before the implementation starts
- **E8 Roaring**: the bitmap is an index, so the Parquet container layer does not apply. Round-trip properties and byte diffs against CRoaring apply to the reference-aligned paths. As documented in the README and harness, sequences such as adding after `run_optimize` can produce legal bytes different from CRoaring; those paths are judged by round trip, container invariants derived from the bytes and operand independence, with a separate layout regression pin

## 5. Scoreboard definitions

- **Compression ratio**: bytes relative to a PLAIN baseline, broken out by column kind (monotonic integer columns / high-cardinality string columns / dictionary-friendly low-cardinality columns / float columns)
- **Throughput**: encode and decode MB/s, listed **separately for native and wasm-gc**
- **Bitmap timing**: the current Roaring decode timer covers `from_bytes` plus `cardinality`, with MB/s normalized to the raw INT32 id size. Expanding the bitmap with `to_array` is outside that timer and needs a separate measurement
- **Integration regression**: the consumer's golden tests stay green

## 6. Explicitly deferred

Not in v1 (the boundary is written down to stop scope creep):

- **Byte-stream compression** (GZIP / ZSTD / Snappy / LZ4 / Brotli) — another layer
- **Full definition / repetition levels for nested types** — v1 handles flat columns only; the interface is reserved but not implemented
- **The Parquet container as a public API** — the acceptance rig's minimal writer makes no stability promise
- **SIMD kernels** — scalar + lookup tables to get the criteria passing first; vectorization is phase two
- **Page-level index / Bloom filter / encryption / column statistics**

Phase two, in progress:

- **Bitmap indexes** — Roaring format, cross-checked against the C/Java implementations file by file. Landed as E8 / P6: portable serialization byte-identical to CRoaring, container shapes and the run-optimisation rule aligned, set operations in place
- **Approximate aggregations**: HLL and t-digest are implemented in `sketches` and published in 0.1.1, with their contracts recorded before implementation. The HLL carries a dense and a sparse register state behind one format, and its rigs judge statistical error, register merge laws, serialization and the per-group state cost; the t-digest rig gates structure and absolute empirical rank-error ceilings while reporting the independent-reference comparison and order/merge spread. SQL adoption belongs to the consumer. See [sketches](SKETCHES.md) and [Next steps](NEXT-STEPS.md) for the current work order

## 7. Engineering conventions

- Zero FFI, zero runtime dependencies (quickcheck allowed at test time; DuckDB is a test-time judge only)
- Everything little-endian, no platform branches; native / wasm-gc / js behave identically
- Decoding errors are typed errors carrying an offset (able to say "byte N, item M"), never a panic
- Pre-commit gate: `moon info && moon fmt && moon check --deny-warn && moon test`

## 8. Work after 0.1.4

The moonlake 0.6.4 checkout at `025f3b3` pins colenc 0.1.3. The registry
comparison and the decoder boundary work do not depend on each other, so either
can start first; the performance baseline is refreshed before any hot path is
measured. The consumer-side changes land in moonlake's repository, the kernel
changes and their fixtures land here. These items are candidates for the next
release, chosen because the specification and the consumer's read path ask for
them, not because a release is complete.

### Adoption and correctness

1. **Verify moonlake against colenc 0.1.4.** Build the same moonlake revision
   with registry copies of 0.1.3 and 0.1.4 on the same toolchain. Run the SQL
   goldens, Parquet page and spill coverage on native, wasm-gc and js. On
   native release, compare grouped HLL with the exact and decode-only controls
   in moonlake's `harness/bench_hll.py`, and compare wide CSV and Parquet scans
   with moonlake's `harness/bench_release.py`. Record the resolved dependency,
   the answers or answer fingerprints, time and peak RSS. Adopt 0.1.4 once
   correctness passes and any reproducible regression is resolved.
2. **Check decoder sizes before arithmetic.** Cover oversized declarations and
   truncated bodies in BYTE_STREAM_SPLIT and DELTA_LENGTH_BYTE_ARRAY. The
   fixed-width PLAIN decoders are the reference: compare the count against the
   available bytes instead of multiplying first, so `count * 4` and `count * 8`
   cannot wrap in `decode_byte_stream_split_float` / `_double`, and the running
   position in `decode_delta_length_byte_array` cannot overflow ahead of its
   range check. A rejected input is a typed error carrying an offset on all
   three backends, never a panic, and the accepted outputs and consumed lengths
   stay equal to the release fixtures.

### Features

1. **Extend BYTE_STREAM_SPLIT to INT32 and INT64.** The integer types are
   already in `ColBuf`, and moonlake's integer page readers currently accept
   DELTA_BINARY_PACKED as their extended encoding. Parquet specifies
   BYTE_STREAM_SPLIT for both integer types.
   [Parquet encoding specification](https://parquet.apache.org/docs/file-format/data-pages/encodings/)

   The judge is the open question, not the format. The first deliverable is a
   probe that records what the pinned writer does with integer pages, signed
   extremes included, and what each judge reads back, because a byte-layer
   claim is only as good as that record. If the pinned DuckDB refuses integer
   BYTE_STREAM_SPLIT, the container layer has no judge until an upgrade, and
   that upgrade is verified on its own against the current fixture and
   container jobs, moving the pin in `harness/requirements.txt` in the same
   step.

   Then extend the encoder, decoder and facade, the fixtures
   (`harness/make_bss_cases.py` and `harness/check_bss.py`), the E6 row in the
   family table and the README table, and require round trips on three
   backends, exact bytes against PyArrow and two-way container interop.
   Exercise both integer types in the moonlake Parquet reader with the packaged
   candidate.
2. **Decode dictionary indices for a cached dictionary.** moonlake decodes the
   index stream separately for each Parquet data page. colenc exposes the
   two-stream decoder, which also reads the dictionary values. Compare that
   reader with moonlake's per-page path before adding an index-only entry point
   in `encoders/`. Cover a one-entry page at bit width 1 (what a writer emits),
   a synthetic width-0 stream (the hybrid allows it, no writer produces one),
   repeated and literal runs, and truncated or out-of-range indices. Check the
   existing two-stream API against its fixtures. Switch the moonlake reader
   after the corpus and error checks pass and multi-page time and peak RSS meet
   or beat the control within measured spread.

### Performance

- **Refresh the page-encoding baseline.** *Done.* `docs/scoreboard.md` was
  regenerated at `938c3be` on `moon 0.1.20261117`, median of three rounds, with
  the worst round-to-round encode swing at native 11% and wasm-gc 15%. Encoded
  bytes and compression ratios were identical on all 42 rows, so no choice bit
  or format moved and only the timing columns changed with the toolchain.
- **Measure temporary suffix copies in DELTA_BYTE_ARRAY decode.** *Done, and the
  copies were material.* The decoder materialized every suffix and then copied
  it again into the value. Validating the length stream in place — the lengths
  are already decoded and the spans are sequential, so a cursor is enough — and
  building each value with one exact-size allocation plus two blits takes
  shared-prefix decode on `harness/perf -- delta` from 15.25 to 5.62 ms native
  (-63.1%) and 21.22 to 12.52 ms wasm-gc (-41.0%). The
  DELTA_LENGTH_BYTE_ARRAY control stayed within 2% and encode did not move, so
  the gain belongs to the target path; decoded values, consumed lengths and
  typed errors are unchanged, and the delta fixtures still match byte for byte.
  Sizing the buffer exactly while keeping the suffix copies is only -34.5%
  native, which is how much of the win comes from the second allocation rather
  than from buffer growth.
- **Size the RLE hybrid decode output before filling it.** *Done.*
  `decode_rle_hybrid` pushed one value at a time into an empty array, so a large
  column paid the geometric growth (about twice the final size in copies) plus a
  push per value. It now allocates the exact count once and writes by index. The
  path is shared, so on `harness/perf -- families` three decoders moved at once:
  boolean RLE decode 1029.9 to 736.2 us native (-28.5%) and 4460.5 to 3054.9 us
  wasm-gc (-31.5%); dictionary decode of 500k Int32 values 1374.7 to 1109.0 us
  native (-19.3%) and 5712.9 to 4195.2 us wasm-gc (-26.6%); dictionary decode of
  200k strings 1047.3 to 913.5 us native (-12.8%) and 3640.4 to 2882.6 us
  wasm-gc (-20.8%). Every other family case stayed inside its spread, encode did
  not move, and the RLE and dictionary fixtures still match byte for byte.

### Work with prerequisites

- **FSST reuse (#8)** and **immutable-table Roaring (#9)** keep their entry
  evidence and stop conditions in the [conditional work
  table](NEXT-STEPS.md#conditional-work-after-consumer-acceptance); this
  section does not restate them. Both are consumer-led, so neither schedules a
  kernel change before that evidence exists.
- **ALP** is a Parquet preview encoding for floating-point pages. Its status
  and a writer that emits it are not verified here yet, so it is assessed only
  once an independent writer and a DuckDB reader can exercise the same pages,
  and it enters the family table and the acceptance system before any
  implementation starts. Compare page size and CPU against PLAIN and
  BYTE_STREAM_SPLIT on a representative workload.
  [Parquet encoding specification](https://parquet.apache.org/docs/file-format/data-pages/encodings/)

Release candidates use the relevant [acceptance gates](#4-the-acceptance-system)
and the packaged consumer on native, wasm-gc and js. Record inconclusive and
negative experiments with their controls so they can inform the next choice.

---

*This document is the public roadmap; it is updated as stages progress*

## Final reminder: update benchmarks

The kernel work in the [implementation record](OPTIMIZATION-PLAN.md) is done and
`docs/scoreboard.md` was regenerated after it, with the sketch and bitmap query
costs recorded in the [final record](NEXT-STEPS.md#final-benchmark-record).
Updating moonlake's end-to-end baseline against the actual registry dependency
is done: that project recorded the pair at `4de8077`, and the wide CSV cases came
out 6-11% faster than the 0.1.1 control in every round. That pair is the 0.1.1
control; the 0.1.3 to 0.1.4 comparison is [§8 item 1](#8-work-after-014). The separate
[PLAIN probe](OPTIMIZATION-PLAN.md#exploratory-plain-record) measured a kernel
candidate, not a release or consumer acceptance result.
