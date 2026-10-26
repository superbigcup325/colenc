# colenc — AGENTS.md

This is a [MoonBit](https://docs.moonbitlang.com) project.

colenc is a pure-MoonBit, zero-FFI **columnar encoding kernel** — the Parquet
page-level encoding family as a reusable, verifiable, pluggable library.
moonlake is its first consumer.

Read [`docs/ROADMAP.md`](docs/ROADMAP.md) first: it carries the design, the
milestone plan and the acceptance criteria this repo is built around.

## Status

Design settled; **P0 through P4 are complete in this package**. Every v1
encoding family is in place: PLAIN, the RLE/bit-packed hybrid, dictionary, the
delta family, BYTE_STREAM_SPLIT and FSST, with E1 to E6 byte-identical to the
reference and E7 measured by round trip plus the scoreboard (no Parquet-native
FSST exists). CI runs the three-backend test matrix plus the harness jobs.
**P5 (moonlake) is merged on that project's `main`**, and the package is
published as `superbigcup325/colenc@0.1.1`. **Phase two has started**: E8 is a
Roaring bitmap index, byte-identical to CRoaring (judged by pyroaring, not
parquet-cpp), with its set operations and portable serialization in place, and
the `sketches` package carries HyperLogLog and t-digest with their contracts in
`docs/SKETCHES.md`.

## Layout

Published (tracked) today:

```
AGENTS.md  README.md  CHANGELOG.md  LICENSE
moon.mod                 module manifest
docs/ROADMAP.md          the public roadmap
types/                   neutral model: PhysicalType / Encoding / ColBuf / errors
primitives/              L1: varint / zigzag / bit packing / bit width
encoders/                L2: PLAIN, RLE hybrid, dictionary, delta family,
                         BYTE_STREAM_SPLIT, FSST and the Roaring bitmap
sketches/                approximate aggregations (HLL and t-digest), a separate
                         API because a sketch is not a page encoding
facade.mbt               L3: encode_column / decode_column dispatch
harness/                 acceptance rig (repository only, excluded from the package)
.githooks/               pre-commit gate
.github/workflows/       CI gate
.gitignore .moonignore .gitattributes
```

Further encoders land as files under `encoders/`, each with its own tests and
its branch in `facade.mbt`.

- MoonBit packages are organized per directory, one `moon.pkg` each; `moon.mod`
  at the top level
- Blackbox tests are `*_test.mbt`, whitebox tests `*_wbtest.mbt`
- Adding an encoding family touches four places: a new file + its tests + the
  `Encoding` branch in `facade` + a row in the README table

## Tooling

- `moon check` / `moon test` / `moon fmt` / `moon info` / `moon run`
- Whitebox tests are `*_wbtest.mbt`, blackbox tests `*_test.mbt`; blackbox
  tests refer to the package under test by alias (`@primitives.bit_pack`), and
  test-only imports live in a `for "test"` block in `moon.pkg`
- Acceptance rig (repository-only, see `harness/README.md`):
  `python3 harness/make_refs.py [--check]` regenerates or verifies the fixtures,
  `python3 harness/extract_pages.py <parquet> --out <dir>` carves pages,
  `python3 harness/diff_bytes.py ours.bin ref.bin` reports the first divergence,
  `harness/duck_read.sh <parquet> [--values ref.bin]` runs both judges,
  `python3 harness/check_rle.py` byte-diffs the hybrid encoder,
  `python3 harness/check_dict.py` byte-diffs dictionary encoding,
  `python3 harness/check_delta.py` byte-diffs the delta family,
  `python3 harness/check_bss.py` byte-diffs BYTE_STREAM_SPLIT,
  `python3 harness/check_fsst.py` round-trips FSST and prints its ratio,
  `python3 harness/make_roaring_cases.py [--check]` regenerates or verifies the
  bitmap cases and asserts each one still exercises its container shape,
  `python3 harness/check_roaring.py` byte-diffs the bitmap in both container
  modes,
  `python3 harness/check_roaring_ops.py` checks the operation sequences that
  have no reference bytes (round trip, container legality as parsed back, and
  operand independence),
  `harness/check_container.sh` proves the container path end to end,
  `python3 harness/check_hll.py` runs the four acceptance groups the sketch
  contract defines (error spread, merge algebra, serialization, boundaries),
  `python3 harness/check_tdigest.py` runs the quantile matrix and its three
  layers (structure, the reference comparison it reports, the absolute ceilings
  it gates on),
  `python3 harness/check_consumer.py` runs a consumer against the unpacked
  release archive on all three backends with a fresh `MOON_HOME` (add
  `--registry-version X.Y.Z` after a publish)
- Throughput has two rigs: `python3 harness/scoreboard.py` regenerates
  `docs/scoreboard.md` from `harness/bench` (native and wasm-gc, median of three
  rounds per phase — one round of the same binary swings by 10-20% on the small
  cases, so toolchain comparisons go through medians), while
  `moon run --target native --release harness/perf` reports medians and spreads
  for the primitives, dataset variants and candidate rewrites; `-- candidates`
  runs only the A/B section, `-- roaring` only the bitmap cases, `-- search`
  only the key-search spellings
- `moon run harness/writer_min -- <out.parquet>` writes the minimal container
- **Before committing**, run the quartet:
  `moon info && moon fmt && moon check --deny-warn && moon test`
- `.githooks/pre-commit` enforces the non-mutating half of that gate
  (`moon check --deny-warn`, `moon fmt --check`); enable it once per clone with
  `git config core.hooksPath .githooks`. CI (`.github/workflows/ci.yml`) runs the
  same gate plus the test matrix on all three backends (wasm-gc, native, js).
- Backend differences must be tested explicitly: the default local target does
  not cover native, so anything touching bytes or buffers needs
  `moon test --target native`

## Coding convention

- Block style, blocks separated by `///|`
- Hot loops stay bounds-checked: the length precondition is checked once at
  the top of the function, then the loop indexes normally. Measured on this
  toolchain, `unsafe_get` in the bit unpacker is **not** faster (within noise,
  and slower at some widths), so the checked form stays — see Known Pitfalls.
  Reading *bytes* is the exception: once the range is validated, a body is read
  with the toolchain's bulk loads (`unsafe_read_uint16_le` /
  `unsafe_read_uint32_le` / `unsafe_read_uint64_le`), which are intrinsics that
  replace a byte-at-a-time assembly — see Known Pitfalls
