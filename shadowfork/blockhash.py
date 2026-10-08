#!/usr/bin/env python3
"""sha256 of every 1 GiB block of stdin: '<index> <sha256>' per block, then '<total bytes> total'."""
import hashlib, sys

BLOCK = 1 << 30
i = total = 0
h, n = hashlib.sha256(), 0
for chunk in iter(lambda: sys.stdin.buffer.read(1 << 22), b""):
    total += len(chunk)
    while chunk:
        take = chunk[: BLOCK - n]
        h.update(take); n += len(take); chunk = chunk[len(take):]
        if n == BLOCK:
            print(i, h.hexdigest(), flush=True); i += 1; h, n = hashlib.sha256(), 0
if n:
    print(i, h.hexdigest(), flush=True)
print(total, "total", flush=True)
