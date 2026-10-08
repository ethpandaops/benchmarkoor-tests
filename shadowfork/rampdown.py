#!/usr/bin/env python3
"""Append empty blocks to the image until its gas limit is the target, and record them in the bundle.

The pre-run leaves the head at its 2 G bump target; a devnet that wants 200 M would otherwise
spend ~2,400 blocks walking down 1/1024 per block. The blocks are built the way benchmarkoor
builds its own (testing_buildBlockV1, then engine_newPayloadV5 + engine_forkchoiceUpdatedV3),
with geth started at --miner.gaslimit=<target>, and appended to pre-run.request so every replayed
client reaches the same head. At least MIN_BLOCKS are built even once the target is reached: they
push the fill out of geth's 128 in-memory diff layers.

Usage: rampdown.py <rpc-url> <engine-url> <jwt-file> <bundle-dir> <target-gas-limit>
"""
import base64, hashlib, hmac, json, sys, time, urllib.request

rpc_url, engine_url, jwt_path, bdir, target = sys.argv[1:6]
target = int(target)
MIN_BLOCKS = 256
EXTRA_DATA = "0x62656e63686d61726b6f6f72"   # "benchmarkoor", as on its own blocks
secret = bytes.fromhex(open(jwt_path).read().strip().removeprefix("0x"))

def jwt():
    b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
    h, p = b(b'{"alg":"HS256","typ":"JWT"}'), b(json.dumps({"iat": int(time.time())}).encode())
    return (h + b"." + p + b"." + b(hmac.new(secret, h + b"." + p, hashlib.sha256).digest())).decode()

def call(url, method, params, auth=False):
    hdr = {"Content-Type": "application/json"}
    if auth:
        hdr["Authorization"] = "Bearer " + jwt()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, data=body, headers=hdr), timeout=120))
    if "error" in r:
        sys.exit(f"{method}: {r['error']}")
    return r["result"]

req_path, meta_path = f"{bdir}/pre_run_bundle/pre-run.request", f"{bdir}/pre_run_bundle/pre-run.meta.json"
meta = json.load(open(meta_path))
head = call(rpc_url, "eth_getBlockByNumber", ["latest", False])
if int(head["number"], 16) != meta["end_block_number"] or head["hash"] != meta["end_block_hash"]:
    sys.exit(f"geth head {int(head['number'], 16)} is not the bundle end {meta['end_block_number']}")

i, built, prev_gl = meta["payloads"], 0, int(head["gasLimit"], 16)
with open(req_path, "a") as f:
    while built < MIN_BLOCKS or int(head["gasLimit"], 16) > target:
        attrs = {"timestamp": hex(int(head["timestamp"], 16) + 1), "prevRandao": head["hash"],
                 "suggestedFeeRecipient": "0x" + "00" * 20, "withdrawals": [],
                 "parentBeaconBlockRoot": head["hash"]}
        # The image is past Amsterdam (V5, slot numbers); an Osaka chain takes V4 (used by the test).
        amsterdam = head.get("slotNumber") is not None
        if amsterdam:
            attrs["slotNumber"] = hex(int(head["slotNumber"], 16) + 1)
        method = "engine_newPayloadV5" if amsterdam else "engine_newPayloadV4"
        res = call(rpc_url, "testing_buildBlockV1", [head["hash"], attrs, [], EXTRA_DATA])
        payload = res.get("executionPayload", res)
        params = [payload, [], head["hash"], res.get("executionRequests") or []]
        st = call(engine_url, method, params, auth=True)
        if st["status"] != "VALID":
            sys.exit(f"block {int(payload['blockNumber'], 16)}: newPayload {st}")
        fc = {"finalizedBlockHash": payload["blockHash"], "headBlockHash": payload["blockHash"],
              "safeBlockHash": payload["blockHash"]}
        call(engine_url, "engine_forkchoiceUpdatedV3", [fc, None], auth=True)
        i += 1
        f.write(json.dumps({"id": i, "jsonrpc": "2.0", "method": method, "params": params},
                           separators=(",", ":")) + "\n")
        f.write(json.dumps({"id": i, "jsonrpc": "2.0", "method": "engine_forkchoiceUpdatedV3", "params": [fc, None]},
                           separators=(",", ":")) + "\n")
        head = call(rpc_url, "eth_getBlockByNumber", ["latest", False])
        gl = int(head["gasLimit"], 16)
        if built == 0 and gl >= prev_gl and gl > target:
            sys.exit(f"gas limit did not fall ({prev_gl} -> {gl}): is geth running with --miner.gaslimit={target}?")
        built += 1
        if built % 500 == 0:
            print(f"  {built} blocks, gas limit {gl}", flush=True)

meta.update(payloads=i, end_block_number=int(head["number"], 16), end_block_hash=head["hash"],
            ramp_down_blocks=built, end_gas_limit=int(head["gasLimit"], 16))
json.dump(meta, open(meta_path, "w"), indent=2)
print(f"ramp-down: {built} blocks to gas limit {int(head['gasLimit'], 16)}, head {meta['end_block_number']} {head['hash']}")
