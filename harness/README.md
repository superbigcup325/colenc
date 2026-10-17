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
read_back.py       judge a Parquet file with DuckDB and pyarrow
duck_read.sh       thin wrapper around read_back.py
make_rle_cases.py  build RLE byte-diff cases from the fixtures
check_rle.py       run the RLE probe over every case and diff the bytes
make_dict_cases.py build dictionary byte-diff cases from the fixtures
check_dict.py      run the dictionary probe and diff both payloads
make_delta_cases.py build delta byte-diff cases from the fixtures
check_delta.py     run the delta probe and diff the stream
check_container.sh end-to-end container check: wrap, judge, diff pages
rle_probe/         minimal MoonBit CLI around the library's RLE encoder
dict_probe/        minimal MoonBit CLI around the dictionary encoder
delta_probe/       minimal MoonBit CLI around the delta encoders
requirements.txt   pinned judge versions (pyarrow, duckdb)
fixtures/          committed reference samples + manifest
writer_min/        minimal MoonBit Parquet writer (T0.2)
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

## Minimal writer

`harness/writer_min/` is the smallest MoonBit writer the container judge
accepts: one required int32 column in PLAIN, uncompressed, a single V1 data
page, Thrift-compact footer, `PAR1` magic on both ends. It is a judge target,
not a general writer.

```bash
moon run harness/writer_min -- /tmp/writer_min.parquet
moon run harness/writer_min -- /tmp/writer_min.parquet --library
harness/duck_read.sh /tmp/writer_min.parquet \
  --values harness/fixtures/plain_int32.values.bin --type INT32
```

`--library` takes the page body from `colpack.encode_column` instead of the
writer's own loop, so the container check exercises the library's PLAIN output;
both modes must produce byte-identical files. `--rle` writes a boolean column
encoded as the RLE hybrid through the library, which is the E1 container check.

## RLE byte diff

The hybrid encoder is only correct if its run selection matches the reference
implementation byte for byte. Two sources feed the check:

- boolean fixtures, whose value section is the hybrid stream behind a 4-byte
  length prefix
- dictionary fixtures, whose data page is a bit-width byte followed by the
  hybrid stream over the indices, so widths above 1 are covered too

```bash
python3 harness/make_rle_cases.py        # fixtures/rle/*.input.bin + *.ref.bin
python3 harness/check_rle.py             # run the probe and diff every case
```

`rle_probe` reads the value sequence as little-endian u64 and writes the raw
stream; `check_rle.py` reports the first differing byte, not just pass/fail.

CI runs both checks in the `harness` job, together with
`harness/check_container.sh`, which wraps library-produced bodies, judges the
files with DuckDB and pyarrow, and diffs the page payloads against the
fixtures.

The writer emits the same 1000-row sequence as the `plain_int32` fixture, so the
page payload can be diffed against the fixture as a third check on top of the
two judges:

```bash
python3 harness/extract_pages.py /tmp/writer_min.parquet --out /tmp/writer_pages
python3 harness/diff_bytes.py \
  /tmp/writer_pages/writer_min.rg0.c0.p0.data.values.bin \
  harness/fixtures/plain_int32.values.bin
```

The writer imports `moonbitlang/x/fs` to write its output. That dependency is
harness-only: no library package imports it, and `harness/` never ships in the
release archive.

## Judge a file

```bash
harness/duck_read.sh FILE.parquet [--values ref.values.bin] [--type INT32] [--count N]
```

Fails unless DuckDB and pyarrow agree row by row, and, when `--values` is given,
unless those values equal the expected PLAIN bytes. Exit status: `0` pass, `1`
mismatch, `2` unreadable file.

## P0 evidence

- `make_refs.py` + `--check`: six samples, all PASS, reproducible
- `extract_pages.py`: carves PLAIN, RLE_DICTIONARY + dictionary page,
  DELTA_BINARY_PACKED and BYTE_STREAM_SPLIT pages; every column chunk is tiled
  exactly to the byte
- `diff_bytes.py`: a single flipped byte is reported at its exact offset; a
  truncated file reports the length difference; identical files exit 0
- `writer_min`: a 4121-byte file of 1000 int32 rows is read back with equal
  values by DuckDB and pyarrow, its page payload is byte-identical to the
  `plain_int32` fixture, and repeated runs produce the same MD5
- `extract_pages.py` parses the writer's own page headers and tiling, so the
  extractor and the writer agree on the container independent of pyarrow

## Dictionary byte diff

```bash
python3 harness/make_dict_cases.py   # fixtures/dict/*.input|dict|indices.bin
python3 harness/check_dict.py        # probe, diff both payloads, show ratio
```

Each case compares two payloads: the PLAIN dictionary page and the data page
(width byte plus index stream). The case types cover fixed-width integers and
length-prefixed strings.

## Delta byte diff

```bash
python3 harness/make_delta_cases.py   # fixtures/delta/*.input|ref.bin
python3 harness/check_delta.py        # probe, diff, show the PLAIN ratio
```

Cases cover DELTA_BINARY_PACKED at both integer widths and both byte-array
encodings. A delta stream is self-delimiting, so the case file is the whole
data page payload.

## P1 evidence

- `check_rle.py`: three cases, all byte-identical to the reference, covering
  width 1 (1000 values), a run-heavy width 1 stream of 676 values, and width 2
  dictionary indices (1000 values)
- `moon run harness/writer_min -- out.parquet --rle` writes a boolean RLE page
  that DuckDB and pyarrow read back with equal values, and whose value section
  is byte-identical to the reference page (4-byte prefix included)