- Everything little-endian; no platform branches; no FFI
- Decoding errors are typed errors carrying an offset ("byte N, item M"), never
  a panic

## Hard rules (read before touching code)

1. **Zero FFI**: no C/C++/Rust bindings; DuckDB is a **test-time judge** only,
   never in the runtime
2. **Zero runtime dependencies**: the library itself depends on no third-party
   package (test-time `moonbitlang/quickcheck` is fine). `moonbitlang/x` is
   declared for `harness/writer_min` only: no library package may import it,
   and `harness/` is excluded from the release archive
3. **Not in scope**: byte-stream compression (DEFLATE / ZSTD / Snappy / Brotli /
   LZ4), full nested-type levels, and a public Parquet-container API — all v1
   boundaries, see `docs/ROADMAP.md` §6
4. **Criteria must not be weakened**: a new encoding passes all three layers
   (round-trip + byte diff + container interop); if it cannot, demote it to the
   roadmap and say so in the README — never pass it silently, never move the
   goalposts to fit an implementation
5. **Choice bits must match the reference implementation** (RLE's run-selection
   heuristic, the dictionary threshold and bit-width derivation, DELTA's block
   128 / miniblock 4) — if they drift, byte diffing becomes meaningless
6. **Don't change criteria definitions unilaterally**; when genuinely needed,
   record the decision (who decided, why) before implementing
7. **The acceptance rig is the foundation**: do not pile encodings on top until
   P0 passes (see `docs/ROADMAP.md` §3)

