# harness — the acceptance rig

The rig that decides whether an encoder is correct. Three layers, per
`docs/ROADMAP.md` §4: property tests in MoonBit, byte-level diffing against a
reference implementation, and container interop with DuckDB as judge.

Both halves are here: the Python side (reference sample generation, page
extraction, byte diffing, dual judges) and the MoonBit probes and minimal
writer. Each section below states what it checks and how to run it.

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
make_bss_cases.py  build BYTE_STREAM_SPLIT cases from the fixtures
check_bss.py       run the BSS probe and diff the planes
check_fsst.py      round-trip FSST and print its PLAIN ratio
make_roaring_cases.py build the bitmap cases and assert their container shapes
check_roaring.py   byte-diff the bitmap in both container modes
check_roaring_ops.py check the sequences that have no reference bytes
check_container.sh end-to-end container check: wrap, judge, diff pages
scoreboard.py      turn `bench` output into docs/scoreboard.md
bench/             throughput bench the scoreboard reads
perf/              hotspot probe: primitives, variants, candidate A/B
rle_probe/         minimal MoonBit CLI around the library's RLE encoder
dict_probe/        minimal MoonBit CLI around the dictionary encoder
delta_probe/       minimal MoonBit CLI around the delta encoders
bss_probe/         minimal MoonBit CLI around BYTE_STREAM_SPLIT
fsst_probe/        minimal MoonBit CLI around FSST (round trip + ratio)
roaring_probe/     minimal MoonBit CLI around the Roaring bitmap
roaring_ops_probe/ minimal MoonBit CLI replaying the bitmap operation sequences
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
for PLAIN samples, exactly the payload colenc must reproduce.

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

`--library` takes the page body from `colenc.encode_column` instead of the
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

## BYTE_STREAM_SPLIT and FSST

```bash
python3 harness/make_bss_cases.py && python3 harness/check_bss.py
python3 harness/check_fsst.py
```

BSS is byte-diffed like the other Parquet encodings. FSST has no reference
format, so `fsst_probe` compresses, decompresses, verifies the round trip and
prints both sizes; `check_fsst.py` collects the ratios.

## Roaring bitmap byte diff

```bash
python3 harness/make_roaring_cases.py            # regenerate the cases
python3 harness/make_roaring_cases.py --check    # verify they are reproducible
python3 harness/check_roaring.py                 # byte-diff every case
```

Twelve cases cover the shapes that matter: the bare empty header, an array
container, the container key edge (65535 / 65536), three and four containers
(the offset table is unconditional without runs), a 5000-id bitmap container,
array and bitmap containers side by side, the largest representable id,
duplicates collapsing, and three run-optimised shapes (one run container, four
run containers with the offset table still written, and a mix).

The reference is CRoaring through **pyroaring**, pinned in `requirements.txt`.
Two references are generated per case because the reference has two paths: one
built through `BitMap.add` (no run optimisation, which is what colenc writes by
default) and one with `run_optimize()` applied (what `--run-optimize` must
match). `roaring_probe` takes the same two paths:

```bash
moon run --target native harness/roaring_probe -- \
  --in harness/fixtures/roaring/roaring_mixed.input.i32le --out out.bin
```

The generator parses its own reference output and fails when a case no longer
contains the container shapes its label claims, so a fixture cannot silently
drift into testing one shape twice.

## Roaring sequences with no reference bytes

```bash
python3 harness/check_roaring_ops.py            # check the sequences
python3 harness/check_roaring_ops.py --update   # re-pin the layout fixture
```

Two sequences cannot be judged by a byte diff. CRoaring keeps a run container
when an id is added to it, while colenc de-optimises the run into an array or
bitmap container, so both streams are legal and they differ. And a set operation
whose result aliases an operand's container is still byte-identical to itself
until someone mutates the result. The cases above never touch either path.

So these sequences are judged by what actually broke in R0 instead:

- the stream parses back to the expected set, decoded from the bytes alone;
- each container is legal *as read from the bytes*: arrays at most 4096 values
  and strictly ascending, bitmaps above 4096 with a popcount equal to the
  declared cardinality, runs ascending, disjoint, non-adjacent and strictly
  smaller than the form they replaced, keys ascending, bodies tiling the stream
  and the offset table pointing at each body;
- the operands are unchanged after the result is mutated, and the probe's own
  cardinality and id hash agree with what the bytes say.

`roaring_ops_probe` replays the sequences and writes one stream per step;
`check_roaring_ops.py` parses them with its own reader, so the library never
grades its own containers. `fixtures/roaring_ops.json` pins the encoded size and
container shape of every step: that is a regression pin and not a criterion, so
a legal but different shape choice shows up as a diff that has to be decided.

## P1 evidence

- `check_rle.py`: three cases, all byte-identical to the reference, covering
  width 1 (1000 values), a run-heavy width 1 stream of 676 values, and width 2
  dictionary indices (1000 values)
- `moon run harness/writer_min -- out.parquet --rle` writes a boolean RLE page
  that DuckDB and pyarrow read back with equal values, and whose value section
  is byte-identical to the reference page (4-byte prefix included)
