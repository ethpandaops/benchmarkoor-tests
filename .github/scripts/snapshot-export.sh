#!/usr/bin/env bash
# Export $DATADIR as <bucket>/jochemnet/$CLIENT/<head>/ with its metadata and head block
# (benchmarkoor snapshot export). The head block is geth's, from the snapshot-tail artifact.
# Env: CLIENT DATADIR SNAPSHOT_IMAGE SNAPSHOT_TAIL_DIR SNAPSHOT_GAS_LIMIT AMSTERDAM_TIME RELEASE EEST BASE BUCKET
set -euo pipefail
blk=$SNAPSHOT_TAIL_DIR/head.json
meta=$SNAPSHOT_TAIL_DIR/pre_run_bundle/pre-run.meta.json
head=$(( $(jq -r .result.number "$blk") ))

jq -n --arg img "$SNAPSHOT_IMAGE" --arg release "$RELEASE" --arg eest "$EEST" --argjson base "$BASE" \
  --argjson head "$head" --arg hash "$(jq -r .result.hash "$blk")" --argjson ams "$AMSTERDAM_TIME" \
  --argjson gas "$SNAPSHOT_GAS_LIMIT" --argjson ramp "$(jq .payloads "$meta")" \
  --arg run "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" '{
    docker_image: $img,
    shadowfork: {network: "jochemnet", base: $base, release: $release, eest: $eest,
      head: $head, head_hash: $hash, gas_limit: $gas, ramp_blocks: $ramp, amsterdam_time: $ams,
      filler: "geth", built_by: $run,
      notes: "already on Amsterdam: a devnet must start on Gloas with amsterdamTime = amsterdam_time"}}' \
  > "$RUNNER_TEMP/snapshot/metadata.json"

sudo -E "$RUNNER_TEMP/benchmarkoor" snapshot export --client "$CLIENT" --datadir "$DATADIR" \
  --network jochemnet --block "$head" --bucket "$BUCKET" \
  --head-block-file "$blk" --metadata-file "$RUNNER_TEMP/snapshot/metadata.json"