## Keeping the published tree clean

This repository is public: everything tracked here is readable by anyone, and
tracked documents ship in the release archive.

- Write tracked documents and comments in **English**
- Keep local-only working material under a dot-prefixed directory, where it is
  neither tracked nor packaged; never reference such material from a tracked
  file (a cloner will not have it)
- `.gitignore` / `.moonignore` carry only build residue and test data. Git's
  `.git/info/exclude` is never consulted when packaging, so it is not a
  secrecy layer
- Before pushing or publishing, read the archive contents with
  `moon package --list` and confirm nothing local-only is in it

## Known Pitfalls

- **Fixture payload carries definition levels** → pyarrow fields default to
  nullable, so `max_definition_level = 1` and a V1 body starts with a 4-byte
  length plus an RLE level section → declare fixtures as `nullable=False`;
  required flat columns have no level bytes, so the payload is the value stream
- **pyarrow silently falls back to PLAIN** when an encoding cannot be applied →
  a fixture that never exercised its encoding would weaken every byte diff →
  read back `metadata.row_group().column().encodings` and fail the generator
- **`ColumnChunkMetaData.file_offset` is 0** (the field is deprecated) → start
  the page walk at `min(data_page_offset, dictionary_page_offset)` and trust
  `total_compressed_size`; header and body must tile the chunk exactly or the
  Thrift parse desynchronized
- **Reference bytes drift with pyarrow** → run-selection heuristics, dictionary
  thresholds and `created_by` are writer-version dependent → pin pyarrow in
  `harness/requirements.txt` and bump it only together with regenerated
  fixtures
- **V1 level prefix is a length of the section, not the page** → each section
  is `u32le length` + that many bytes, repetition first, and a section is
  absent entirely when its max level is 0
- **A nested Thrift struct must be self-contained** → compact-protocol field
  ids are deltas relative to the enclosing struct, so build each nested struct
  into its own buffer and append its bytes as the struct field payload; a
  struct writer that shares the parent's last-id state corrupts the parent
- **Footer sizes are asymmetric** → `total_compressed_size` and
  `total_byte_size` count the page header plus the body, while
  `PageHeader.uncompressed_page_size` counts the body alone; the footer length
  before the trailing `PAR1` is a plain `u32le`, not a varint
- **`moon fmt --check` arms itself with the first package** → the pre-commit
  hook and CI skip the format half only while no `moon.pkg` exists; run
  `moon fmt` before committing once packages land
- **RLE-encoded boolean values carry a 4-byte length prefix** while dictionary
  data pages carry a 1-byte bit width before the same hybrid stream; a byte
  diff against either must keep or strip the right prefix
- **pyarrow refuses RLE for non-boolean columns** (`RLE only supports
  BOOLEAN`) so widths above 1 have to be referenced through dictionary indices
- **The hybrid's literal runs stop at 63 groups** (504 values) because the
  indicator is one byte; the next group forces the run out, and a trailing
  run shorter than eight still becomes a repeated run at the end flush
- **Harness executables run on native in CI** → `moon test --target js` covers
  the library packages, but `writer_min` and `rle_probe` use `moonbitlang/x/fs`
  and are invoked with `--target native` by the harness scripts
- **BYTE_STREAM_SPLIT is size-neutral** (planes are a permutation of the same
  bytes); it only pays off when a byte-stream compressor follows, so its
  scoreboard ratio is 100% by design
- **FSST has no Parquet-native format to diff against** → colenc defines its
  own framing (symbol table, per-value length, escape 255) and the criteria are
  round trip plus the scoreboard, never byte identity
- **parquet-cpp's delta block is 256 values for INT64 and 128 for INT32** while
  the spec says 128; byte identity requires following the writer, not the spec
- **A delta block always carries four width bytes** even when the last block
  uses fewer miniblocks (the unused widths are zero and carry no data), and a
  partial miniblock is zero-padded to its full size
- **The delta header holds the first value**; block deltas start at the second
  value, so a single-value column is header-only
