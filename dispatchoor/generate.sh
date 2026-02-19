#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLIENTS=(geth erigon nethermind besu reth)

SNAPSHOTS=(
  "mainnet/24350000"
  "perf-devnet-2/23861500"
)

TEST_TYPES=(stateful compute)

for client in "${CLIENTS[@]}"; do
  outfile="${SCRIPT_DIR}/benchmarkoor.${client}.yaml"
  # Capitalise first letter for display name
  client_display="$(tr '[:lower:]' '[:upper:]' <<< "${client:0:1}")${client:1}"

  entries=()
  for snapshot in "${SNAPSHOTS[@]}"; do
    network="${snapshot%%/*}"
    block="${snapshot##*/}"
    slug="${network}-${block}"
    network_display="$(tr '[:lower:]' '[:upper:]' <<< "${network:0:1}")${network:1}"

    for test_type in "${TEST_TYPES[@]}"; do
      test_type_display="$(tr '[:lower:]' '[:upper:]' <<< "${test_type:0:1}")${test_type:1}"

      # 12h timeout for erigon/reth compute tests, 6h for everything else
      timeout="360"
      if [[ "$test_type" == "compute" && ("$client" == "erigon" || "$client" == "reth") ]]; then
        timeout="720"
      fi

      entries+=("- id: benchmarkoor-${client}-${slug}-${test_type}
  name: \"Benchmarkoor (${client_display}) - ${network_display}(${block}) - ${test_type_display}\"
  owner: ethpandaops
  repo: benchmarkoor-tests
  workflow_id: benchmarkoor.yaml
  ref: master
  labels:
    el-client: \"${client}\"
    network: \"${network}\"
    block: \"${block}\"
    test-type: \"${test_type}\"
  inputs:
    run-timeout-minutes: \"${timeout}\"
    clients: '[\"${client}\"]'
    snapshot: \"${snapshot}\"
    test-type: \"${test_type}\"
    upload-artifacts: \"false\"")
    done
  done

  first=true
  for entry in "${entries[@]}"; do
    if $first; then
      first=false
    else
      echo ""
    fi
    echo "$entry"
  done > "${outfile}"
  echo "Generated ${outfile}"
done
