# colpack

A columnar encoding kernel for MoonBit — the Parquet page-level encoding family
(plain, RLE/bit-packed, dictionary, delta, byte-stream split, FSST) as a
reusable, verifiable, pluggable library. Pure MoonBit, zero FFI.

- **Design, milestones and acceptance criteria**: [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **License**: [Apache-2.0](LICENSE)

**Status**: design settled, at P0 — the acceptance rig's Python judges are in
place (reference generation, page extraction, byte diffing); the MoonBit
minimal writer is next. No library code yet.
