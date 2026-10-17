#!/usr/bin/env python3
"""Generate the byte-diff reference samples (T0.1).

Each sample is a one-column Parquet file written by pyarrow with an explicitly
requested encoding, plus the expected values as PLAIN-encoded bytes (little
endian, no length prefix for fixed width types, 4-byte LE length prefix for
BYTE_ARRAY, one byte per BOOLEAN). Those PLAIN bytes are what the MoonBit side
must reproduce and what the duckdb judge compares against.

Determinism: the sample data is hard-coded, statistics and the Arrow schema are
not written, and the writer settings are pinned here. With the pyarrow version
in requirements.txt the output is reproducible; `--check` re-generates in
memory and diffs against the committed fixtures.

Usage:
    python3 harness/make_refs.py            # write fixtures/ + manifest.json
    python3 harness/make_refs.py --check    # regenerate and diff, write nothing
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE / "fixtures"

FORMAT_VERSION = "2.6"
DATA_PAGE_VERSION = "1.0"

# Sample data is fixed on purpose: fixture bytes must never depend on a clock,
# a random seed or the order of a directory listing.
PLAIN_INT32 = [i * 7 - 300 for i in range(1000)]
PLAIN_STRING = [f"bead-{i:04d}" for i in range(200)]
DICT_STRING = ["black", "white", "red", "green"]
DICT_VALUES = [DICT_STRING[(i * 7 + i // 10) % 4] for i in range(1000)]
DELTA_INT64 = [7 + 3 * i for i in range(1000)]
# Eight distinct integers, with runs and jumps so the index stream exercises
# both repeated and literal runs at a width above one bit.
DICT_INT32 = [(i * 3 + i // 7) % 8 for i in range(1000)]
# Varied deltas, including negative jumps, so the frame of reference and the
# per-miniblock widths both move.
DELTA_INT32 = [((i * 37) % 151) - 75 for i in range(1000)]
DELTA_LENGTH_STRINGS = [f"item-{i % 40:03d}" for i in range(300)]
# Long shared prefixes, so DELTA_BYTE_ARRAY actually saves bytes.
DELTA_BYTE_ARRAY_STRINGS = [f"shared-prefix-{i:05d}" for i in range(300)]
BSS_FLOAT32 = [i / 7.0 for i in range(1000)]
RLE_BOOL = [i % 3 == 0 for i in range(1000)]
# Runs on both sides of the eight-value threshold, a stretch long enough to
# force the 63-group literal cap, and mixed tails so the end-of-stream flush
# and padding paths are exercised.
RLE_RUNS = (
    [False] * 9
    + [True] * 8
    + [False] * 7
    + [True]
    + [False] * 3
    + [True] * 20
    + [False] * 20
    + [i % 2 == 0 for i in range(600)]
    + [True] * 5
    + [False]
    + [True] * 2
)


@dataclass(frozen=True)
class Sample:
    name: str
    column: str
    arrow_type: pa.DataType
    physical_type: str
    values: list
    encoding: str
    write_options: dict

    def array(self) -> pa.Array:
        return pa.array(self.values, type=self.arrow_type)

    def table(self) -> pa.Table:
        field = pa.field(self.column, self.arrow_type, nullable=False)
        return pa.table([self.array()], schema=pa.schema([field]))

    def plain_bytes(self) -> bytes:
        """Expected values in Parquet PLAIN form (required column, no levels)."""
        values = self.array().to_pylist()
        if self.physical_type == "INT32":
            return b"".join(struct.pack("<i", v) for v in values)
        if self.physical_type == "INT64":
            return b"".join(struct.pack("<q", v) for v in values)
        if self.physical_type == "FLOAT":
            return b"".join(struct.pack("<f", v) for v in values)
        if self.physical_type == "DOUBLE":
            return b"".join(struct.pack("<d", v) for v in values)
        if self.physical_type == "BOOLEAN":
            # Parquet PLAIN bits, LSB first, eight values per byte.
            out = bytearray((len(values) + 7) // 8)
            for index, value in enumerate(values):
                if value:
                    out[index // 8] |= 1 << (index % 8)
            return bytes(out)
        if self.physical_type == "BYTE_ARRAY":
            out = bytearray()
            for v in values:
                raw = v.encode("utf-8")
                out += struct.pack("<I", len(raw)) + raw
            return bytes(out)
        raise ValueError(f"{self.name}: unknown physical type {self.physical_type}")


SAMPLES = [
    Sample(
        name="plain_int32",
        column="i32",
        arrow_type=pa.int32(),
        physical_type="INT32",
        values=PLAIN_INT32,
        encoding="PLAIN",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"i32": "PLAIN"},
        },
    ),
    Sample(
        name="plain_string",
        column="words",
        arrow_type=pa.string(),
        physical_type="BYTE_ARRAY",
        values=PLAIN_STRING,
        encoding="PLAIN",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"words": "PLAIN"},
        },
    ),
    Sample(
        name="dict_string",
        column="labels",
        arrow_type=pa.string(),
        physical_type="BYTE_ARRAY",
        values=DICT_VALUES,
        encoding="RLE_DICTIONARY",
        write_options={"use_dictionary": True},
    ),
    Sample(
        name="dict_int32",
        column="i32",
        arrow_type=pa.int32(),
        physical_type="INT32",
        values=DICT_INT32,
        encoding="RLE_DICTIONARY",
        write_options={"use_dictionary": True},
    ),
    Sample(
        name="delta_int32",
        column="i32",
        arrow_type=pa.int32(),
        physical_type="INT32",
        values=DELTA_INT32,
        encoding="DELTA_BINARY_PACKED",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"i32": "DELTA_BINARY_PACKED"},
        },
    ),
    Sample(
        name="delta_length_string",
        column="s",
        arrow_type=pa.string(),
        physical_type="BYTE_ARRAY",
        values=DELTA_LENGTH_STRINGS,
        encoding="DELTA_LENGTH_BYTE_ARRAY",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"s": "DELTA_LENGTH_BYTE_ARRAY"},
        },
    ),
    Sample(
        name="delta_byte_array_string",
        column="s",
        arrow_type=pa.string(),
        physical_type="BYTE_ARRAY",
        values=DELTA_BYTE_ARRAY_STRINGS,
        encoding="DELTA_BYTE_ARRAY",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"s": "DELTA_BYTE_ARRAY"},
        },
    ),
    Sample(
        name="delta_int64",
        column="i64",
        arrow_type=pa.int64(),
        physical_type="INT64",
        values=DELTA_INT64,
        encoding="DELTA_BINARY_PACKED",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"i64": "DELTA_BINARY_PACKED"},
        },
    ),
    Sample(
        name="bss_float32",
        column="f32",
        arrow_type=pa.float32(),
        physical_type="FLOAT",
        values=BSS_FLOAT32,
        encoding="BYTE_STREAM_SPLIT",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"f32": "BYTE_STREAM_SPLIT"},
        },
    ),
    Sample(
        name="bss_double",
        column="f64",
        arrow_type=pa.float64(),
        physical_type="DOUBLE",
        values=[i * 0.1 - 3.25 for i in range(1000)],
        encoding="BYTE_STREAM_SPLIT",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"f64": "BYTE_STREAM_SPLIT"},
        },
    ),
    Sample(
        name="rle_bool",
        column="flags",
        arrow_type=pa.bool_(),
        physical_type="BOOLEAN",
        values=RLE_BOOL,
        encoding="RLE",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"flags": "RLE"},
        },
    ),
    Sample(
        name="rle_bool_runs",
        column="flags",
        arrow_type=pa.bool_(),
        physical_type="BOOLEAN",
        values=RLE_RUNS,
        encoding="RLE",
        write_options={
            "use_dictionary": False,
            "column_encoding": {"flags": "RLE"},
        },
    ),
]


def write_parquet(sample: Sample) -> bytes:
    """Write one sample to memory with the settings fixed by this rig."""
    sink = pa.BufferOutputStream()
    pq.write_table(
        sample.table(),
        sink,
        version=FORMAT_VERSION,
        data_page_version=DATA_PAGE_VERSION,
        compression="none",
        write_statistics=False,
        store_schema=False,
        **sample.write_options,
    )
    return sink.getvalue().to_pybytes()


def observed_encodings(data: bytes) -> tuple[list[str], bool]:
    metadata = pq.ParquetFile(pa.BufferReader(data)).metadata
    column = metadata.row_group(0).column(0)
    return list(column.encodings), bool(column.has_dictionary_page)


def check_encoding(sample: Sample, encodings: list[str], has_dict_page: bool) -> None:
    """Fail loudly if pyarrow silently picked a different encoding.

    Small samples and unsupported combinations make parquet-cpp fall back to
    PLAIN without a warning. A fixture whose bytes do not actually exercise the
    encoding it names would quietly weaken every later byte diff.
    """
    if sample.encoding == "PLAIN":
        ok = "PLAIN" in encodings and not has_dict_page
    elif sample.encoding == "RLE_DICTIONARY":
        ok = (
            bool({"RLE_DICTIONARY", "PLAIN_DICTIONARY"} & set(encodings))
            and has_dict_page
        )
    else:
        ok = sample.encoding in encodings
    if not ok:
        raise SystemExit(
            f"{sample.name}: asked for {sample.encoding}, pyarrow wrote "
            f"{encodings} (dictionary page: {has_dict_page})"
        )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build() -> tuple[dict[str, tuple[bytes, bytes]], dict]:
    """Return {sample name: (parquet bytes, PLAIN values bytes)} and the manifest."""
    built: dict[str, tuple[bytes, bytes]] = {}
    entries = []
    for sample in SAMPLES:
        parquet = write_parquet(sample)
        encodings, has_dict_page = observed_encodings(parquet)
        check_encoding(sample, encodings, has_dict_page)
        values = sample.plain_bytes()
        built[sample.name] = (parquet, values)
        entries.append(
            {
                "name": sample.name,
                "parquet": f"{sample.name}.parquet",
                "values": f"{sample.name}.values.bin",
                "column": sample.column,
                "physical_type": sample.physical_type,
                "encoding": sample.encoding,
                "count": len(sample.values),
                "row_groups": 1,
                "observed_encodings": encodings,
                "has_dictionary_page": has_dict_page,
                "parquet_sha256": sha256(parquet),
                "parquet_bytes": len(parquet),
                "values_sha256": sha256(values),
                "values_bytes": len(values),
            }
        )
    manifest = {
        "generator": "harness/make_refs.py",
        "pyarrow_version": pa.__version__,
        "parquet_format_version": FORMAT_VERSION,
        "data_page_version": DATA_PAGE_VERSION,
        "compression": "none",
        "write_statistics": False,
        "store_arrow_schema": False,
        "row_group_columns": "required (nullable=False), flat",
        "expected_values_encoding": "PLAIN with no level bytes; BOOLEAN bit-packed LSB first",
        "samples": sorted(entries, key=lambda e: e["name"]),
    }
    return built, manifest


def manifest_bytes(manifest: dict) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()


def write_fixtures(
    out: Path, built: dict[str, tuple[bytes, bytes]], manifest: dict
) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, (parquet, values) in built.items():
        (out / f"{name}.parquet").write_bytes(parquet)
        (out / f"{name}.values.bin").write_bytes(values)
    (out / "manifest.json").write_bytes(manifest_bytes(manifest))
    print(f"wrote {len(built)} samples to {out}")


def check_fixtures(
    out: Path, built: dict[str, tuple[bytes, bytes]], manifest: dict
) -> int:
    from diff_bytes import first_difference

    failures = 0

    def compare(label: str, actual: bytes, expected: bytes) -> None:
        nonlocal failures
        if actual == expected:
            print(f"  PASS  {label}")
            return
        offset = first_difference(actual, expected)
        failures += 1
        print(
            f"  FAIL  {label}: first difference at byte {offset} "
            f"(generated {len(actual)} bytes, on disk {len(expected)} bytes)"
        )

    for name, (parquet, values) in sorted(built.items()):
        parquet_path = out / f"{name}.parquet"
        values_path = out / f"{name}.values.bin"
        if not parquet_path.exists() or not values_path.exists():
            failures += 1
            print(f"  FAIL  {name}: fixture missing")
            continue
        compare(f"{name}.parquet", parquet, parquet_path.read_bytes())
        compare(f"{name}.values.bin", values, values_path.read_bytes())

    manifest_path = out / "manifest.json"
    if manifest_path.exists():
        compare("manifest.json", manifest_bytes(manifest), manifest_path.read_bytes())
    else:
        failures += 1
        print("  FAIL  manifest.json: missing")

    if failures:
        print(f"\n{failures} fixture mismatch(es) — regenerate with make_refs.py")
        return 1
    print("\nfixtures are reproducible: every sample matches")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out", type=Path, default=DEFAULT_OUT, help="fixture directory"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate in memory and diff against the fixtures on disk",
    )
    args = parser.parse_args(argv)

    built, manifest = build()
    if args.check:
        print(f"checking {args.out}")
        return check_fixtures(args.out, built, manifest)
    write_fixtures(args.out, built, manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