- **Dictionary fallback differs in scope from the reference** → parquet-cpp
  falls back mid-column when the dictionary outgrows its page limit, colenc
  decides per column (returns `None`), so byte diffs only cover columns under
  the limit
- **A dictionary with one entry uses bit width 1, not 0**, and five entries use
  three bits; widths follow `max(1, bit_width_for(size - 1))`
- **pyroaring's constructor run-optimises, `add` does not** → `BitMap(values)`
  comes back with run containers wherever they are smaller, while
  `BitMap()` + `add` stays on the array/bitmap path → colenc writes the
  incremental path by default and only emits runs behind `run_optimize`, so the
  fixtures carry two references per case (with and without `run_optimize()`)
- **A run conversion has to be strictly smaller** → the reference keeps the
  array form when the run form ties it (cardinality `1 + 2 * runs`), and the
  bitmap container at 4096 ids is also a tie in byte count → compare sizes, not
  cardinalities, when mirroring the rule
- **The offset table is not always there** → it is written whenever no container
  is a run container, and with runs only once there are four or more containers;
  reading it unconditionally desynchronises the whole stream
- **The Roaring surface takes INT32 ids** → the portable format's upper u32 half
  needs a column type `ColBuf` does not have yet, so ids above 2^31-1 are
  rejected with `OutOfRange` rather than truncated
- **A set operation converted every operand to bitmap words** → `union` and
  `intersect` materialized 8 KB per container regardless of shape, ORed the
  words, and then re-derived the result's values, which meant a dense container
  enumerated 60k values it threw away when the result stayed a bitmap. Measured
  on the same call: an 8-value array container cost 68.5 ns per id while a
  bitmap container of 60k values cost 0.42 ns per id — the small container was
  paying the large container's price. Merging two sorted value arrays, filtering
  an array against a bitmap's words, and choosing the result shape by popcount
  takes the array case to 2.7 ns per id (-96%) and the bitmap case to 0.026 ns
  per id (-94%). The lesson generalizes: a container's shape is already known,
  so an operation that densifies both operands throws that knowledge away
