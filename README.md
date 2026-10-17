# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
(plain, RLE/bit-packed, dictionary, delta, byte-stream split, FSST) as a
reusable, verifiable, pluggable library. Pure MoonBit, zero FFI.

- **Design, milestones and acceptance criteria**: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **License**: [Apache-2.0](LICENSE)

**Status**: design settled, **P0 complete** — reference samples, page
extraction, byte diffing and a minimal MoonBit writer, all verified by DuckDB
and pyarrow. **P0, P1 and P2 complete**: `primitives`, the neutral `types` model,
PLAIN, the RLE/bit-packed hybrid and dictionary encoding behind the facade
dispatch, with E1 and E2 byte-identical to the reference. CI covers native,
wasm-gc and js plus the harness byte-diff and container jobs. The delta family
(P3) is next.
