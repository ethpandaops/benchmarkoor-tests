#!/usr/bin/env python3
"""Copy a pre-runs bundle from one release tarball into another.

A build with no `pre_runs` stage of its own still fills against a pre-run head:
its filler boots on a datadir an earlier build advanced. The runner replays the
bundle out of the SAME tarball as the fixtures, because a runner `pre_runs:`
block takes only a `fixtures_subdir` and never a URL of its own. So the bundle
has to travel inside the release, or the runner starts at the raw snapshot head
and every payload is an orphan.

The bundle does not fit on a hosted runner: `pre-run.request` is ~47 GB
uncompressed for a 41k-payload replay. So never unpack either archive. Read
both as streams, write one stream out, and keep the big member in flight. Disk
holds only the two inputs and the merged output.

gzip work dominates the run time, so shell out to pigz when it is on PATH
(every GitHub-hosted runner has it) and fall back to the gzip module.

The output keeps GNU tar format, the format every other release asset carries,
because the builds write theirs with GNU tar. Python defaults to PAX instead,
and there is no reason to hand the runner a format no other asset uses.
"""

import argparse
import gzip
import shutil
import subprocess
import sys
import tarfile
from contextlib import contextmanager

PRERUNS_ROOT = "benchmarkoor-build-artifacts/pre-runs"
# The runner replays this file; a bundle without it is not replayable.
BUNDLE_MARKER = "pre_run_bundle/pre-run.request"


def has_pigz():
    return shutil.which("pigz") is not None


@contextmanager
def reader(path):
    """A `tarfile` stream over path, decompressed by pigz where available."""
    if has_pigz():
        proc = subprocess.Popen(
            ["pigz", "-dc", path], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
                yield tar
        finally:
            proc.stdout.close()
            if proc.wait() != 0:
                raise SystemExit(f"pigz failed to read {path}")
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


def copy(src, dst, member):
    """Move one member across, streaming any payload rather than reading it."""
    if member.isreg():
        dst.addfile(member, src.extractfile(member))
    else:
        dst.addfile(member)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--into", required=True, help="tarball to add the bundle to")
    ap.add_argument("--source", required=True, help="tarball to take it from")
    ap.add_argument("--client", required=True, help="client whose bundle to take")
    ap.add_argument("--out", required=True, help="merged tarball to write")
    args = ap.parse_args()

    prefix = f"{PRERUNS_ROOT}/{args.client}/"
    kept = 0
    marker_seen = False

    with writer(args.out) as out:
        with reader(args.into) as base:
            for member in base:
                # Refuse to shadow a bundle this build made itself: a duplicate
                # path in a tar is silent, and the runner reads whichever
                # extracts last.
                if member.name.startswith(PRERUNS_ROOT + "/"):
                    raise SystemExit(
                        f"{args.into} already carries {member.name}. "
                        "That build made its own bundle; do not copy one over it.")
                copy(base, out, member)

        with reader(args.source) as src:
            for member in src:
                # The bundle only, never the source release's own fixtures.
                if not member.name.startswith(prefix):
                    continue
                copy(src, out, member)
                kept += 1
                if member.name == prefix + BUNDLE_MARKER:
                    marker_seen = True
                    print(f"  {member.name}  {member.size} bytes", flush=True)

    if not marker_seen:
        raise SystemExit(
            f"{args.source} carries no {prefix}{BUNDLE_MARKER} to copy.")
    print(f"Copied {kept} member(s) under {prefix} into {args.out}")


if __name__ == "__main__":
    sys.exit(main())
