#!/bin/bash
# After the pre-run: walk the gas limit down, push the fill out of geth's journal, compact, and
# write the reference digest the replaying clients are checked against.
#   GAS_TARGET=200000000 shadowfork/finalize.sh
#
# Why each step (shadowfork/README.md, "A clean image"):
# - geth's path scheme keeps the last 128 blocks as in-memory diff layers and everything older but
#   unflushed in a write buffer (up to 256 MiB); a clean stop writes both to triedb/merkle.journal,
#   and the next start reads them back into memory. The pre-run's last ~1,200 blocks of deployed
#   contracts sat there (2026-10-08), so a benchmark found them in RAM rather than on disk.
#   --cache.gc=0 makes the buffer 0 bytes: every block that leaves the diff layers is flushed.
# - Freshly written keys sit in the top LSM levels while mainnet's state is in the bottom ones;
#   `geth db compact` rewrites everything to the bottom level.
source "$(dirname "$0")/lib.sh"
source "$WORK/anchor.env"
GAS_TARGET=${GAS_TARGET:-200000000}
B=$WORK/bundle/pre_run_bundle
[ -f "$B/pre-run.meta.json" ] || die "no bundle at $B"
lines=$(wc -l < "$B/pre-run.request"); payloads=$(jq .payloads "$B/pre-run.meta.json")
[ "$lines" -eq $((payloads * 2)) ] || die "bundle has $lines lines for $payloads payloads"

log "=== ramp-down to $GAS_TARGET with a 0-byte write buffer ==="
boot_geth --cache.gc=0 --miner.gaslimit="$GAS_TARGET"
docker logs sf-geth 2>&1 | grep -q 'buffer=0.00B' || die "geth did not start with a 0-byte write buffer"
python3 "$SF_DIR/rampdown.py" "http://127.0.0.1:$P_RPC" "http://127.0.0.1:$P_ENGINE" "$WORK/jwtsecret" "$WORK/bundle" "$GAS_TARGET"
stop_geth rampdown
# The journal may hold the 128 diff layers of the last (empty) blocks and nothing else.
grep -E 'Persisting dirty state' "$WORK/geth-rampdown.log" | tail -1
grep -E 'Persisting dirty state.*layers=128$' "$WORK/geth-rampdown.log" >/dev/null \
  || die "geth journaled more than the 128 diff layers: the fill is still in memory"

log "=== geth db compact ==="
docker run --rm -v "$DATADIR:/data" "$GETH_IMAGE" db compact --datadir=/data 2>&1 | tail -5

log "=== reopen and reference digest ==="
END=$(jq .end_block_number "$B/pre-run.meta.json"); END_HASH=$(jq -r .end_block_hash "$B/pre-run.meta.json")
boot_geth
h=$(rpc eth_getBlockByNumber '["latest",false]')
[ "$(( $(jq -r .result.number <<<"$h") ))" = "$END" ] && [ "$(jq -r .result.hash <<<"$h")" = "$END_HASH" ] \
  || die "geth reopens at $(jq -c '.result | [.number, .hash]' <<<"$h"), not $END $END_HASH"
# The same heights lib/replay.py digests on a replaying client: first payload, every n/200th.
start=$(head -1 "$B/pre-run.request" | jq -r '.params[0].blockNumber'); start=$((start))
n=$(jq .payloads "$B/pre-run.meta.json"); step=$(( n / 200 > 0 ? n / 200 : 1 ))
for ((b = start; b < start + n; b += step)); do
  r=$(rpc eth_getBlockByNumber "[\"$(printf 0x%x $b)\",false]")
  jq -r --argjson b "$b" '"\($b) \(.result.hash) \(.result.stateRoot) \(.result.gasUsed) \(.result.blockAccessListHash // "none")"' <<<"$r"
done > "$WORK/digest-geth.txt"
rpc eth_getBlockByNumber "[\"$(printf 0x%x "$END")\",true]" > "$WORK/_snapshot_eth_getBlockByNumber.json"
stop_geth final
log "image head $END $END_HASH, gas limit $(( $(jq -r .result.gasLimit "$WORK/_snapshot_eth_getBlockByNumber.json") )), $(wc -l < "$WORK/digest-geth.txt") digest heights"
