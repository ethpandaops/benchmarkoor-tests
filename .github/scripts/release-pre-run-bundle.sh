#!/usr/bin/env bash
# Fetch a benchmarkoor-release's pre-run bundle into <dest>/pre_run_bundle, checked
# against the release's sha256. Prints the bundle's pre-run.meta.json.
#   release-pre-run-bundle.sh <release-tag> <dest>
set -euo pipefail
tag=${1:?release tag} dest=${2:?dest dir}
base="https://github.com/${GITHUB_REPOSITORY:-ethpandaops/benchmarkoor-tests}/releases/download/$tag"
dl="$dest/download"
mkdir -p "$dl"

curl -fsSL --retry 5 "$base/manifest.json" -o "$dl/manifest.json"
# Every client's run replays the geth pre-run (test-source.*.runner.yaml), so it is the only one.
asset=$(jq -ce '.assets[] | select(.client == "geth")' "$dl/manifest.json")
tarball=$(jq -r .tarball <<<"$asset")
mapfile -t files < <(jq -r '.files[]' <<<"$asset")

for f in "${files[@]}"; do curl -fsSL --retry 5 "$base/$f" -o "$dl/$f"; done
# Assets over 2 GB are split into .part-NNN; an unsplit asset is the tarball itself.
[ "${#files[@]}" -eq 1 ] && [ "${files[0]}" = "$tarball" ] || { (cd "$dl" && cat "${files[@]}") > "$dl/$tarball"; }
echo "$(jq -r .sha256 <<<"$asset")  $dl/$tarball" | sha256sum -c --quiet -

tar -xzf "$dl/$tarball" -C "$dest" --strip-components=3 benchmarkoor-build-artifacts/pre-runs/geth/pre_run_bundle
rm -rf "$dl"
cat "$dest/pre_run_bundle/pre-run.meta.json"
