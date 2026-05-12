#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTEXTS_DIR="${REPO_ROOT}/configs/contexts"

CLIENTS=(geth erigon nethermind besu reth ethrex)

cap() {
  local s="$1"
  printf '%s%s' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')" "${s:1}"
}

# Timeout in minutes for a (client, context, test_type) combo.
get_timeout() {
  local client="$1" context="$2" test_type="$3"
  if [[ "$test_type" == "stateful" ]]; then
    if [[ "$client" == "erigon" && "$context" == "repricing" ]]; then
      echo "4500"
    else
      echo "2160"
    fi
  elif [[ "$test_type" == "compute" && ( "$client" == "erigon" || "$client" == "reth" ) ]]; then
    echo "900"
  else
    echo "360"
  fi
}

# Print instance ids from clients.yaml that belong to the given client.
# A match is an id equal to the client name or starting with `<client>-`.
# If the only match is the bare client name, prints a single empty line
# (signal: emit one entry without an instance-id).
get_instance_ids() {
  local clients_yaml="$1" client="$2"
  [[ -f "$clients_yaml" ]] || return 0

  local ids=() id
  while IFS= read -r id; do
    if [[ "$id" == "$client" || "$id" == "${client}-"* ]]; then
      ids+=("$id")
    fi
  done < <(sed -nE 's/^[[:space:]]+-[[:space:]]*id:[[:space:]]*([^[:space:]]+).*/\1/p' "$clients_yaml")

  if [[ ${#ids[@]} -eq 0 ]]; then
    return 0
  elif [[ ${#ids[@]} -eq 1 && "${ids[0]}" == "$client" ]]; then
    echo ""
  else
    printf '%s\n' "${ids[@]}"
  fi
}

for client in "${CLIENTS[@]}"; do
  outfile="${SCRIPT_DIR}/benchmarkoor.${client}.yaml"
  client_display="$(cap "$client")"

  entries=()
  prev_subdir_key=""

  while IFS= read -r subdir_path; do
    [[ -e "${subdir_path}/.dispatchoor_ignore" ]] && continue

    rel="${subdir_path#${CONTEXTS_DIR}/}"
    IFS='/' read -r context network block subdir <<< "$rel"

    snapshot="${network}/${block}"
    slug="${network}-${block}"
    network_display="$(cap "$network")"
    subdir_display="$(cap "$subdir")"
    context_display="$(cap "$context")"

    # Discover test types from test-source.*.yaml in this subdir.
    test_types=()
    for ts in "${subdir_path}"/test-source.*.yaml; do
      [[ -e "$ts" ]] || continue
      tt="${ts##*/test-source.}"
      tt="${tt%.yaml}"
      test_types+=("$tt")
    done
    [[ ${#test_types[@]} -gt 0 ]] || continue

    # Discover instance ids for this client from clients.yaml.
    instance_ids=()
    while IFS= read -r id; do
      instance_ids+=("$id")
    done < <(get_instance_ids "${subdir_path}/clients.yaml" "$client")
    [[ ${#instance_ids[@]} -gt 0 ]] || continue

    subdir_key="${context}/${snapshot}/${subdir}"
    if [[ "$subdir_key" != "$prev_subdir_key" ]]; then
      entries+=("# === Context: ${context_display} ===
# --- Subdir: ${subdir} (${snapshot}) ---")
      prev_subdir_key="$subdir_key"
    fi

    for test_type in "${test_types[@]}"; do
      test_type_display="$(cap "$test_type")"
      timeout="$(get_timeout "$client" "$context" "$test_type")"

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

        entries+=("- id: benchmarkoor-${client}-${context}-${slug}-${subdir}-${test_type}${id_suffix}
  name: \"(${client_display}) - ${context_display} - ${network_display}(${block}) - ${subdir_display} - ${test_type_display}${name_suffix}\"
  owner: ethpandaops
  repo: benchmarkoor-tests
  workflow_id: benchmarkoor.yaml
  ref: master
  labels:
    el-client: \"${client}\"
    network: \"${network}\"
    block: \"${block}\"
    subdir: \"${subdir}\"
    test-type: \"${test_type}\"
    context: \"${context}\"${instance_label}
  inputs:
    run-timeout-minutes: \"${timeout}\"
    clients: '[\"${client}\"]'
    snapshot: \"${snapshot}\"
    subdir: \"${subdir}\"
    test-type: \"${test_type}\"
    context: \"${context}\"${instance_input}")
      done
    done
  done < <(find "${CONTEXTS_DIR}" -mindepth 4 -maxdepth 4 -type d | sort)

  {
    echo "# AUTO-GENERATED FILE - DO NOT EDIT MANUALLY"
    echo "# Regenerate with: make config (or ./dispatchoor/generate.sh)"
    echo "# Source: configs/contexts/<context>/<network>/<block>/<subdir>/"
    for entry in "${entries[@]}"; do
      echo ""
      echo "$entry"
    done
  } > "${outfile}"
  echo "Generated ${outfile} (${#entries[@]} entries)"
done
