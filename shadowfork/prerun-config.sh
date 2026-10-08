#!/bin/bash
# Print the `benchmarkoor build` config for the geth pre-run (stdout).
#   RECEIVERS=100000 EEST_REPO=... EEST_REF=... shadowfork/prerun-config.sh
# The datadir advances in place (datadir_method schelk + shadowfork/inplace-schelk): a copy
# of a 1.4 TiB mainnet datadir is time and disk for nothing, since the snapshot is re-downloadable.
source "$(dirname "$0")/lib.sh"
source "$WORK/anchor.env"
: "${RECEIVERS:?}" "${EEST_REPO:?}" "${EEST_REF:?}"
GAS_BUMP=${GAS_BUMP:-2000000000}   # 2x the 1 Ggas benchmark block the fill packs to
# One test: under --no-reset-between-tests a second test in the same fill does not re-read the head.
TEST=${TEST:-'tests/benchmark/stateful/bloatnet/test_setup_contracts.py::test_deploy_existing_contracts_all_sizes[fork_Amsterdam-blockchain_test_stateful_engine-benchmark-gas-value_1000M]'}
# The EIP-8282 predeploy calldata is lifted verbatim from the CI prefill: a single changed byte of
# CREATE2 initcode lands the contract at another address.
PREDEPLOY=$(awk '/^      predeploy:/,/^    targets:/' \
  "$SF_DIR/../configs/contexts/repricing/jochemnet/v1/glamsterdam-devnet-8/test-source.stateful.builder.yaml" \
  | grep -v '^    targets:')
[ -n "$PREDEPLOY" ] || die "no predeploy block in the devnet-8 prefill config"
cat <<YML
global:
  log_level: info
builder:
  pre_runs:
    pull_policy: always
    eest_repo: $EEST_REPO
    eest_ref: $EEST_REF
    config:
      fork: amsterdam
      rpc_seed_key: "0x0000000000000000000000000000000000000000000000000000000000000001"
      datadir_method: schelk
      gas_limit: $GAS_BUMP
      funding_accounts:
        - address: 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
        # buildoor's wallet: a shadowfork's alloc is frozen, so nothing else funds it
        - address: 0x8943545177806ED17B9F23F0a21ee5948eCaa776
      funding_pools:
        - base_key_seed: gas-repricings-private-key
          count: 25000
      gas_benchmark_values: [1000]
      fill_env:
        BLOATNET_RECEIVER_CONTRACT_COUNT: "$RECEIVERS"
      tests:
        - "$TEST"
$PREDEPLOY
    targets:
      - name: pre-run-geth
        filler_client: geth
        filler_image: $GETH_IMAGE
        source_dir: $DATADIR
        bundle_dir: $WORK/bundle
        genesis: $GENESIS
        genesis_fork_override:
          amsterdam: $AMS_TS
        filler_extra_args:
          - --override.amsterdam=$AMS_TS
          - --rpc.batch-request-limit=16384
          # one testing_buildBlock body carries a whole block of 7702 delegations (~9 MB)
          - --rpc.http-body-limit=1024
YML
