#!/usr/bin/env python3
"""Carve the pages out of Parquet files into standalone blobs (T0.3).

For every page this writes the value-section bytes (and the level-section bytes
when a column has levels) next to a JSON description of where they came from.
The blobs are the inputs to `diff_bytes.py`: colenc encodes a column, the rig
diffs the result against the reference blob.

Usage:
    python3 harness/extract_pages.py fixtures/*.parquet --out /tmp/pages
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
from parquet_pages import iter_pages


def safe_name(path: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in path)


def extract(path: Path, out: Path) -> dict:
    data = path.read_bytes()
    parquet_file = pq.ParquetFile(path)
    pages = iter_pages(data, parquet_file)
    stem = path.stem
    records = []

    for page in pages:
        base = f"{stem}.rg{page.row_group}.c{page.column_index}.p{page.page_index}"
        kind = "dict" if page.page_type == "DICTIONARY_PAGE" else "data"
        values_path = out / f"{base}.{kind}.values.bin"
        values_path.write_bytes(
            data[page.values_offset : page.values_offset + page.values_len]
        )

        record = page.to_dict()
        record["values_file"] = values_path.name
        if page.levels_len:
            levels_path = out / f"{base}.{kind}.levels.bin"
            levels_path.write_bytes(data[page.body_offset : page.values_offset])
            record["levels_file"] = levels_path.name
        records.append(record)

    description = {
        "source": path.name,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "columns": sorted({page.column_path for page in pages}),
        "pages": records,
    }
    (out / f"{stem}.pages.json").write_text(
        json.dumps(description, indent=2, sort_keys=True) + "\n"
    )
    return description


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    args.out.mkdir(parents=True, exist_ok=True)
    failures = 0
    for path in args.inputs:
        try:
            description = extract(path, args.out)
        except (OSError, ValueError, pa.ArrowException) as error:
            failures += 1
            print(f"FAIL {path}: {type(error).__name__}: {error}", file=sys.stderr)
            continue
        if not args.quiet:
            summary = ", ".join(
                f"{page['column_path']}:{page['page_type']}:{page['encoding']}"
                for page in description["pages"]
            )
            print(f"{path.name}: {summary}")

    if failures:
        print(f"{failures} file(s) failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
