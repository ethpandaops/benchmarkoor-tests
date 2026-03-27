#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLIENTS=(geth erigon nethermind besu reth)

SNAPSHOTS=(
  "mainnet/24350000"
  "perf-devnet-2/23861500"
  "perf-devnet-3/24188300"
)

CONTEXTS=(repricing bloating)
REPRICING_TEST_TYPES=(stateful compute)
BLOATING_TEST_TYPES=(stateful)

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

    for context in "${CONTEXTS[@]}"; do
      # Resolve test types for this context
      test_types_var="${context^^}_TEST_TYPES[@]"
      test_types=("${!test_types_var}")

      for test_type in "${test_types[@]}"; do
        test_type_display="$(tr '[:lower:]' '[:upper:]' <<< "${test_type:0:1}")${test_type:1}"
        context_display="$(tr '[:lower:]' '[:upper:]' <<< "${context:0:1}")${context:1}"

        # 26h timeout for perf-devnet-3 stateful runs,
        # 13h timeout for mainnet stateful runs,
        # 12h timeout for erigon/reth compute tests, 6h for everything else
        timeout="360"
        if [[ "$test_type" == "stateful" && "$network" == "perf-devnet-3" ]]; then
          timeout="1560"
        elif [[ "$test_type" == "stateful" && "$network" == "mainnet" ]]; then
          timeout="780"
        elif [[ "$test_type" == "compute" && ("$client" == "erigon" || "$client" == "reth") ]]; then
          timeout="720"
        fi

        entries+=("- id: benchmarkoor-${client}-${slug}-${test_type}-${context}
  name: \"Benchmarkoor (${client_display}) - ${network_display}(${block}) - ${test_type_display} - ${context_display}\"
  owner: ethpandaops
  repo: benchmarkoor-tests
  workflow_id: benchmarkoor.yaml
  ref: master
  labels:
    el-client: \"${client}\"
    network: \"${network}\"
    block: \"${block}\"
    test-type: \"${test_type}\"
    context: \"${context}\"
  inputs:
    run-timeout-minutes: \"${timeout}\"
    clients: '[\"${client}\"]'
    snapshot: \"${snapshot}\"
    test-type: \"${test_type}\"
    upload-artifacts: \"false\"
    context: \"${context}\"")
      done
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
