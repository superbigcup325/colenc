# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
(plain, RLE/bit-packed, dictionary, delta, byte-stream split, FSST) as a
reusable, verifiable, pluggable library. Pure MoonBit, zero FFI.

- **Design, milestones and acceptance criteria**: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **License**: [Apache-2.0](LICENSE)

**Status**: design settled, **P0 complete** — reference samples, page
extraction, byte diffing and a minimal MoonBit writer, all verified by DuckDB
and pyarrow. **P0 complete, P1 complete**: `primitives`, the neutral `types`
model, PLAIN and the RLE/bit-packed hybrid behind the facade dispatch, with E1
byte-identical to the reference. CI covers native, wasm-gc and js plus the
harness byte-diff and container jobs. The dictionary encoding (P2) is next.
