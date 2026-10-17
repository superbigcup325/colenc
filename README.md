# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
(plain, RLE/bit-packed, dictionary, delta, byte-stream split, FSST) as a
reusable, verifiable, pluggable library. Pure MoonBit, zero FFI.

- **Design, milestones and acceptance criteria**: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **License**: [Apache-2.0](LICENSE)

**Status**: design settled, **P0 complete** — reference samples, page
extraction, byte diffing and a minimal MoonBit writer, all verified by DuckDB
and pyarrow. **P1 in progress**: `primitives` (varints, bit packing, bit width),
the neutral `types` model, PLAIN and the facade dispatch have landed; the
RLE/bit-packed hybrid is next.
