# benchmarkoor-tests

Configuration and orchestration repository for Ethereum execution client benchmarking. It defines test scenarios, client configurations, network snapshots, and contexts to systematically benchmark different EL client implementations under various conditions.

This repository coordinates with the [benchmarkoor](https://github.com/ethpandaops/benchmarkoor) runner to execute performance tests.

## Supported Clients

- Geth
- Erigon
- Nethermind
- Besu
- Reth

## Configuration

All test configurations live under `configs/`. The directory structure follows this hierarchy:

```
configs/
├── global.yaml                            # Global runner settings (log level, cleanup, etc.)
├── resource-limits-eip-7870-fullnode.yaml  # Hardware constraints (CPU, memory, frequency)
├── s3-upload.yaml                         # S3 results upload configuration
├── s3-indexing.yaml                       # Results indexing configuration
├── contexts/
│   └── <context>/<snapshot>/<fork>/
│       ├── clients.yaml                   # Client images and extra args
│       ├── genesis.yaml                   # Custom genesis config
│       ├── test-source.stateful.yaml      # Stateful test definition
│       └── test-source.compute.yaml       # Compute test definition (where applicable)
└── datadirs/
    └── <snapshot>/
        └── datadir.yaml                   # ZFS snapshot references per client
```

### Context

A **context** defines the scenario being tested. Each context may support different test types.

| Context | Description | Test Types |
|---------|-------------|------------|
| `repricing` | Gas price repricing changes (EIP-7870) | stateful, compute |
| `bloating` | State bloat scenarios | stateful |

### Snapshot

A **snapshot** identifies a specific network state to benchmark against, defined as `<network>/<block>`.

| Snapshot | Description |
|----------|-------------|
| `mainnet/24350000` | Mainnet at block 24,350,000 |
| `perf-devnet-3/24358000` | Performance devnet 3 at block 24,358,000 |

Snapshots are backed by ZFS, allowing fast client datadir setup via cloning.

### Fork

A **fork** specifies which Ethereum hard fork rules to apply during the test.

| Fork | Description |
|------|-------------|
| `amsterdam` | Amsterdam hard fork rules |
| `osaka` | Osaka hard fork rules |

### Test Types

| Type | Description |
|------|-------------|
| `stateful` | Full state-transition tests using podman + CRIU checkpoint/restore |
| `compute` | Stateless computation benchmarks |

## Workflow

The GitHub Actions workflow (`.github/workflows/benchmarkoor.yaml`) accepts inputs for client, snapshot, context, fork, and test type, then:

1. Constructs URLs to the relevant YAML configs from this repo
2. Merges them in order: global → resource-limits → s3 → datadir → genesis → test-source → clients
3. Runs the benchmarkoor action for each client in the matrix
4. Uploads results to S3

## Dispatchoor

The `dispatchoor/` directory contains generated job definitions used by the [dispatchoor](https://github.com/ethpandaops/dispatchoor) to trigger benchmark runs.

`dispatchoor/generate.sh` produces one YAML file per client (`benchmarkoor.<client>.yaml`) covering all combinations of snapshots, forks, contexts, and test types. Run it via:

```bash
make generate
```

### Timeouts

| Scenario | Timeout |
|----------|---------|
| Stateful on perf-devnet-3 | 26h |
| Stateful on mainnet | 13h |
| Compute on erigon/reth | 15h |
| Everything else | 6h |
