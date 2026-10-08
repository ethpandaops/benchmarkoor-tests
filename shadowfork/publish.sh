#!/bin/bash
# Stream the geth image and the replay bundle to the images bucket; no archive on disk.
#   shadowfork/publish.sh
# Writes $WORK/publish-<name>.blocks (sha256 of every GiB of the uploaded stream) for verify.sh.
# Never writes `latest`: that waits until every client's image is up (shadowfork/README.md).
source "$(dirname "$0")/lib.sh"
source "$WORK/anchor.env"
B=$WORK/bundle/pre_run_bundle
END=$(jq .end_block_number "$B/pre-run.meta.json")
up() { # up <name> <dest> : stdin -> zstd -> hashed -> bucket
  zstd -6 -T0 -q | tee >(python3 "$SF_DIR/blockhash.py" > "$WORK/publish-$1.blocks") \
    | r2 rcat --s3-chunk-size 256M --s3-upload-concurrency 8 "r2:$BUCKET/$2"
  sleep 5   # the process substitution may still be flushing
  grep -q total "$WORK/publish-$1.blocks" || die "$1: upload stream incomplete"
}
docker ps --format '{{.Names}}' | grep -qx sf-geth && die "geth is still running"

log "=== geth image -> mainnet/geth/$END ==="
# The geth/ prefix is load-bearing: <datadir>/geth/triedb holds the state geth reopens with.
sudo tar --sort=name -C "$DATADIR" --exclude=geth/nodekey --exclude=geth/LOCK --exclude=geth/nodes \
  --exclude='geth/_snapshot_*' -cf - geth | up geth "mainnet/geth/$END/snapshot.tar.zst"
r2 copyto "$WORK/_snapshot_eth_getBlockByNumber.json" "r2:$BUCKET/mainnet/geth/$END/_snapshot_eth_getBlockByNumber.json"

log "=== bundle -> bundles/mainnet-$END ==="
# Everything a replaying client needs: the payloads, the genesis they were built against, the
# anchor, and geth's digest to compare its own against.
tar --sort=name -C "$WORK" -cf - anchor.env genesis.json digest-geth.txt _snapshot_eth_getBlockByNumber.json \
  bundle/pre_run_bundle/pre-run.request bundle/pre_run_bundle/pre-run.meta.json | up bundle "bundles/mainnet-$END/bundle.tar.zst"
log "published head $END: geth image $(awk '$2=="total"{print $1}' "$WORK/publish-geth.blocks") B, bundle $(awk '$2=="total"{print $1}' "$WORK/publish-bundle.blocks") B"
