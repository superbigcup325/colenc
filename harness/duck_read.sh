#!/bin/sh
# Judge a Parquet file with DuckDB and pyarrow.
#
#   harness/duck_read.sh file.parquet
#   harness/duck_read.sh file.parquet --values fixtures/plain_int32.values.bin --type INT32
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$here/.venv/bin/python" "$here/read_back.py" "$@"
