# harness — the acceptance rig

The rig that decides whether an encoder is correct. Three layers, per
`docs/ROADMAP.md` §4: property tests in MoonBit, byte-level diffing against a
reference implementation, and container interop with DuckDB as judge.

Today this directory holds the P0 Python side: reference sample generation, page
extraction, and byte diffing. The MoonBit minimal writer lands with T0.2.

```
make_refs.py       generate the reference samples and their expected values
extract_pages.py   carve pages out of Parquet files into standalone blobs
parquet_pages.py   Thrift compact page-header reader used by extract_pages
diff_bytes.py      byte diff with first-divergence offset and hex context
requirements.txt   pinned judge versions (pyarrow, duckdb)
fixtures/          committed reference samples + manifest
```

## Setup

```bash
uv venv harness/.venv --python 3.13
uv pip install -r harness/requirements.txt
```

The versions in `requirements.txt` are pinned deliberately. The fixtures are
byte-compared, so a different pyarrow may change output (run selection,
dictionary thresholds, the `created_by` string) and every fixture would drift.

## Generate and verify the reference samples

```bash
python3 harness/make_refs.py            # write fixtures/
python3 harness/make_refs.py --check    # regenerate in memory, diff, write nothing
```

`--check` is the reproducibility gate: it regenerates every sample and compares
the bytes (and the manifest) with what is committed, reporting the first
diverging offset instead of just "different".

## Fixtures

One required, flat column per file, uncompressed, Parquet format `2.6`, data
page version `1.0`, no statistics, no Arrow schema in the footer.

| Sample | Physical type | Encoding | Count | Values file |
|---|---|---|---|---|
| `plain_int32` | INT32 | PLAIN | 1000 | 4-byte LE ints |
| `plain_string` | BYTE_ARRAY | PLAIN | 200 | 4-byte LE length + UTF-8 |
| `dict_string` | BYTE_ARRAY | RLE_DICTIONARY (dictionary page PLAIN) | 1000, 4 distinct | PLAIN strings |
| `delta_int64` | INT64 | DELTA_BINARY_PACKED | 1000 | 8-byte LE ints |
| `bss_float32` | FLOAT | BYTE_STREAM_SPLIT | 1000 | 4-byte LE IEEE 754 |
| `rle_bool` | BOOLEAN | RLE | 1000 | PLAIN bits, LSB first |

`<sample>.values.bin` holds the column's values in PLAIN form with no level
bytes (BOOLEAN bit-packed LSB first): that is both the "expected values" list for the container judge and,
for PLAIN samples, exactly the payload colpack must reproduce.

`manifest.json` records the writer settings, pyarrow version, observed
encodings, dictionary-page presence and SHA-256 for each file. The generator
asserts the observed encodings and fails if pyarrow silently fell back to PLAIN
— a fixture that does not exercise its encoding would quietly weaken every
later byte diff.

## Extract pages

```bash
python3 harness/extract_pages.py harness/fixtures/*.parquet --out /tmp/pages
```

Writes one `<stem>.rg<g>.c<c>.p<i>.<dict|data>.values.bin` per page, plus a
`<stem>.pages.json` with header/body offsets, value lengths, encoding and level
lengths. Level sections, when present, are written as separate `.levels.bin`
files. The page walk is self-checking: headers and bodies must tile each column
chunk exactly, otherwise extraction fails loudly.

## Byte diff

```bash
python3 harness/diff_bytes.py ours.bin reference.values.bin
```

Prints the first diverging offset, the byte on each side, a hex dump around it,
and the following difference runs. Exit status: `0` identical, `1` different,
`2` unreadable input.

## Decisions taken here

- **Data page version 1.0.** All four target encodings are writable under it,
  and V1 pages keep the level length prefixes simple (4-byte LE) instead of the
  V2 raw level layout. Byte diffing only needs the value section, and V1 keeps
  the split trivial.
- **Parquet format version 2.6** with data page V1: modern encoding enums,
  simple page headers.
- **Required columns** (`nullable=False`), so `max_definition_level = 0` and the
  page body is the value stream with no level prefix. Nullable columns are
  deliberately out of scope until level encoders land.
- **No compression, no statistics.** Compression would hide the encoded bytes
  behind a byte-stream layer; statistics would enlarge page headers and drag in
  min/max encoding decisions.
- **Committed fixtures.** CI must diff against the same bytes without needing
  pyarrow to regenerate them; `--check` proves the fixtures still follow from
  the generator.

## P0 evidence

- `make_refs.py` + `--check`: six samples, all PASS, reproducible
- `extract_pages.py`: carves PLAIN, RLE_DICTIONARY + dictionary page,
  DELTA_BINARY_PACKED and BYTE_STREAM_SPLIT pages; every column chunk is tiled
  exactly to the byte
- `diff_bytes.py`: a single flipped byte is reported at its exact offset; a
  truncated file reports the length difference; identical files exit 0
