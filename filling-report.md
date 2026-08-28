# Filling report — jochemnet glamsterdam-devnet-8, stateful

Results of the EEST payload fill for `geth` on the jochemnet
glamsterdam-devnet-8 stateful context, 2026-08-27.

| | |
| --- | --- |
| Context | `repricing` / `jochemnet/v1/glamsterdam-devnet-8`, test type `stateful` |
| Client | `ethpandaops/geth:glamsterdam-devnet-8` |
| EEST source | `skylenet/execution-specs` @ `fix/no-reset-reanchor-start-block` |
| Gas values | 200M, 300M (payload stage), 1000M (pre-run) |
| Runs | [33113319262](https://github.com/ethpandaops/benchmarkoor-tests/actions/runs/33113319262) (ci-3, unfiltered) · [33113387249](https://github.com/ethpandaops/benchmarkoor-tests/actions/runs/33113387249) (ci-18, filtered) |

## Headline

The **pre-run stage passed for the first time**, on both hosts. Both
`code_size` variants of `test_deploy_existing_contracts` filled, where
previous attempts were killed by the kernel at 46 GiB. No OOM occurred on
either host.

The **payload stage now runs**, and this report covers what it produced.

```
pre_runs        2 passed in 7689.80s (2:08:10)
eest_payloads   424 failed, 336 passed, 4 skipped in 9302.29s (2:35:02)
```

Numbers below come from the unfiltered run (ci-3, 764 collected). The
filtered run on ci-18 is summarised at the end.

## Totals

| Outcome | Count |
| --- | ---: |
| Filled | 336 |
| Failed | 424 |
| Skipped | 4 |
| **Collected** | **764** |

## Failures by cause

Every one of the 424 failures is accounted for. One category — the gas
mismatch — only became visible after pulling the complete log; the
truncated view had hidden it.

| Count | Cause |
| ---: | --- |
| **360** | `JSONRPCError -32000: nonce too low` |
| 39 | `RuntimeError: Depth benchmark requires more mined contracts than available` |
| 13 | `HTTPError: 413 Client Error: Request Entity Too Large` |
| 4 | `AssertionError: initcode prefix too long` |
| 4 | `BlockAccessListValidationError: storage read not found or not in correct order` |
| 3 | `AssertionError: Total gas used does not match expected benchmark gas` |
| 1 | no error line in its failure block |

### 1. `nonce too low` — 360 failures (85%) — root cause found

```
JSONRPCError(code=-32000, message=nonce too low:
  address 0x34531c4fC59c3198d7D62d303834833…, tx: 0 state: 3)
```

**The payload stage hands out EOAs whose private key is a small integer,
and assumes each one has never sent a transaction. On a fork of a live
chain, many of those accounts already have history.**

The mechanism, in three steps:

1. The payload fill runs with `--eoa-start=1000`.
2. `pre_alloc.py:140` turns that into accounts whose **private key is the
   index itself**, with the nonce hardcoded:
   ```python
   return iter(EOA(key=i, nonce=0) for i in count(start=eoa_start))
   ```
3. Keys 1000, 1001, 1002 … are trivially guessable, so on the jochemnet
   fork many of them have already been used. The filler still sends
   nonce 0, and the client rejects it.

Nothing on this path ever reads the account's real nonce. The only
nonce-sync in the codebase covers the session seed key (`worker_key`) and
the refund path in the `execute` plugin — not per-test EOA allocation.

**Evidence.** Deriving addresses from key indices and matching them
against the failures:

| Check | Result |
| --- | --- |
| Failing addresses matched to key indices | **360 of 360** |
| Index range | **1013 – 2027** (exactly the `--eoa-start=1000` range) |
| Transaction nonce used | `0` in all 720 error lines |
| On-chain nonce found | 2 – 1763 (median 32) |
| Indices in that range that did *not* fail | 655 — keys with no history |

The natural experiment confirms it. Two tests, two different sender
sources:

| Test | Sender source | Result |
| --- | --- | ---: |
| `test_transaction_types.py` | `yield_distinct_sender()` → `EOA(key=SENDER_BASE_KEY + i)`, keccak-derived, far from any used range | 72 filled, **0 failed** |
| `test_account_query.py` | `pre.fund_eoa()` → the low-integer range | 247 failed |

The all-passing test never calls `fund_eoa` once. That is why it is
immune.

This also explains two things that looked odd. The failures correlate
with **no** test parameter — not opcode, account mode, code size, value
sent, overhead baseline, or gas value — because what decides success is
simply which key index the allocator happens to hand out. And the failure
rate by position **oscillates** (94%, 58%, 17%, 59%, 66%, 16%, 71%, 68%,
5% across deciles) rather than climbing, because it tracks which test is
consuming indices, not elapsed time.

The pre-run stage does not hit this: it runs with
`--eoa-start=1000000000`, far above the used range.

Note this is **not** related to `--no-reset-between-tests`. That flag is
set only on the pre-run. The payload stage rewinds between tests, and the
rewind works correctly — 704 rewinds, every one targeting block
24,443,820 and verified against the expected hash.

### 2. Not enough mined contracts — 39 failures

```
RuntimeError: Depth benchmark requires more mined contracts than
available for (storage_depth=12, account_depth=5):
required 53973, available 18000.
```

A data shortfall, not a defect. Requirements run from 19,421 to 53,973
contracts; the pre-run deployed 18,000. Affects the depth benchmarks
only.

### 3. `413 Request Entity Too Large` — 13 failures — fixed

All 13 are `test_worst_depth_stateroot_recomp`. `build_block` POSTs a
whole block's transactions to the eth RPC port as
`testing_buildBlockV1`, and the deep-branch benchmarks exceed geth's
default 5 MB HTTP body limit:

```
rpc.py:1772  self.post_request(…)
E   requests.exceptions.HTTPError: 413 Client Error: Request Entity
    Too Large for url: http://172.20.0.2:8545/
```

geth exposes the limit, so this is a configuration fix:

```
--rpc.http-body-limit value  (default: 5)
    Maximum size (in megabytes) of an HTTP request body
```

`--rpc.http-body-limit=128` is now set on the `eest_payloads` geth
target, alongside the `--rpc.batch-request-limit=16384` already there.

Note the depth benchmarks fail two different ways: the deeper variants
never get this far, stopping at the contract shortfall above, while the
shallower ones clear that and then blow the body limit.

### 4. `initcode prefix too long` — 4 failures

Assertion inside `test_sload_bloated_multi_contract`.

### 5. Block access list mismatch — 4 failures

All 4 are `test_sload_bloated_prefetch_miss`:

```
blockchain.py:1233  block.expected_block_access_list.verify_against(t8n_bal)
expectations.py:297 raise BlockAccessListValidationError(
E   Storage read 0x0000…f3cf193bb4af1022af7d2089f37d8bae7157b85f
    not found or not in correct order. Actual reads: […]
```

The test declares expected EIP-7928 storage reads; geth's actual block
access list does not contain that read, or not in that order. The test
is a *prefetch miss* — it deliberately reads slots that do not exist —
so the open question is whether a read of an empty slot belongs in the
BAL at all.

This is a client-versus-test disagreement about EIP-7928 semantics
rather than a harness problem, and is worth raising with the EEST and
geth sides rather than configuring around.

### 6. Gas mismatch — 3 failures

```
AssertionError: Total gas used (85343842) does not match expected
benchmark gas (299998976), difference: -214655134
```

All three in `test_sstore_variants`. The shortfalls are large — the
observed gas is a fraction of the expected budget in two of the three.

## Failures by test

| Test | Cause | Count |
| --- | --- | ---: |
| `test_account_access` | nonce too low | 247 |
| `test_ext_account_query_warm` | nonce too low | 35 |
| `test_worst_depth_get_deepest` | not enough mined contracts | 26 |
| `test_sstore_variants` | nonce too low | 21 |
| `test_sstore_dirty_transitions` | nonce too low | 16 |
| `test_worst_depth_stateroot_recomp` | 413 request too large | 13 |
| `test_worst_depth_stateroot_recomp` | not enough mined contracts | 13 |
| `test_create2_immediate_access` | nonce too low | 12 |
| `test_sload_benchmark` | nonce too low | 7 |
| `test_sstore_bloated` | nonce too low | 5 |
| `test_sload_bloated_multi_contract` | initcode prefix too long | 4 |
| `test_sload_bloated_prefetch_miss` | nonce too low | 4 |
| `test_sload_bloated_prefetch_miss` | block access list mismatch | 4 |
| `test_tstore_unique_keys` | nonce too low | 4 |
| `test_deploy_existing_contracts` | nonce too low | 3 |
| `test_sload_bloated` | nonce too low | 3 |
| `test_sload_bloated_multi_contract` | nonce too low | 3 |
| `test_sstore_variants` | gas mismatch | 3 |
| `test_deploy_existing_contracts` | no error line | 1 |

## Tests that filled

336 payload fixtures filled, plus the 2 pre-run fixtures.

| Test | File | Filled |
| --- | --- | ---: |
| `test_account_access` | `test_account_query.py` | 153 |
| `test_ext_account_query_warm` | `test_account_query.py` | 77 |
| `test_ether_transfers_onchain_receivers` | `test_transaction_types.py` | 72 |
| `test_sstore_variants` | `test_sstore.py` | 8 |
| `test_create2_immediate_access` | `test_create.py` | 6 |
| `test_sload_same_key_benchmark` | `test_sload.py` | 4 |
| `test_sstore_dirty_transitions` | `test_sstore.py` | 4 |
| `test_tstore_same_key` | `test_transient_storage.py` | 4 |
| `test_sstore_bloated` | `test_sstore.py` | 3 |
| `test_call_value_to_empty` | `test_call.py` | 2 |
| `test_deploy_existing_contracts` | `test_setup_contracts.py` | 2 (pre-run) |
| `test_sload_benchmark` | `test_sload.py` | 1 |
| `test_sload_bloated` | `test_sload.py` | 1 |
| `test_sload_bloated_multi_contract` | `test_sload.py` | 1 |

`test_ether_transfers_onchain_receivers` is the only test that filled
every one of its variants — 72 filled, 0 failed.

## Second run (ci-18, filtered)

The paired run applied an `eest_payloads` filter selecting
`test_account_access` on the two max-size contract receivers, plus
`test_ether_transfers_onchain_receivers` on three `diff_to_*` cases.

```
pre_runs        2 passed in 8863.41s (2:27:43)
eest_payloads   142 failed, 42 passed, 580 deselected in 3022.12s (0:50:22)
```

Every failure in that run was `nonce too low`, all on
`test_account_access` — consistent with the unfiltered run.

## Suggested next steps

1. **Fix the EOA collision** — 85% of all failures. Two options, not
   exclusive:
   - *Config, immediate:* raise `--eoa-start` for the payload stage out
     of the used range, as the pre-run already does. Pick a value above
     the pre-run's own `1000000000` so the two stages cannot overlap.
     benchmarkoor sets this flag; it is not exposed in the
     `benchmarkoor-tests` config today.
   - *Upstream, robust:* stop assuming `nonce=0` at `pre_alloc.py:140`.
     Read the account's nonce when allocating, or skip indices whose
     account is non-empty. Any fixed starting index is a guess about
     what the chain has not used yet; on a fork of a live chain that
     guess will eventually be wrong again.
2. **Raise the deployed contract count** if the depth benchmarks are
   wanted — they need up to 53,973 against 18,000 available.
3. ~~Raise geth's JSON-RPC body limit~~ — done,
   `--rpc.http-body-limit=128` on the `eest_payloads` geth target.
4. **Raise the block access list mismatch** with the EEST and geth
   sides. Whether a read of a non-existent storage slot belongs in an
   EIP-7928 BAL is a spec question, not something to configure around.
5. Treat the `initcode prefix too long` and gas-mismatch assertions as
   separate, small test-level issues.

## Corrections

An earlier revision of this report gave 17 `413` failures and no block
access list failures, and attributed four 413s to
`test_sload_bloated_prefetch_miss`. That was wrong. The
`BlockAccessListValidationError` lines are width-truncated in the job log
(`…exceptions.BlockAccessListValidat`), so a regex keyed on the class
name ending in `Error` skipped them, and those failures were absorbed
into the neighbouring block's cause. The counts above come from
classifying each failure block by its full text instead.

## Notes on method

Counts come from the complete job log downloaded via
`gh api repos/{owner}/{repo}/actions/runs/{id}/logs`, not
`gh run view --log`. The latter truncates: it dropped the final tally,
57 failure blocks, and an entire error category.
