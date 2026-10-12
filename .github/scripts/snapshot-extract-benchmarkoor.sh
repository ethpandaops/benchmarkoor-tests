#!/usr/bin/env bash
# The benchmarkoor action deletes its binary. Restore it from the same local
# image for the subsequent compaction/export steps; do not pull a moving tag again.
# Env: RUNNER_TEMP, BENCHMARKOOR_IMAGE (empty selects the action's local build).
set -euo pipefail
image=${BENCHMARKOOR_IMAGE:-benchmarkoor:local}
image_id=$(docker image inspect --format '{{.Id}}' "$image")
cid=$(docker create "$image_id")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
bin=${RUNNER_TEMP:?runner temp}/benchmarkoor
docker cp "$cid:/usr/local/bin/benchmarkoor" "$bin"
chmod +x "$bin"
"$bin" db compact --help >/dev/null
"$bin" snapshot export --help >/dev/null