- **A set operation that reuses an operand's container aliases it** → the union
  used to push the surviving side's container by reference, so a later `add` on
  the result rewrote the operand (the array container's `insert` is in place);
  every container a result carries has to be copied, and the regression belongs
  in a test, not in a review note
- **A container's shape must be chosen from the cardinality the operation
  produces** → `container_add` used to convert a run container only when its old
  length was exactly 4096, so a 5000-id run grew into a 5001-value *array*; the
  writer serializes by shape while the reader picks by cardinality, so the bytes
  could not be read back (10018 bytes written, no valid parse). The invariant is
  the contract: arrays hold at most 4096 values, bitmaps more, and a run form is
  adopted only when it is strictly smaller
- **A byte diff cannot judge every bitmap path** → CRoaring keeps a run
  container when an id is added to it while colenc de-optimises the run, so both
  streams are legal and differ; an aliased set result is byte-identical to itself
  until the result is mutated. Those sequences are judged by round trip, by the
  container invariants re-derived from the bytes, and by leaving the operands
  untouched, with the layout pinned separately as a regression net rather than
  as a criterion
- **A bulk build must settle on the shape repeated adds would have chosen** →
  building a bitmap from a sorted column key run by key run is 4-7x faster than
  one insert per id, but the shape rule reads the *final* cardinality of the
  run, not the cardinality at some insert: an array up to 4096 values, a bitmap
  above. Proving the rewrite means comparing bytes with the incremental path on
  the boundary cases (4096/4097, a full 65536-value key, duplicates, MAX_ID,
  before and after `run_optimize`), not comparing the decoded sets
- **A scoreboard run is only as good as the machine it ran on** → the header
  records the worst round-to-round swing for a reason: one regeneration here
  reported 148% and another 502% while the host was busy outside the sandbox
  (`ps` inside it showed nothing, `load average` did), so read that line first
  and regenerate rather than picking the flattering run — a reused median from
  an overloaded machine is a wrong number in a tracked document
- **A container's cost is one allocation, and the arrays around it grow** →
  a bitmap of 32768 one-value containers spends about 29 ns per container,
  of which `Array::make(1, value)` is 8.4 ns and the two pushes into
  `keys`/`containers` are the rest (measured as control cases in
  `harness/perf -- candidates`, where 32768 pushes cost 21 µs against 5 µs for
  one exact-size `Array::make`); reserving both arrays from the key span
  between the first and the last id takes the encode path down 16% on wide
  keys and 26% on the sparse column. Counting the containers per id instead
  was *slower* on the dense cases, which is why the span estimate stays O(1)
- **The bulk build used to scan the ids three times** → finding the key run,
  counting its distinct lows and filling the container were three passes, and
  on a sparse column the counting pass alone was a third of the build time.
  Counting inside the walk that finds the run (one `& 0xFFFF`, one compare, one
  increment per id) takes `from_ids` down 13.4% sparse and 9.4% dense; the
  remaining fill pass has to stay because an array container's length must be
  exact (`Array` has no truncate), and a lowercase-scratch copy instead of the
  fill was not worth the extra allocation
- **A per-value read helper costs more than the bytes it reads** → decoding
  used `roaring_read_u16` per value, so every 16-bit read paid a call and a
  fresh `offset + 2 > length` check even though the container's byte count was
  known before the loop. Validating the table (or container) once and walking
  it with a cursor takes `from_bytes` down 37.9% on the sparse column and 26.3%
  on a set of 32768 containers; the same treatment applied to the key/card and
  offset tables, which are walked once per container. `unsafe_get` on top of
  that is *mixed* (sparse -7.7%, a 32768-container set +1.8%), so the checked
  array indexing stays, matching the convention above
- **A byte-at-a-time load is the next step up from that** → even with the
  cursor in place, a 64-bit bitmap word was assembled from eight checked byte
  reads, so a sparse column's 8 KB bodies cost 256M byte accesses. The
  toolchain's `unsafe_read_uint64_le` / `_uint32_le` / `_uint16_le` on a
  `BytesView` are intrinsics (they lower to one load), and reading each body
  with them after the same single range check takes `from_bytes` down 67.5% on
  a dense container, 65.0% mixed, 19.9% on a sparse array container and 14.2%
  on the 1M-value sparse column; wasm-gc agrees (-40.2% / -38.8% / -40.7% /
  -2.4%). The card check came along for free by counting the popcount inside
  the same walk (and a run container's lengths in the pairs loop) instead of a
  second pass — but the *array* container's card is the word by construction,
  so that branch has nothing to check and the old tautological check is gone.
  Watch the noise: the same HEAD binary measured 2026 and 2526 us on the 1M
  read, so a single A/B pair cannot resolve a 10% claim on that case — the
  numbers above come from interleaved median-of-three pairs
- **A container's array is zero-filled and then overwritten** → `from_bytes`
  and the bulk build both allocated their container body with
  `Array::make(len, 0)` and then wrote every slot, so half of the allocation
  was a pass nobody read. `Array::unsafe_make_uninit(len)` (hidden core API,
  same allocation without the zeroing) is safe exactly here: the loop that
  creates the array also writes all `len` slots, an error drops the array
  instead of exposing it, and `Int32`/`Int64` arrays hold no pointers the
  collector could follow. Measured on a quiet host, zeroing costs about 7.5 ns
  of a 30-value container's 27.8 ns alloc-and-fill pair (20.4 ns without it)
  and 186 ns per 8 KB bitmap body (456 -> 270 ns); the reader and the sorted
  build both stop paying it (four interleaved pairs: the 1M-value sparse read
  1519 -> 1371 us, a sparse array container -9.6%, 32768 one-value containers
  -7.3%, the sorted build -1.9% to -5.7%). Do not reach for it where the body
  is *read* before it is written (a bitmap container built by ORing bits in) —
  that one still needs the zeroed array. One caveat on the rig: `array-make`
  and other few-microsecond controls moved 18% between two builds whose code
  for them is identical, so a layout effect can masquerade as a win on the
  microbenchmarks — trust the dataset cases, and interleave the pairs
- **The per-value write is at the floor; the per-container control flow was
  not** → the control cases in `harness/perf -- candidates` price the byte-level
  alternatives on 32768 u16 values into a buffer: two `write_byte` calls 38.0 us,
  one `write_uint16_le` 44.3 us (slower, the `UInt16` conversion costs more than
  the call saves), building a scratch array and one `write_bytes` 32.7 us — so
  writing the values differently buys little. A first attempt at sizing the
  buffer exactly was *mixed* (dense and mixed -10/-18%, a 32768-container set
  +6.5%) because it added a whole extra length pass that re-derived
  `has_run_container`. The version that works fuses that pass into the tables
  the writer already walks: one match per container yields its card, its body
  size and its run flag, the exact total comes out of the same loop, and the
  buffer is created at that size. Four matches per container became two and the
  buffer never grows: `to_bytes` -22.8% dense, -19.5% on 32768 one-value
  containers, -28.3% mixed; on wasm-gc the same A/B is -13.8% to -33.1%
- **A run container's pairs are `[start, length - 1]`, not `[start, end]`** →
  the serializer's planning pass re-derives each container's cardinality to fill
  the card table, and the first version subtracted `start` from `end`; every
  run-optimised case then wrote a wrong card (the byte diff caught one, the
  reader's cardinality check caught the rest). The fix belongs in the code, but
  the guard is a test: `check_serialization_plan` in `roaring_wbtest.mbt` pins
  the plan's card and size for every container against `container_cardinality`
  and `container_byte_size`, on all three shapes, before and after
  `run_optimize`, plus the empty bitmap
- **`Int32` has no `to_int` in this toolchain** → `x.to_int()` on an `Int32`
  fails with "Type Int has no method to_int", which reads as if the type were
  already `Int`; the wide path is `x.to_int64().to_int()`
- **A binary search costs its mispredictions before its bounds checks** → the
  key lookup behind `contains` was `low/high` with a branch per step. Four
  spellings of the same lower bound were priced in `harness/perf -- search` on a
  32768-key array: branchy 36.8 ns per probe, branchy with the length hoisted
  40.3, an unchecked copy 35.6 (no gain, so the bounds check is not the cost),
  branchless 13.1. The branchless form is *not* universally better: on the build
  path, where a sorted column walks the keys forward, the branch predicts and
  speculation runs ahead, so the same change measured +26% to +90% on `add` and
  had to be kept to the probe path only. Short arrays want a linear scan
  (a 5-key bitmap: 3.8 ns branchy, 6.4 ns branchless, 1.4 ns linear). Pick the
  spelling by access pattern, and price it — not by principle
- **Unchecked access is not a speedup here** → rewriting the bit unpacker with
  `unsafe_get` measured 0.271→0.305 ms at width 5, 0.361→0.445 at 12 and
  0.422→0.497 at 16 (and a wash elsewhere), so bounds checks are not the
  bottleneck; the win comes from the algorithm (one 64-bit accumulator, whole
  bytes per step), not from dropping checks
- **A benchmark without a round-trip guard rewards the error path** → the first
  `harness/perf` version timed `encode_column` with `Dictionary`, which the
  facade rejects on purpose, and the swallowed error read as 23 ns per call;
  every case now asserts the round trip and aborts instead of measuring a raise
- **Prefer prelude and non-deprecated core APIs** → `Buffer()` replaces
  `@buffer.new()`, and `String::to_bytes` is deprecated in favour of
  `@utf8.encode`; `--deny-warn` turns both into build failures
- **`count * width` wraps in `Int32` before the length check sees it** → the
  fixed-width PLAIN decoders computed `need = count * 8` and compared it with the
  view length, so a count of 2^29 wrapped to zero (and 2^29 at width 4 to a
  negative size) and passed the check before an out-of-bounds read. The check
  now compares `count` with `data.length() / width` and reports a saturated
  requirement, so no multiplication happens first; with that in place the
  values are read with `unsafe_read_uint64_le` / `_uint32_le`. Interleaved A/B
  on native release, 500k values, medians of three rounds: Int64 1991 -> 236
  us, Double 1992 -> 236 us, Int32 666 -> 152 us, Float 678 -> 152 us; wasm-gc
  (two rounds) Int64 4600 -> 1955 us and Int32 2045 -> 1370 us. Encode is
  unchanged. The js backend does not preserve a NaN payload, so tests assert
  the NaN class and compare other doubles and floats by bit pattern
- **A dictionary was built in full before its size was looked at** → the
  planners deduplicated the whole column and the writer then compared the PLAIN
  payload with `max_dictionary_bytes`, so a high-cardinality column paid for the
  complete dictionary and index array it was about to discard. The planners now
  take the limit and return `None` as soon as the next new value would pass it
  (entries times width for fixed-width types, a running `4 + length` total in 64
  bits for byte arrays). The payload only grows, so the early exit decides what
  the final comparison decided and the accepted bytes are unchanged
  (`check_dict.py` and the container check still match). Native release,
  refused columns: 500k distinct Int32 values 59.8 -> 24.7 ms (-59%), 200k
  distinct strings 22.3 -> 6.9 ms (-69%); wasm-gc -65% and -78%. The accepted
  low-cardinality cases get no added per-value work, but the candidate binary
  measured bimodally on the Int32 one over eight rounds (about 2.7 to 2.9 ms in
  some, 3.1 in others, against a steady 2.7 for the baseline), so treat a
  difference under 15% there as unresolved layout noise, not as a result
- **A register per machine word cost four times its payload** → `HllSketch`
  held its registers in an `Array[Int32]` although a rank never exceeds 61 and
  the serialized form already used one byte each, so a precision-14 sketch
  carried 64 KiB of state for 16 KiB of information. The state is a
  `FixedArray[Byte]` now; precision, hash, rank rule, estimator and the v1 bytes
  are untouched (`check_hll.py`, the pinned serialization test and the packaged
  consumer pass on all three targets). The public `registers()` accessor used to
  hand out a non-copying `ArrayView[Int32]`; it keeps its type but now builds a
  fresh array per call (a snapshot, O(register_count)), and `register(index)`
  is the new allocation-free read, returning an error for a bad index. Native
  release, medians of three: update with 1000 groups of 1000 values 40.7 -> 36.0
  ms, estimate 124 -> 113 us, merge 57.5 -> 52.8 us, `to_bytes` 7.3 -> 5.9 us,
  `from_bytes` 10.5 -> 7.4 us; one 1M-value group is unchanged (18.5 vs 18.4 ms).
  Peak RSS of the grouped state (1000 groups x 1000 values) 96.7 -> 25.0 MB and
  of 5000 groups x 10 values 428 -> 109 MB, which is the dense-state cost the
  consumer measured, not a sparse-state result: small groups still pay a full
  16 KiB each, so a sparse state stays a separate decision
- **A question about an intersection does not need the intersection** → `intersect`
  builds a result bitmap (and for run containers converts both sides to 8 KB
  word arrays), so asking only for its size or for whether it is empty paid for
  containers the caller discarded. `intersection_cardinality` and `intersects`
  walk the two key lists and count per container pair without allocating a
  result, and `intersects` returns at the first shared id; `ids_after(after,
  limit)` returns the next batch of ascending ids from a cursor (the last id seen,
  `-1L` to start) instead of expanding the whole bitmap, and holds no state, so
  there is nothing to invalidate when the bitmap changes between calls. They are
  checked against an independent set oracle for every container pairing
  (array/bitmap/run, plain and run-optimised, 4096/4097, the largest id) and
  against `to_array`, and the perf rig aborts if either disagrees with its model
  before timing. Native release, medians of three rounds, `intersect` -> count:
  array containers partial overlap 150 -> 37 us, identical 167 -> 30 us; bitmap
  containers 14.0 -> 3.45 us; mixed shapes identical 5.5 -> 1.04 us but partial
  only 6.6 -> 5.9 us; run containers 957 us -> 0.02 us (the run case goes
  through two word arrays in `intersect`). `intersects` on overlapping sets is
  about 10 ns, but with no overlap it still walks everything (array-disjoint
  40 us), so early stop only helps where an overlap exists. Batches: the first
  4096 ids of a 1M-id bitmap cost 4.3 us against 907 us for `to_array`, and a full
  walk is faster than `to_array` on dense containers (bitmap 486 -> 282 us, run
  438 -> 181 us, mixed 17.7 -> 10.4 us) but 14% slower on the sparse 1M-id array
  case (907 -> 1035 us), because each batch re-locates its key by binary search
- **The compression pass sorted tuples that were already in order** → every
  `compress` and `merge` built a list of `(mean, weight)` tuples from the
  centroids and the raw buffer and sorted all of it, although the centroids come
  out of each pass already ordered and only the buffer is raw. `tdigest_sorted_parts`
  sorts the buffer as plain doubles and merges it with the centroids into the
  split arrays directly (a tie takes the centroid first, which is where the
  stable tuple sort put it); centroids that are not in `(mean, weight)` order,
  as a state read from bytes need not be, fall back to the tuple sort. The
  lower scale value of a centroid is also computed once instead of once per
  candidate. The result is the same list, checked against the tuple sort at
  every stage of a tied stream in `tdigest_wbtest.mbt`, so serialized bytes,
  extremes and the `check_tdigest.py` ceilings are unchanged (worst interior
  0.5%, tail 0.2%). Native release, medians of three rounds: 1M updates 88.5 ->
  51.9 ms (-41%), 20k updates 1750 -> 1015 us, merge of two 1M-value digests 3.7
  -> 2.5 us; quantile queries (2.3 us per 99), `to_bytes` and `from_bytes` do not
  move, as the pass is not on their path
- **FSST trained its symbol table on every call, and training is most of the
  call** -> `encode_fsst` built the table and then encoded, so a batch of 100
  short strings spent 36.6 of its 39.5 us on training and 2.8 us on matching.
  `FsstModel::train` and `encode_fsst_with` split the two; `encode_fsst` is now
  `train` then `encode_fsst_with`, so a model trained on a batch encodes that
  batch to exactly the bytes the one-shot encoder wrote (tested). The frame is
  unchanged: every batch still carries its own copy of the table, so
  `decode_fsst` needs no model and old frames read as before, and the price of
  reuse is that table repeated per batch (648 to 1842 bytes on these data). Held-out
  batches of the same shape, native release, medians of two rounds, reused vs
  fresh training: low-cardinality labels 28.5 vs 395 ns per value at 100 values
  and 15.8 vs 84 at 20000, the same bytes; prefix-heavy text 51 vs 1564 ns per
  value at 100 and 67 vs 416 at 20000; high-cardinality text 787 vs 8670 at 100
  and 791 vs 2125 at 20000. Size is data-dependent and not always better: on the
  held-out batch the reused model was 7.0% larger at 100 prefix-heavy values, 2.8%
  larger at 1000, 3.6% larger at 100 high-cardinality values and equal at 20000,
  while at 20000 prefix-heavy values it was 14% smaller. The model is immutable
  and nothing detects that the data drifted away from it; a caller that reuses a
  model owns that decision

## Command reference

```bash
moon version              # toolchain self-check
moon check                # type-check
moon test                 # test suite
moon test --target native # required for backend-differing paths
moon info && moon fmt     # refresh interfaces, format

# pre-commit gate
moon info && moon fmt && moon check --deny-warn && moon test
```

The acceptance rig's Python side lives in `harness/` in the source repository
(excluded from the published package); its setup, commands and the fixture
contract are documented in `harness/README.md`.
