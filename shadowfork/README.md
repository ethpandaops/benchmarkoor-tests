# Shadowfork benchmark images

Post-Gloas mainnet datadirs for every EL, ready for a mainnet shadowfork (msf-2) to boot and
benchmark without a prefill of its own. Published to `ethpandaops-shadowfork-images`, read at
`https://shadowfork-images.ethpandaops.io/mainnet/<client>/<block>/snapshot.tar.zst` with the
usual `_snapshot_eth_getBlockByNumber.json` / `_snapshot_metadata.json` / `latest` layout, so
ethereum-package's `network_sync_base_url` works unchanged.

An image is a fresh `snapshots.ethpandaops.io` mainnet snapshot advanced by one pre-run that:

1. funds the 25,000-account pool and buildoor's wallet, and deploys the EIP-8282 contracts in two
   **Osaka** blocks (a strict client rejects every Amsterdam block without them);
2. crosses **Amsterdam** 3 s after the snapshot head, then ramps the gas limit to 2 G;
3. deploys `test_account_access`'s receivers at **24 KiB and 64 KiB**: SAME_MAX, DIFF_MAX and
   JUMPDEST at both sizes, MINIMAL once, plus the 7702 delegations, in one test
   (`test_deploy_existing_contracts_all_sizes`). 100k per variant covers benchmarks up to ~300 Mgas,
   1 Ggas needs ~321k;
4. walks the gas limit back down to the target (200 M) with empty blocks.

geth fills; every other client **replays** the recorded bundle, so all images are one chain with one
head hash, and a client is only published if its digest (hash, stateRoot, gasUsed, BAL hash at ~200
heights) is identical to geth's.

## A clean image: nothing recent may be faster to read than old mainnet state

Benchmarks against a prefilled snapshot found the contracts deployed after the snapshot in higher
DB tiers, and for some clients still warm in the journal, so they read faster than real mainnet
state would. Each client is cleaned before it is packed:

| client | journal / hot layer | compaction |
|---|---|---|
| geth | path scheme keeps 128 diff layers plus an unflushed write buffer (up to 256 MiB) and writes both to `triedb/merkle.journal` on a clean stop, which the next start reads back into memory. The 2026-10-08 image journaled **1,354** blocks: the last ~1,200 fill blocks never reached pebble. The ramp-down runs with `--cache.gc=0` (a 0-byte buffer), so every block that leaves the diff layers is flushed, and `finalize.sh` fails unless the journal holds exactly the last 128 (empty) blocks | `geth db compact` |
| erigon | `seg retire` | `erigon db compact` |
| nethermind, besu | none | RocksDB `ldb compact` per column family, offline (neither ships a compaction command) |
| reth | none: MDBX, persisted every block | none needed |

The geth mechanism was verified on a dev chain (v1.17.7): 176 blocks of state journaled as
`layers=176`; restarted with `--cache.gc=0` (`buffer=0.00B`), ~150 later blocks left `layers=128`.

## Running it

`shadowfork-image-build` (workflow_dispatch) does the geth half on a `synctest` `Disk4TB` runner:
snapshot, pre-run, ramp-down + flush + compaction, reference digest, then uploads
`mainnet/geth/<head>/` and `bundles/mainnet-<head>/bundle.tar.zst` (payloads, genesis, anchor,
`digest-geth.txt`, head block). It never writes `latest`.

The other clients are replayed separately, one machine each, from that bundle: download the
client's `snapshots.ethpandaops.io/mainnet/<client>/<anchor>` snapshot, replay every payload
(each must be VALID), check that it reopens at the bundle's head, clean it as above, compare its
digest against `digest-geth.txt`, then pack and upload. Once all five are up and verified, write
each client's `_snapshot_metadata.json` and head block, and `latest` last.

Requirements learned the hard way:
- Open each datadir with the **release** that wrote the snapshot and that the devnets run, not a
  devnet build: the glamsterdam-devnet-8 images trailed by a major version (nethermind 1.40 vs 2.1).
- The fill must not hold its fixture in memory: each 64 KiB deploy's code is also in its block
  access list, so the bundle is ~55 GB and an in-memory fixture passed 200 GiB. The default EEST
  ref carries skylenet's spill-to-disk fixes.
- Every long step is its own process: no host may auto-upgrade or restart services mid-build
  (unattended-upgrades restarted a unit and killed a 1 TB upload with it).

## Files

| file | does |
|---|---|
| `prepare.sh` | download the geth snapshot (parallel ranged GETs), genesis with Amsterdam at head + 3 s |
| `prerun-config.sh` | the `benchmarkoor build` pre-run config (predeploy block lifted from the devnet-8 prefill) |
| `inplace-schelk` | schelk's CLI over a bind-mounted directory, so the pre-run advances the datadir in place |
| `rampdown.py` | empty blocks down to the gas target, appended to the bundle |
| `finalize.sh` | ramp-down with a 0-byte buffer, journal check, compaction, reopen, reference digest |
| `publish.sh`, `blockhash.py`, `verify.sh` | stream to the bucket hashing every GiB; re-read random GiBs |
