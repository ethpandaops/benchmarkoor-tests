#!/usr/bin/env bash
# Reopen the stopped snapshot with the consumer chainspec before publication.
# Env: DATADIR, SNAPSHOT_IMAGE, SNAPSHOT_TAIL_DIR, AMSTERDAM_TIME, W.
set -euo pipefail
DATADIR=${DATADIR:?datadir}; SNAPSHOT_IMAGE=${SNAPSHOT_IMAGE:?image}
GENESIS=${W:?work directory}/nethermind-reopen-genesis.json
OUT=$W/nethermind-reopen
expected=${SNAPSHOT_TAIL_DIR:?tail directory}/head.json
name=snapshot-nethermind-reopen-${GITHUB_RUN_ID:-$$}
url=$(sed -n 's/^ *GETH_GENESIS: *//p' configs/datadirs/jochemnet/v1/global.yaml)
[ -n "$url" ]
# Geth permits unprefixed alloc addresses; Nethermind's genesis reader requires 0x.
curl -fsSL --max-time 60 "$url" | jq --argjson ams "${AMSTERDAM_TIME:?fork timestamp}" '
  .config.amsterdamTime = $ams |
  .alloc |= with_entries(.key |= if startswith("0x") then . else "0x" + . end)
' > "$GENESIS"
mkdir -p "$OUT"
rm -f "$OUT/PASS"
want=$(jq -er .result.hash "$expected")
number=$(jq -er .result.number "$expected")
state_root=$(jq -er .result.stateRoot "$expected")
DBREL=nethermind_db/mainnet
[ ! -d "$DATADIR/mainnet" ] || DBREL=mainnet
[ -d "$DATADIR/$DBREL" ]
[ "$(jq -r .config.amsterdamTime "$GENESIS")" = "$AMSTERDAM_TIME" ]
[ -z "$(docker ps -aq --filter "name=^${name}$")" ]
cleanup() {
  docker stop -t 600 "$name" > "$OUT/stop.log" 2>&1 || true
  docker logs "$name" > "$OUT/container.log" 2>&1 || true
  docker inspect -f '{{.State.ExitCode}}' "$name" > "$OUT/exit-code" 2>/dev/null || true
  docker rm "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --name "$name" --user 0:0 --network host \
  -v "$DATADIR:/data" -v "$GENESIS:/network-genesis.json:ro" "$SNAPSHOT_IMAGE" \
  --config=mainnet --datadir=/data --Init.ChainSpecPath=/network-genesis.json --Merge.TerminalTotalDifficulty=0 \
  --Init.BaseDbPath="/data/$DBREL" --FlatDb.Enabled=true \
  --Network.MaxActivePeers=0 --Init.DiscoveryEnabled=false \
  --Network.DiscoveryPort=30399 --Network.P2PPort=30399 \
  --JsonRpc.Enabled=true --JsonRpc.Host=127.0.0.1 --JsonRpc.Port=18545 \
  --JsonRpc.EngineHost=127.0.0.1 --JsonRpc.EnginePort=18551 \
  --Sync.NetworkingEnabled=false --Sync.FastSync=false --Sync.SnapSync=false
for ((n=0; n<180; n++)); do
  if curl -fsS --max-time 5 -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' \
    http://127.0.0.1:18545 > "$OUT/head.tmp.json" 2>/dev/null; then
    mv "$OUT/head.tmp.json" "$OUT/head.json"
    jq -c '.result | {number,hash,stateRoot}' "$OUT/head.json"
    if jq -e --arg want "$want" --arg number "$number" --arg root "$state_root" '.result.hash == $want and .result.number == $number and .result.stateRoot == $root' "$OUT/head.json" >/dev/null; then
      curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_config","params":[]}' \
        http://127.0.0.1:18545 > "$OUT/eth-config.json"
      activation=$(jq -er '.result.current.activationTime' "$OUT/eth-config.json")
      [[ "$activation" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]]
      [ "$((activation))" -eq "$AMSTERDAM_TIME" ]
      for addr in 0x0000bff46984e3725691fa540a8c7589300d8282 0x000064d678505ad48f8ccb093bc65613800e8282; do
        curl -fsS --max-time 10 -H 'Content-Type: application/json' \
          --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$addr\",\"latest\"]}" \
          http://127.0.0.1:18545 > "$OUT/code-$addr.json"
        jq -e '.result | type == "string" and length > 2' "$OUT/code-$addr.json" >/dev/null
      done
      cleanup
      trap - EXIT
      case "$(cat "$OUT/exit-code")" in 0|130|143) ;; *) exit 1 ;; esac
      date -u +%FT%TZ > "$OUT/PASS"
      echo 'PASS: Nethermind reopens offline at the snapshot head'
      exit 0
    fi
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
  sleep 5
done
echo 'FAIL: Nethermind did not reopen at the required head' >&2
exit 1
