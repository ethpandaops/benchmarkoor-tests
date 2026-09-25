#!/usr/bin/env python3
"""Merge one build's eest fixtures into a previous release's tarball.

A build that fills a filtered subset (say, two new benchmarks) produces an
asset with only those fixtures. To ship one release that carries the whole
suite, its fixtures have to join the fixtures an earlier release already holds.

The merge runs per TEST CASE, not per file. A fixture JSON holds a dict keyed
by the full pytest node ID, and one file covers one test function. Replacing
whole files looks equivalent, but it drops cases the moment a filter selects
only some of a function's parameters. So the two dicts are unioned and the
overlay wins every ID collision.

Both sets must describe the same chain, or the merged release is nonsense: a
payload only applies to the head its filler booted on. The script reads
snapshotBlockHash/startBlockHash out of both sides and refuses to write
anything when they disagree.

The base is never unpacked. pre-run.request runs to ~50 GB uncompressed inside
a ~1 GB tarball, and a hosted runner has ~25 GB of disk, so the base streams
through and the bundle stays in flight. Only the overlay lands on disk, and
only its fixtures. Peak memory is one colliding file from each side, so a
collision on a very large fixture file costs that much RAM.

gzip work dominates, so shell out to pigz when it is on PATH (every
GitHub-hosted runner has it) and fall back to the gzip module. The output keeps
GNU tar format, the format every other release asset carries.
"""

import argparse
import datetime
import gzip
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
from contextlib import contextmanager

ARTIFACT_ROOT = "benchmarkoor-build-artifacts"
PAYLOAD_ROOT = f"{ARTIFACT_ROOT}/eest-payloads"
PRERUNS_ROOT = f"{ARTIFACT_ROOT}/pre-runs"

INDEX = ".meta/index.json"
FILL = ".benchmarkoor-fill.json"
BUILD = ".benchmarkoor-build.json"
PYTEST = ".benchmarkoor-pytest-report.json"
REWRITTEN = (INDEX, FILL, BUILD, PYTEST)
# Kept from the base, with the overlay's copy stored beside it under the
# overlay's commit. Neither describes the merged set on its own.
PER_RUN = (".meta/report_fill.html",)
FIXTURE_DIR = "blockchain_tests"

# Cap on the base fixture file parsed just to read its chain anchor. Some run
# to hundreds of MB and any one of them answers the question.
ANCHOR_SAMPLE_MAX = 8 * 1024 * 1024


def has_pigz():
    return shutil.which("pigz") is not None


@contextmanager
def reader(path):
    """A `tarfile` stream over path, decompressed by pigz where available."""
    if has_pigz():
        proc = subprocess.Popen(["pigz", "-dc", path], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
                yield tar
        finally:
            # A caller that stops early leaves pigz writing into a closed pipe;
            # its exit status is meaningless then, so it is not checked.
            proc.stdout.close()
            proc.wait()
    else:
        with tarfile.open(path, mode="r|gz") as tar:
            yield tar


@contextmanager
def writer(path):
    """A `tarfile` stream into path, compressed by pigz where available."""
    if has_pigz():
        with open(path, "wb") as out:
            proc = subprocess.Popen(
                ["pigz", "-c"], stdin=subprocess.PIPE, stdout=out)
            try:
                with tarfile.open(fileobj=proc.stdin, mode="w|",
                                  format=tarfile.GNU_FORMAT) as tar:
                    yield tar
            finally:
                proc.stdin.close()
                if proc.wait() != 0:
                    raise SystemExit(f"pigz failed to write {path}")
    else:
        with gzip.open(path, "wb") as gz:
            with tarfile.open(fileobj=gz, mode="w|",
                              format=tarfile.GNU_FORMAT) as tar:
                yield tar


def walk(path):
    """Yield (tarfile, member) pairs from a streamed tarball."""
    with reader(path) as tar:
        for member in tar:
            yield tar, member


def read(tar, member):
    return tar.extractfile(member).read()


def is_fixture(rel):
    return rel.startswith(FIXTURE_DIR) and rel.endswith(".json")


def anchors_of(cases):
    """The (snapshot, start) block hashes the given fixture cases pin to."""
    return {
        (c.get("snapshotBlockHash"), c.get("startBlockHash"))
        for c in cases.values()
        if isinstance(c, dict)
    }


def add_bytes(tar, name, data, template):
    """Write `data` as `name`, keeping the mode/owner of a real member."""
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mtime = template.mtime
    info.mode = template.mode if template.isreg() else 0o644
    info.uid, info.gid = template.uid, template.gid
    info.uname, info.gname = template.uname, template.gname
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar, name, template):
    """Write a directory member modelled on a real one."""
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = template.mtime
    info.uid, info.gid = template.uid, template.gid
    info.uname, info.gname = template.uname, template.gname
    tar.addfile(info)


