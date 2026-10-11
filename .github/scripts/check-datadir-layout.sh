#!/usr/bin/env bash
# Fail before a client boots on a datadir laid out differently from what it is started with.
# geth started with --datadir on a flat instance dir (chaindata/ at the top) still opens the
# database, but looks for triedb/merkle.journal under <datadir>/geth/, discards the state it
# holds, rewinds the head and truncates state history: the datadir is spoiled, not just unused.
#   check-datadir-layout.sh <client> <datadir>
set -euo pipefail
c=${1:?client} d=${2:?datadir}
need() { [ -e "$d/$1" ] || { echo "::error::$c datadir $d has no $1 (wrong layout)"; exit 1; }; }
case $c in
  geth) need geth/chaindata
        [ ! -e "$d/chaindata" ] || { echo "::error::$d/chaindata: a flat instance dir, geth wants it under $d/geth/"; exit 1; } ;;
  nethermind) need nethermind_db/mainnet/state ;;
  besu) need database ;;
  # jochemnet's reth v2 archive: static_files/, rocksdb/ and the MDBX db at the datadir root.
  reth) need static_files; need rocksdb ;;
  # erigon's pruned archive is its datadir: chaindata/ (mdbx) and snapshots/ (segments).
  erigon) need chaindata; need snapshots ;;
  # ethrex keeps its RocksDB at <datadir>/chain-1; the archive is that directory's contents.
  ethrex) need chain-1/CURRENT ;;
  *) echo "::error::unknown client $c"; exit 1 ;;
esac
echo "$c datadir layout ok: $d"
