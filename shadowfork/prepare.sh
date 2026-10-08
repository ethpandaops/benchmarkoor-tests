#!/bin/bash
# Download the anchor mainnet geth snapshot and write the pre-run's genesis.
#   shadowfork/prepare.sh [block|latest]
# Amsterdam is scheduled 3 s after the snapshot head: the pre-run's two funding/predeploy blocks
# are Osaka (the EIP-8282 contracts must exist before the fork), everything after is Amsterdam.
source "$(dirname "$0")/lib.sh"
BLOCK=${1:-latest}
[ "$BLOCK" != latest ] || BLOCK=$(curl -sf "$SNAP/mainnet/geth/latest" | tr -d '[:space:]')
[[ "$BLOCK" =~ ^[0-9]+$ ]] || die "no anchor block ($BLOCK)"
DATADIR=$WORK/geth-datadir
URL=$SNAP/mainnet/geth/$BLOCK/snapshot.tar.zst

# The pre-run advances the datadir in place, so the disk needs the extracted snapshot plus the
# fill's delta, its fixtures and the bundle (55 GB at 100k receivers per variant).
need=$(( $(curl -sf "$SNAP/mainnet/geth/$BLOCK/_snapshot_metadata.json" | jq -r .data_size_bytes) + 400 * 1024**3 ))
free=$(( $(df -B1 --output=avail "$WORK" | tail -1) ))
[ "$free" -gt "$need" ] || die "$WORK has $((free / 1024**3)) GiB free, needs $((need / 1024**3))"

if [ ! -f "$DATADIR/.complete" ]; then
  sudo rm -rf "$DATADIR"; mkdir -p "$DATADIR/geth"
  log "downloading mainnet/geth/$BLOCK ($(curl -sfI "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{printf "%.0f GiB", $2/2^30}'))"
  # The published snapshot has no geth/ prefix; geth wants <datadir>/geth/chaindata.
  "$SF_DIR/pfetch.sh" "$URL" "${PFETCH_WORKERS:-16}" | zstd -d --stdout | sudo tar -xf - -C "$DATADIR/geth" \
    || die "download/extract failed"
  sudo touch "$DATADIR/.complete"
fi

HEAD=$(curl -sf "$SNAP/mainnet/geth/$BLOCK/_snapshot_eth_getBlockByNumber.json")
HEAD_TS=$(( $(jq -r '.result.timestamp' <<<"$HEAD") ))
AMS_TS=$((HEAD_TS + 3))
GENESIS=$WORK/genesis.json
# Only forks not yet active at the head may move: moving an active one makes geth rewind.
curl -sf https://raw.githubusercontent.com/eth-clients/mainnet/refs/heads/main/metadata/genesis.json \
  | jq --argjson h "$HEAD_TS" --argjson a "$AMS_TS" '
      .config |= with_entries(if (.key|test("^(osaka|bpo[0-9]+)Time$")) and (.value > $h) then .value = $h + 1 else . end)
      | .config.amsterdamTime = $a' > "$GENESIS"
[ "$(jq -r '[.config | to_entries[] | select(.key|test("Time$")) | .value] | max' "$GENESIS")" = "$AMS_TS" ] \
  || die "a parent fork is scheduled after amsterdam; this anchor cannot cross it"
[ -f "$WORK/jwtsecret" ] || openssl rand -hex 32 > "$WORK/jwtsecret"
cat > "$WORK/anchor.env" <<EOF
BLOCK=$BLOCK
HEAD_TS=$HEAD_TS
AMS_TS=$AMS_TS
DATADIR=$DATADIR
GENESIS=$GENESIS
EOF
log "anchor mainnet $BLOCK, head ts $HEAD_TS, amsterdam $AMS_TS"
