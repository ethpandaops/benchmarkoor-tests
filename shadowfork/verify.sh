#!/bin/bash
# Check an uploaded object against the block hashes publish.sh took of the stream it sent: its size,
# then N random 1 GiB blocks. Images are read through the public host as consumers read them (each
# Range must be a 206); bundles/ is not public (WAF), so it is read with the bucket credentials.
#   shadowfork/verify.sh <object-path> <blocks-file> [N=3]
source "$(dirname "$0")/lib.sh"
obj=${1:?object} f=${2:?blocks file} n=${3:-3}
want=$(awk '$2=="total"{print $1}' "$f")
if [[ $obj == mainnet/* ]]; then
  got=$(curl -sfI "$PUBLIC/$obj" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
else
  got=$(r2 size --json "r2:$BUCKET/$obj" | jq .bytes)
fi
[ "$got" = "$want" ] || die "$obj: size $got, uploaded $want"
blocks=$(grep -vc total "$f")
for i in $(shuf -i 0-$((blocks - 1)) -n "$(( n < blocks ? n : blocks ))"); do
  s=$((i << 30)); len=$(( (1 << 30) )); [ $((s + len)) -le "$want" ] || len=$((want - s))
  if [[ $obj == mainnet/* ]]; then
    code=$(curl -s -o "$WORK/vb.$i" -w '%{http_code}' -r "$s-$((s + len - 1))" "$PUBLIC/$obj")
    [ "$code" = 206 ] || die "$obj block $i: HTTP $code"
  else
    r2 cat --offset "$s" --count "$len" "r2:$BUCKET/$obj" > "$WORK/vb.$i"
  fi
  [ "$(sha256sum < "$WORK/vb.$i" | cut -d' ' -f1)" = "$(awk -v i="$i" '$1==i{print $2}' "$f")" ] \
    || die "$obj block $i: hash mismatch"
  rm -f "$WORK/vb.$i"; log "$obj block $i OK"
done
log "$obj: $want bytes, size and random blocks match"