def read_overlay(path, prefix, workdir):
    """Pull the client's payload tree out of the overlay tarball."""
    fixtures, meta, sidecars = {}, {}, {}
    for tar, member in walk(path):
        if member.name.startswith(PRERUNS_ROOT + "/"):
            raise SystemExit(
                f"{path} carries its own pre-runs bundle. Its fixtures anchor "
                "on a head the base release does not hold, so they cannot be "
                "merged into it.")
        if not member.isreg() or not member.name.startswith(prefix):
            continue
        rel = member.name[len(prefix):]
        data = read(tar, member)
        if is_fixture(rel):
            out = os.path.join(workdir, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(data)
            fixtures[rel] = out
        elif rel in REWRITTEN:
            sidecars[rel] = data
        else:
            meta[rel] = data
    if not fixtures:
        raise SystemExit(f"{path} holds no fixtures under {prefix}")
    return fixtures, meta, sidecars


def scan_base(path, prefix):
    """Read the base's index, sidecars and one chain anchor, cheaply.

    Stops at the pre-runs bundle, which sits after the payloads, so this never
    touches the expensive part of the archive.
    """
    found = {}
    names, anchor = set(), set()
    for tar, member in walk(path):
        if member.name.startswith(PRERUNS_ROOT + "/"):
            break
        if not member.isreg() or not member.name.startswith(prefix):
            continue
        rel = member.name[len(prefix):]
        if rel in REWRITTEN:
            found[rel] = read(tar, member)
        elif is_fixture(rel):
            names.add(rel)
            if not anchor and member.size <= ANCHOR_SAMPLE_MAX:
                anchor = anchors_of(json.loads(read(tar, member)))
    if not names:
        raise SystemExit(f"{path} holds no fixtures under {prefix}")
    return found, names, anchor


def sha8(value):
    return (value or "unknown")[:8]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True,
                    help="release tarball to merge into")
    ap.add_argument("--overlay", required=True,
                    help="build tarball whose fixtures win collisions")
    ap.add_argument("--client", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source-tag", default="",
                    help="release tag the base came from, for lineage")
    ap.add_argument("--workdir", default="merge-overlay")
    args = ap.parse_args()

    prefix = f"{PAYLOAD_ROOT}/{args.client}/"
    os.makedirs(args.workdir, exist_ok=True)

    print(f"Reading overlay {args.overlay}", flush=True)
    new_fix, new_meta, new_side = read_overlay(
        args.overlay, prefix, args.workdir)
    print(f"  {len(new_fix)} fixture file(s)", flush=True)

    print(f"Scanning base {args.base}", flush=True)
    old_side, base_names, base_anchor = scan_base(args.base, prefix)
    idx = json.loads(old_side[INDEX]) if INDEX in old_side else {}
    fill = json.loads(old_side[FILL]) if FILL in old_side else {}
    print(f"  {len(base_names)} fixture file(s), "
          f"{idx.get('test_count', '?')} case(s)", flush=True)

    # Every payload only applies to the head its filler booted on. Merging two
    # sets that pin to different heads produces a release where one half is
    # replayed against a chain it was never filled for.
    new_anchor = set()
    for disk in new_fix.values():
        with open(disk) as f:
            new_anchor |= anchors_of(json.load(f))
    if base_anchor and new_anchor and base_anchor != new_anchor:
        raise SystemExit(
            "chain anchor mismatch — refusing to merge.\n"
            f"  base    {sorted(base_anchor)}\n"
            f"  overlay {sorted(new_anchor)}")
    print(f"  anchor {sorted(new_anchor)[0]}", flush=True)

    new_fill = json.loads(new_side[FILL]) if FILL in new_side else {}
    new_idx = json.loads(new_side[INDEX]) if INDEX in new_side else {}
    base_sha, new_sha = sha8(fill.get("eest_sha")), sha8(
        new_fill.get("eest_sha"))

    # index.json — union by case ID, overlay wins. root_hash is a hash over
    # the fixtures EEST wrote in one run; it cannot describe two, and the model
    # allows null. The runner never reads this file: it lives beside
    # fixtures_subdir, not inside it.
    cases = {c["id"]: c for c in idx.get("test_cases", [])}
    cases.update({c["id"]: c for c in new_idx.get("test_cases", [])})

    overridden = added = size_delta = 0
    pending = dict(new_fix)
    written, dirs = set(), set()
    template = None
    flushed = False

    with writer(args.out) as out:

        def flush():
            """Write everything the base had no member for."""
            nonlocal added, size_delta

            for rel, disk in sorted(pending.items()):
                name = prefix + rel
                parent, missing = os.path.dirname(name), []
                while parent and parent not in dirs:
                    missing.append(parent)
                    dirs.add(parent)
                    parent = os.path.dirname(parent)
                for d in reversed(missing):
                    add_dir(out, d + "/", template)
                with open(disk) as f:
                    new = json.load(f)
                data = json.dumps(new, indent=4).encode()
                added += len(new)
                size_delta += len(data)
                add_bytes(out, name, data, template)
                written.add(name)
                print(f"  add   {rel}: {len(new)} case(s)", flush=True)

            merged_idx = {
                "root_hash": None,
                "created_at": datetime.datetime.now().isoformat(),
                "test_count": len(cases),
                "forks": sorted({*idx.get("forks", []),
                                 *new_idx.get("forks", [])}),
                "fixture_formats": sorted(
                    {*idx.get("fixture_formats", []),
                     *new_idx.get("fixture_formats", [])}),
                "test_cases": list(cases.values()),
            }
            add_bytes(out, prefix + INDEX,
                      json.dumps(merged_idx, indent=2).encode(), template)

            # fill sidecar — the merged totals, plus where each half came from.
            # benchmarkoor-release reads `filled` for the release notes.
            merged_fill = {**fill, **new_fill}
            merged_fill["filled"] = len(cases)
            merged_fill["failed"] = (fill.get("failed") or 0) \
                + (new_fill.get("failed") or 0)
            merged_fill["size_bytes"] = (fill.get("size_bytes") or 0) \
                + size_delta
            merged_fill["merged_from"] = [
                {"release": args.source_tag or None,
                 "eest_sha": fill.get("eest_sha"),
                 "filter": fill.get("filter"),
                 "filled": idx.get("test_count")},
                {"release": None,
                 "eest_sha": new_fill.get("eest_sha"),
                 "filter": new_fill.get("filter"),
                 "filled": new_fill.get("filled")},
            ]
            add_bytes(out, prefix + FILL,
                      json.dumps(merged_fill, indent=2).encode(), template)

            # Per-run records. Neither pytest report covers the merged set, so
            # neither keeps the canonical name — benchmarkoor-release then
            # reports no pytest counts rather than one run's for two runs.
            for data, sha in ((old_side.get(PYTEST), base_sha),
                              (new_side.get(PYTEST), new_sha)):
                if data:
                    add_bytes(
                        out, f"{prefix}.benchmarkoor-pytest-report.{sha}.json",
                        data, template)
            for rel in PER_RUN:
                if rel in new_meta:
                    stem, dot, ext = rel.rpartition(".")
                    add_bytes(out, f"{prefix}{stem}.{new_sha}{dot}{ext}",
                              new_meta[rel], template)
            # Anything else the overlay's .meta carries that the base did not.
            for rel, data in sorted(new_meta.items()):
                if rel in PER_RUN or prefix + rel in written:
                    continue
                add_bytes(out, prefix + rel, data, template)

            # Build sidecar: the overlay's describes the run being promoted.
            sidecar = new_side.get(BUILD) or old_side.get(BUILD)
            if sidecar:
                add_bytes(out, prefix + BUILD, sidecar, template)

        for tar, member in walk(args.base):
            if template is None:
                template = member
            # The payload tree sits ahead of the pre-runs bundle, and staying
            # in that order matters: a reader that stops at the bundle (this
            # script's own scan, so a merge of a merge) must still see every
            # payload member. So everything added lands at that boundary, not
            # at the end of the archive.
            if not flushed and member.name.startswith(PRERUNS_ROOT + "/"):
                flush()
                flushed = True
            if member.isdir():
                dirs.add(member.name.rstrip("/"))
            rel = (member.name[len(prefix):]
                   if member.name.startswith(prefix) else None)
            # Rewritten or relocated by flush(); never copy the base's copy.
            if rel in REWRITTEN:
                continue
            if rel is not None and rel in pending:
                disk = pending.pop(rel)
                old = json.loads(read(tar, member))
                with open(disk) as f:
                    new = json.load(f)
                shared = len(set(old) & set(new))
                merged = {**old, **new}
                data = json.dumps(merged, indent=4).encode()
                overridden += shared
                added += len(new) - shared
                size_delta += len(data) - member.size
                add_bytes(out, member.name, data, template)
                print(f"  merge {rel}: {len(old)} + {len(new)} "
                      f"({shared} overridden) -> {len(merged)}", flush=True)
            elif member.isreg():
                out.addfile(member, tar.extractfile(member))
            else:
                out.addfile(member)
            written.add(member.name.rstrip("/"))

        # A base with no pre-runs bundle never hit the boundary above.
        if not flushed:
            flush()

    print(f"\nMerged -> {args.out}")
    print(f"  cases      {idx.get('test_count')} -> {len(cases)}")
    print(f"  overridden {overridden}")
    print(f"  added      {added}")
    shutil.rmtree(args.workdir, ignore_errors=True)
if __name__ == "__main__":
    sys.exit(main())
