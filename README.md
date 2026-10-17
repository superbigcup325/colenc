# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
(plain, RLE/bit-packed, dictionary, delta, byte-stream split, FSST) as a
reusable, verifiable, pluggable library. Pure MoonBit, zero FFI.

- **Design, milestones and acceptance criteria**: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **License**: [Apache-2.0](LICENSE)

**Status**: design settled, **P0 complete** — reference samples, page
extraction, byte diffing and a minimal MoonBit writer, all verified by DuckDB
and pyarrow. **P0 through P4 complete**: every v1 encoding family is in place — PLAIN, the
RLE/bit-packed hybrid, dictionary, the delta family, BYTE_STREAM_SPLIT and
FSST — with E1 to E6 byte-identical to the reference and E7 measured by round
trip plus the scoreboard. CI covers native, wasm-gc and js plus the harness
byte-diff and container jobs. Integration with moonlake (P5) is next.
