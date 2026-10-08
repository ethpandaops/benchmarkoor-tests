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
  reth|erigon|ethrex) echo "$c datadir layout not checked (unverified)"; exit 0 ;;
  *) echo "::error::unknown client $c"; exit 1 ;;
esac
echo "$c datadir layout ok: $d"
