# shellcheck shell=bash disable=SC2034  # sourced: the settings are used by the scripts that source it
# Shared settings for the shadowfork image build (see shadowfork/README.md).
set -euo pipefail
SF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${SF_WORK:?SF_WORK must point at a directory on the big disk}
SNAP=${SF_SNAPSHOTS:-https://snapshots.ethpandaops.io}
BUCKET=${SF_BUCKET:-ethpandaops-shadowfork-images}
PUBLIC=${SF_PUBLIC:-https://shadowfork-images.ethpandaops.io}
# The image is opened by the release that wrote the snapshot and that the devnets run.
GETH_IMAGE=${GETH_IMAGE:-ethereum/client-go:v1.17.7}
P_RPC=19545 P_ENGINE=19551
mkdir -p "$WORK"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
rpc() { # rpc <method> [params-json]
  curl -sf --max-time 60 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "http://127.0.0.1:$P_RPC"
}
r2() { # rclone against the images bucket with the repo's S3 credentials
  RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_ENDPOINT=${S3_ENDPOINT_URL:?} \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:?} RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:?} \
    rclone "$@"
}
boot_geth() { # boot_geth <extra geth args...>: the image datadir on the fixed ports, no peers
  source "$WORK/anchor.env"
  docker rm -f sf-geth >/dev/null 2>&1 || true
  docker run -d --name sf-geth --network host -v "$DATADIR:/data" -v "$GENESIS:/genesis.json:ro" \
    -v "$WORK/jwtsecret:/jwtsecret:ro" "$GETH_IMAGE" \
    --datadir=/data --override.genesis=/genesis.json --override.amsterdam="$AMS_TS" \
    --http --http.addr=127.0.0.1 --http.port=$P_RPC --http.api=eth,debug,testing \
    --authrpc.addr=127.0.0.1 --authrpc.port=$P_ENGINE --authrpc.jwtsecret=/jwtsecret \
    --syncmode=full --maxpeers=0 --nodiscover "$@" >/dev/null
  for _ in $(seq 120); do rpc eth_blockNumber >/dev/null 2>&1 && return 0; sleep 5; done
  docker logs --tail 20 sf-geth; die "geth did not open its RPC"
}
stop_geth() { # graceful: a killed geth never writes its trie journal and reopens short of its head
  docker stop -t 1800 sf-geth >/dev/null; docker logs sf-geth > "$WORK/geth-$1.log" 2>&1; docker rm sf-geth >/dev/null
}
