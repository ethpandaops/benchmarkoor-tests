#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLIENTS=(geth erigon nethermind besu reth)

SNAPSHOTS=(
  "mainnet/24350000"
  "perf-devnet-3/24358000"
)

FORKS=(amsterdam osaka)
# bloating context commented out for now, may be re-added later
CONTEXTS=(repricing bal)
REPRICING_TEST_TYPES=(stateful compute)
# BLOATING_TEST_TYPES=(stateful)
BAL_TEST_TYPES=(stateful)

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

    for fork in "${FORKS[@]}"; do
      fork_display="$(tr '[:lower:]' '[:upper:]' <<< "${fork:0:1}")${fork:1}"

      for context in "${CONTEXTS[@]}"; do
        # bal context only runs on perf-devnet-3/24358000 + amsterdam
        if [[ "$context" == "bal" ]]; then
          if [[ "$snapshot" != "perf-devnet-3/24358000" || "$fork" != "amsterdam" ]]; then
            continue
          fi
        fi

        # Resolve test types for this context
        test_types_var="${context^^}_TEST_TYPES[@]"
        test_types=("${!test_types_var}")

        for test_type in "${test_types[@]}"; do
          test_type_display="$(tr '[:lower:]' '[:upper:]' <<< "${test_type:0:1}")${test_type:1}"
          context_display="$(tr '[:lower:]' '[:upper:]' <<< "${context:0:1}")${context:1}"

          # 36h timeout for stateful runs,
          # 12h timeout for erigon/reth compute tests, 6h for everything else
          timeout="360"
          if [[ "$test_type" == "stateful" ]]; then
            timeout="2160"
          elif [[ "$test_type" == "compute" && ("$client" == "erigon" || "$client" == "reth") ]]; then
            timeout="900"
          fi

          instance_ids=("")
          if [[ "$fork" == "amsterdam" ]]; then
            instance_ids=("${client}-bal-full" "${client}-bal-nobatchio" "${client}-bal-sequential")
          fi

          for instance_id in "${instance_ids[@]}"; do
            id_suffix=""
            name_suffix=""
            instance_label=""
            instance_input=""
            if [[ -n "$instance_id" ]]; then
              id_suffix="-${instance_id}"
              name_suffix=" - ${instance_id}"
              instance_label="
    instance-id: \"${instance_id}\""
              instance_input="
    instance-id: \"${instance_id}\""
            fi

            entries+=("- id: benchmarkoor-${client}-${slug}-${fork}-${test_type}-${context}${id_suffix}
  name: \"Benchmarkoor (${client_display}) - ${network_display}(${block}) - ${fork_display} - ${test_type_display} - ${context_display}${name_suffix}\"
  owner: ethpandaops
  repo: benchmarkoor-tests
  workflow_id: benchmarkoor.yaml
  ref: master
  labels:
    el-client: \"${client}\"
    network: \"${network}\"
    block: \"${block}\"
    fork: \"${fork}\"
    test-type: \"${test_type}\"
    context: \"${context}\"${instance_label}
  inputs:
    run-timeout-minutes: \"${timeout}\"
    clients: '[\"${client}\"]'
    snapshot: \"${snapshot}\"
    fork: \"${fork}\"
    test-type: \"${test_type}\"
    context: \"${context}\"${instance_input}")
          done
        done
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
