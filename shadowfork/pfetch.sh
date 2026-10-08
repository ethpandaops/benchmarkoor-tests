#!/bin/sh
# pfetch.sh <url> [workers] [chunk-bytes] : write <url> to stdout, fetched as parallel
# ranged GETs and emitted in order. One stream from R2 via Cloudflare tops out ~95 MB/s;
# 16 ranges measured 239-349 MB/s. POSIX sh + curl, so it runs in ethereum-package's
# alpine downloader: `pfetch.sh "$URL" | tar -I zstd -xf - -C "$DIR"`.
# At most 2 x workers chunks are staged in $TMPDIR; a chunk is retried until complete.
set -eu
URL=$1; P=${2:-16}; C=${3:-67108864}
TOTAL=$(curl -sfIL "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')
[ -n "$TOTAL" ] || { echo "pfetch: no Content-Length for $URL" >&2; exit 1; }
[ -z "${PFETCH_BYTES:-}" ] || [ "$PFETCH_BYTES" -ge "$TOTAL" ] || TOTAL=$PFETCH_BYTES   # testing: a prefix only
N=$(( (TOTAL + C - 1) / C ))
T=$(mktemp -d); echo 0 > "$T/emitted"
PIDS=""   # our workers only: `kill 0` would also hit the tar we are piped into
trap 'kill $PIDS 2>/dev/null || true; rm -rf "$T"' EXIT INT TERM

fetch() { # fetch <i>: until the chunk file holds exactly its range
  s=$(( $1 * C )); e=$(( s + C - 1 )); [ "$e" -lt "$TOTAL" ] || e=$(( TOTAL - 1 ))
  want=$(( e - s + 1 )); tries=0
  while :; do
    # --max-filesize: a cold, cache-eligible object can answer a Range with 200 and the
    # whole body (measured on snapshots.ethpandaops.io); refuse it before a byte lands.
    curl -sfL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --max-filesize "$want" \
      -r "$s-$e" -o "$T/$1.part" "$URL" || true
    [ "$(wc -c 2>/dev/null < "$T/$1.part" || echo 0)" -eq "$want" ] && { mv "$T/$1.part" "$T/$1"; return; }
    tries=$(( tries + 1 )); [ "$tries" -lt 50 ] || { echo "pfetch: chunk $1 failed $tries times" >&2; touch "$T/failed"; return 1; }
    sleep 2
  done
}

k=0
while [ "$k" -lt "$P" ]; do
  { ( i=$k
    while [ "$i" -lt "$N" ]; do
      while [ $(( i - $(cat "$T/emitted") )) -ge $(( 2 * P )) ]; do sleep 0.1; done
      fetch "$i" || exit 1
      i=$(( i + P ))
    done ) || touch "$T/failed"; } &   # a worker that dies must fail the stream, not hang it
  PIDS="$PIDS $!"; k=$(( k + 1 ))
done

i=0
while [ "$i" -lt "$N" ]; do
  while [ ! -f "$T/$i" ]; do [ ! -f "$T/failed" ] || exit 1; sleep 0.05; done
  cat "$T/$i"; rm -f "$T/$i"; i=$(( i + 1 ))
  echo "$i" > "$T/emitted.tmp"; mv "$T/emitted.tmp" "$T/emitted"   # atomic: a torn read kills a worker
done
wait
