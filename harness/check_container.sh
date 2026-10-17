#!/bin/sh
# Container interop, end to end: wrap library-produced page bodies in a Parquet
# container, read the files back with both judges, and diff the page payloads
# against the reference fixtures.
#
#   harness/check_container.sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
cd "$root"
if [ -x "$here/.venv/bin/python" ]; then
  py="$here/.venv/bin/python"
else
  py="${PYTHON:-python3}"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

moon run --target native harness/writer_min -- "$work/plain_hand.parquet" >/dev/null
moon run --target native harness/writer_min -- "$work/plain_lib.parquet" --library >/dev/null
if cmp "$work/plain_hand.parquet" "$work/plain_lib.parquet"; then
  echo "PASS hand-written and library PLAIN bodies produce identical files"
else
  echo "FAIL the two PLAIN writers diverged"
  exit 1
fi

moon run --target native harness/writer_min -- "$work/rle.parquet" --rle >/dev/null
moon run --target native harness/writer_min -- "$work/dict.parquet" --dict >/dev/null
moon run --target native harness/writer_min -- "$work/delta.parquet" --delta >/dev/null

"$here/duck_read.sh" "$work/plain_lib.parquet" \
  --values "$here/fixtures/plain_int32.values.bin" --type INT32
"$here/duck_read.sh" "$work/rle.parquet" \
  --values "$here/fixtures/rle_bool.values.bin" --type BOOLEAN --count 1000
"$here/duck_read.sh" "$work/dict.parquet" \
  --values "$here/fixtures/dict_int32.values.bin" --type INT32 --count 1000
"$here/duck_read.sh" "$work/delta.parquet" \
  --values "$here/fixtures/delta_int64.values.bin" --type INT64 --count 1000

"$py" "$here/extract_pages.py" \
  "$work/plain_lib.parquet" "$work/rle.parquet" "$work/dict.parquet" \
  "$work/delta.parquet" "$here/fixtures/rle_bool.parquet" \
  "$here/fixtures/dict_int32.parquet" "$here/fixtures/delta_int64.parquet" \
  --out "$work" --quiet
"$py" "$here/diff_bytes.py" \
  "$work/plain_lib.rg0.c0.p0.data.values.bin" \
  "$here/fixtures/plain_int32.values.bin"
"$py" "$here/diff_bytes.py" \
  "$work/rle.rg0.c0.p0.data.values.bin" \
  "$work/rle_bool.rg0.c0.p0.data.values.bin"
"$py" "$here/diff_bytes.py" \
  "$work/dict.rg0.c0.p0.dict.values.bin" \
  "$work/dict_int32.rg0.c0.p0.dict.values.bin"
"$py" "$here/diff_bytes.py" \
  "$work/dict.rg0.c0.p1.data.values.bin" \
  "$work/dict_int32.rg0.c0.p1.data.values.bin"
"$py" "$here/diff_bytes.py" \
  "$work/delta.rg0.c0.p0.data.values.bin" \
  "$work/delta_int64.rg0.c0.p0.data.values.bin"
