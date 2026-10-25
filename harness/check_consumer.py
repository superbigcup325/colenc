"""Run a separate consumer against a packaged `superbigcup325/colenc`.

The archive mode uses only what `moon package` produced: the temporary module
has exactly two members, the unpacked archive and this consumer, so neither the
working checkout nor a local `.mooncakes` can satisfy an import by accident. A
fresh `MOON_HOME` fetches the public dependency graph; only the installed
compiler and core are reused, never credentials or a previous package cache.
Nothing is uploaded or published.

`--registry-version` checks the registry copy instead, which is only meaningful
after publishing that version. Both modes run native, wasm-gc and JS.

The consumer program checks its own round trips and prints one line per case;
this script asserts the facts in those lines. Absolute byte counts are pinned
only where the format makes them exact (PLAIN int32, byte-stream-split); sizes
that a future encoder may legitimately change are compared as relations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE = "superbigcup325/colenc"
TARGETS = ("native", "wasm-gc", "js")


def command(args: list[str], cwd: pathlib.Path, env: dict | None = None) -> str:
    proc = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if proc.returncode:
        raise RuntimeError(
            f"{' '.join(args)} exited {proc.returncode}:\n"
            f"{proc.stdout[-2000:]}{proc.stderr[-4000:]}"
        )
    return proc.stdout.strip()


def local_version() -> str:
    manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
    found = re.search(r'(?m)^version\s*=\s*"([^"]+)"', manifest)
    if not found:
        raise ValueError("moon.mod carries no version")
    return found.group(1)


def package_archive() -> pathlib.Path:
    """Build the release archive and return its path."""
    proc = subprocess.run(
        ["moon", "package"], cwd=ROOT, capture_output=True, text=True
    )
    if proc.returncode:
        raise RuntimeError(
            f"moon package failed:\n{proc.stdout[-2000:]}{proc.stderr[-4000:]}"
        )
    for line in (proc.stdout + "\n" + proc.stderr).splitlines():
        if line.startswith("Package to "):
            path = pathlib.Path(line.removeprefix("Package to ").strip())
            path = path if path.is_absolute() else ROOT / path
            if path.is_file():
                return path
    raise RuntimeError("moon package did not identify an existing archive")


def unpack_archive(archive: pathlib.Path, dest: pathlib.Path) -> str:
    with zipfile.ZipFile(archive) as packed:
        for entry in packed.infolist():
            path = pathlib.PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"archive path escapes its package: {entry.filename}")
        packed.extractall(dest)
    manifest = (dest / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'(?m)^name\s*=\s*"([^"]+)"', manifest)
    version = re.search(r'(?m)^version\s*=\s*"([^"]+)"', manifest)
    if not name or name.group(1) != MODULE or not version:
        raise ValueError(f"archive must contain {MODULE} with a version")
    if (dest / "moon.work").exists() or (dest / ".mooncakes").exists():
        raise ValueError("archive carries a workspace override or a dependency cache")
    if (dest / "harness").exists():
        raise ValueError("archive carries the repository-only harness")
    return version.group(1)


def fresh_moon_home(dest: pathlib.Path) -> None:
    executable = shutil.which("moon")
    if not executable:
        raise RuntimeError("moon is not on PATH")
    toolchain = pathlib.Path(executable).resolve().parent.parent
    dest.mkdir()
    for name in ("bin", "lib", "include"):
        source = toolchain / name
        if not source.is_dir():
            raise RuntimeError(f"cannot locate installed toolchain directory: {source}")
        (dest / name).symlink_to(source, target_is_directory=True)


def parse(output: str) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        name, *fields = line.split("|")
        if name in rows:
            raise ValueError(f"consumer printed {name} twice")
        rows[name] = fields
    return rows


def expect(rows: dict[str, list[str]], name: str, fields: list[str]) -> None:
    if rows.get(name) != fields:
        raise ValueError(f"{name}: expected {fields}, got {rows.get(name)}")


def numbers(rows: dict[str, list[str]], name: str, count: int) -> list[int]:
    fields = rows.get(name)
    if fields is None or len(fields) != count:
        raise ValueError(f"{name}: expected {count} numeric fields, got {fields}")
    try:
        return [int(field) for field in fields]
    except ValueError:
        raise ValueError(f"{name}: non-numeric fields {fields}") from None


def check_output(output: str, version: str, expected_version: str | None) -> None:
    rows = parse(output)
    wanted = {
        "plain-int32",
        "delta-int64",
        "rle-bool",
        "bss-double",
        "delta-byte-array",
        "fsst",
        "dictionary",
        "roaring",
        "names",
        "errors",
    }
    if set(rows) != wanted:
        raise ValueError(f"consumer printed {sorted(rows)}, expected {sorted(wanted)}")

    # PLAIN is fixed-width, so these two are arithmetic rather than a guess:
    # sixteen int32 values are 64 bytes, and byte-stream-split permutes the
    # 64 bytes of eight doubles without changing the count.
    expect(rows, "plain-int32", ["16", "64", "64"])
    expect(rows, "bss-double", ["64", "64"])

    # Sizes a future encoder may legitimately change are compared as relations
    # against PLAIN, not as exact byte counts.
    delta = numbers(rows, "delta-int64", 2)
    if not 0 < delta[0] < 64 * 8:
        raise ValueError(f"delta-int64: {delta[0]} bytes for a 512-byte PLAIN column")
    if delta[1] != delta[0]:
        raise ValueError(f"delta-int64: reported {delta[1]} bytes, produced {delta[0]}")
    if not 0 < numbers(rows, "rle-bool", 1)[0] < 60:
        raise ValueError(f"rle-bool: {rows['rle-bool'][0]} bytes for 60 booleans")
    encoded, plain = numbers(rows, "delta-byte-array", 2)
    if not 0 < encoded < plain:
        raise ValueError(f"delta-byte-array: {encoded} bytes against {plain} PLAIN")
    if numbers(rows, "fsst", 1)[0] <= 0:
        raise ValueError("fsst: empty encoding")

    # Three distinct values select a two-bit index width by the reference rule.
    dictionary = numbers(rows, "dictionary", 4)
    if dictionary[0] != 3 or dictionary[1] != 2:
        raise ValueError(f"dictionary: expected 3 entries at width 2, got {dictionary}")
    if not 0 < dictionary[2] <= 3 * 4:
        raise ValueError(f"dictionary: dictionary page is {dictionary[2]} bytes")
    if not 0 < dictionary[3] < 9 * 4:
        raise ValueError(f"dictionary: index stream {dictionary[3]} bytes against 36 PLAIN")

    # Seven ids spread over three keys: the set is deduplicated, and the union
    # with a disjoint three-id set has six.
    roaring = numbers(rows, "roaring", 3)
    if roaring[0] != 7 or roaring[2] != 6:
        raise ValueError(f"roaring: cardinalities {roaring[0]} and {roaring[2]}")
    if roaring[1] <= 0:
        raise ValueError("roaring: empty encoding")

    expect(rows, "names", ["ROARING", "INT32"])
    expect(rows, "errors", ["out-of-range", "type-mismatch"])
    if expected_version is not None and version != expected_version:
        raise ValueError(f"version {version} does not match {expected_version}")


def check_consumer(
    archive: pathlib.Path | None = None,
    registry_version: str | None = None,
) -> dict:
    if archive is not None and registry_version is not None:
        raise ValueError("choose an archive or a registry version, not both")
    archive = archive.resolve() if archive is not None else None
    if registry_version is None and archive is None:
        archive = package_archive()
    record = {
        "schema": 1,
        "source": "archive" if archive else "registry",
        "toolchain": command(["moon", "version", "--all"], ROOT),
        "targets": {},
    }
    if archive:
        with archive.open("rb") as stream:
            record["archive_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()

    with tempfile.TemporaryDirectory(prefix="colenc-consumer-") as tmp:
        work = pathlib.Path(tmp)
        if archive:
            version = unpack_archive(archive, work / "package")
            expected = local_version()
            if version != expected:
                raise ValueError(
                    f"archive version {version} does not match moon.mod {expected}"
                )
            (work / "moon.work").write_text(
                'members = ["./package", "./consumer"]\n', encoding="utf-8"
            )
        else:
            version = registry_version
        record["version"] = version
        consumer = work / "consumer"
        consumer.mkdir()
        for name in ("main.mbt", "moon.pkg"):
            shutil.copyfile(ROOT / "harness" / "consumer" / name, consumer / name)
        (consumer / "moon.mod").write_text(
            'name = "colenc-acceptance/consumer"\nversion = "0.0.0"\n'
            f"import {{ {json.dumps(MODULE + '@' + version)} }}\n",
            encoding="utf-8",
        )
        moon_home = work / "moon-home"
        fresh_moon_home(moon_home)
        env = dict(os.environ, MOON_HOME=str(moon_home))
        print(f"consumer: {record['source']} {version}; fresh registry and dependency cache", flush=True)
        command(["moon", "update"], consumer, env)
        for target in TARGETS:
            output = command(
                ["moon", "run", "--target", target, "--deny-warn", "."], consumer, env
            )
            check_output(output, version, None)
            record["targets"][target] = "passed"
            print(
                f"ok: consumer {target} — PLAIN, RLE, dictionary, delta family, "
                "BSS, FSST, Roaring set ops and the typed error paths",
                flush=True,
            )
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--archive", type=pathlib.Path, help="default: build with moon package")
    source.add_argument(
        "--registry-version",
        help="check the registry copy instead (only after publishing that version)",
    )
    parser.add_argument("--json-out", type=pathlib.Path)
    args = parser.parse_args()
    try:
        record = check_consumer(args.archive, args.registry_version)
    except (RuntimeError, ValueError, OSError, zipfile.BadZipFile) as error:
        print(f"FAIL: {error}")
        return 1
    if args.json_out:
        args.json_out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print("consumer acceptance: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
