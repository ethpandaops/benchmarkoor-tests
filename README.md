# benchmarkoor-tests

Configuration and orchestration repository for Ethereum execution client benchmarking. It defines test scenarios, client configurations, network snapshots, and contexts to systematically benchmark different EL client implementations under various conditions.

This repository coordinates with the [benchmarkoor](https://github.com/ethpandaops/benchmarkoor) runner to execute performance tests.

## Supported Clients

- Geth
- Erigon
- Nethermind
- Besu
- Reth
- Ethrex
- Nimbus

## Configuration

All test configurations live under `configs/`. The directory structure follows this hierarchy:

```yaml
configs/
├── global.yaml                            # Global runner settings (log level, cleanup, etc.)
├── resource-limits-eip-7870-fullnode.yaml # Hardware constraints for fullnode tests
├── resource-limits-eip-7870-attester.yaml # Hardware constraints for attester tests
├── s3-upload.yaml                         # S3 results upload configuration
├── s3-indexing.yaml                       # Results indexing configuration
├── contexts/
│   └── <context>/<network>/<block>/<subdir>/
│       ├── clients.yaml                   # Client images, instance ids, and extra args
│       ├── genesis.yaml                   # Custom genesis config (defines the active fork)
│       ├── test-source.<test-type>.yaml   # One file per supported test type
│       └── .dispatchoor_ignore            # (optional) skip this subdir during dispatch generation
└── datadirs/
    └── <network>/<block>/
        └── datadir.yaml                   # ZFS snapshot references per client
```

A test run is fully identified by the tuple `(context, snapshot, subdir, test-type, client, instance-id)`. The workflow assembles the configs by fetching the files under that tuple's directory.

### Context

A **context** defines the scenario being tested. Each context can host any set of snapshots and subdirs; what exists on disk is what is runnable.

| Context | Description |
|---------|-------------|
| `repricing` | Gas price repricing changes (EIP-7870) |
| `bal` | Block-level access list scenarios |
| `bloating` | State bloating scenarios |

### Snapshot

A **snapshot** identifies a specific network state to benchmark against, defined as `<network>/<block>`. Each snapshot must have a matching `configs/datadirs/<network>/<block>/datadir.yaml`.

| Snapshot | Description |
|----------|-------------|
| `mainnet/24350000` | Mainnet at block 24,350,000 |
| `perf-devnet-3/24358000` | Performance devnet 3 at block 24,358,000 |
| `jochemnet/24402727` | Jochemnet at block 24,402,727 |

Snapshots are backed by ZFS, allowing fast client datadir setup via cloning.

### Subdirectory

A **subdir** is the leaf directory under `contexts/<context>/<network>/<block>/`. It groups a `genesis.yaml`, `clients.yaml`, and one or more `test-source.<test-type>.yaml` files together. The subdir name is free-form — it typically reflects the fork rules and/or devnet variant baked into the genesis.

Examples currently in the repo: `osaka`, `amsterdam-devnet-3`, `amsterdam-devnet-6`.

### Test Types

Test types are discovered per subdir from the `test-source.<test-type>.yaml` files present.

| Type | Description |
|------|-------------|
| `stateful` | Full state-transition tests using podman + CRIU checkpoint/restore |
| `compute` | Stateless computation benchmarks |

## Workflow

The GitHub Actions workflow (`.github/workflows/benchmarkoor.yaml`) accepts inputs for `clients`, `snapshot`, `context`, `subdir`, `test-type`, and `instance-id`, then:

1. Constructs URLs to the relevant YAML configs from this repo
2. Merges them in order: global → resource-limits → s3 → datadir → genesis → test-source → clients
3. Runs the benchmarkoor action for each client in the matrix
4. Uploads results to S3

## Dispatchoor

The `dispatchoor/` directory contains generated job definitions used by the [dispatchoor](https://github.com/ethpandaops/dispatchoor) to trigger benchmark runs.

`dispatchoor/generate.sh` produces one YAML file per client (`benchmarkoor.<client>.yaml`) by walking `configs/contexts/`. For every `<context>/<network>/<block>/<subdir>` it:

- Discovers test types from the `test-source.<test-type>.yaml` files in the subdir.
- Discovers per-client instance ids from `clients.yaml` (matching `<client>` or `<client>-*`); a client with no matching entry is skipped for that subdir.
- Emits one dispatch entry per `(test-type, instance-id)` combination.

To skip a subdir during generation, drop an empty `.dispatchoor_ignore` file inside it.

Run the generator via:

```bash
make config
```
