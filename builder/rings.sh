#!/usr/bin/env bash
# Ring maintenance for a repository that runs unattended (docs/pipeline.md):
#
#   - promote canary -> early once a level has been in canary for
#     PROMOTE_EARLY_DAYS (default 3), and early -> stable once it has been
#     in early for PROMOTE_STABLE_DAYS (default 7); a level moves at most
#     one ring per run
#   - renew every ring manifest that expires within RENEW_DAYS (default 10):
#     same level and build time, a new expiry VALID_DAYS (default 30) from
#     now. Without this, a kernel that gets no new level stops being
#     installable when its manifest expires.
#
# Nothing is promoted that is revoked (v1/revoked.json) or held. The holds
# file lists "<kernel|*> <level|*> <reason>" per line (# starts a comment);
# "* * <reason>" stops all promotions. Revoked levels are not renewed either.
# Only manifests that verify with the given public key are promoted
# (promote.sh) or renewed.
#
# usage: rings.sh <repo-root> <manifest-pubkey> [holds-file]
#
# MANIFEST_KEY (hvpatch-tool key) or MINISIGN_KEY (minisign) signs.
# PROMOTE=0 only renews. Exits 1 if anything could not be checked or
# changed (after doing everything else).
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?usage: rings.sh <repo-root> <manifest-pubkey> [holds-file]}; PUB=${2:?pubkey}; HOLDS=${3:-}
require hvpatch-tool python3 date
EARLY_DAYS=${PROMOTE_EARLY_DAYS:-3}; STABLE_DAYS=${PROMOTE_STABLE_DAYS:-7}
RENEW_DAYS=${RENEW_DAYS:-10}; VALID_DAYS=${VALID_DAYS:-30}
for n in "$EARLY_DAYS" "$STABLE_DAYS" "$RENEW_DAYS" "$VALID_DAYS"; do
  [[ "$n" =~ ^[0-9]{1,3}$ ]] || die "day counts must be small integers"
done
[ -z "$HOLDS" ] || [ -f "$HOLDS" ] || die "holds file $HOLDS not found"
NOW=$(date -u +%s)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BAD=0

# When <level> first reached <ring>: the oldest <ring>.versions/<level>-<stamp>
# (renewals add newer ones). Empty if unknown.
first_published() {
  local d stamp oldest=""
  for d in "$1/$2.versions/$3-"*; do
    [ -d "$d" ] || continue
    stamp=${d##*/"$3"-}
    [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    if [ -z "$oldest" ] || [[ "$stamp" < "$oldest" ]]; then oldest=$stamp; fi
  done
  [ -n "$oldest" ] || return 0
  date -u -d "${oldest:0:4}-${oldest:4:2}-${oldest:6:2} ${oldest:9:2}:${oldest:11:2}:${oldest:13:2}" +%s
}

held() {
  [ -n "$HOLDS" ] || return 1
  local k l _
  while read -r k l _; do
    case "$k" in '' | '#'*) continue ;; esac
    if { [ "$k" = '*' ] || [ "$k" = "$1" ]; } && { [ "$l" = '*' ] || [ "$l" = "$2" ]; }; then return 0; fi
  done < "$HOLDS"
  return 1
}

revoked() {
  [ -f "$REPO/v1/revoked.json" ] || return 1
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(r.get("kernel") == sys.argv[2] and r.get("level") == int(sys.argv[3]) for r in d.get("revoked", [])) else 1)
' "$REPO/v1/revoked.json" "$1" "$2"
}

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

# promote <kver> <from> <to> <days>
promote() {
  local kver=$1 from=$2 to=$3 days=$4 base level since
  base="$REPO/v1/$kver"
  [ -f "$base/$from/manifest.json" ] || return 0
  level=$(ring_level "$REPO" "$kver" "$from")
  [ "$level" -gt "$(ring_level "$REPO" "$kver" "$to")" ] || return 0
  since=$(first_published "$base" "$from" "$level")
  if [ -z "$since" ]; then
    log "$kver level $level: no publication time in $from.versions; not promoting"
    return 0
  fi
  [ $(( NOW - since )) -ge $(( days * 86400 )) ] || return 0
  if revoked "$kver" "$level"; then log "$kver level $level is revoked; not promoting"; return 0; fi
  if held "$kver" "$level"; then log "$kver level $level is held; not promoting to $to"; return 0; fi
  if VALID_DAYS=$VALID_DAYS "$HERE/promote.sh" "$REPO" "$kver" "$to" "$PUB"; then
    PROMOTED="$PROMOTED $kver/$to"
  else
    log "promoting $kver level $level to $to failed"; BAD=1
  fi
}

# renew <kver> <ring>
renew() {
  local kver=$1 ring=$2 m level expires
  m="$REPO/v1/$kver/$ring/manifest.json"
  [ -f "$m" ] || return 0
  if ! hvpatch-tool verify --pubkey "$PUB" "$m" >/dev/null; then
    log "$kver $ring: the manifest does not verify with $PUB; not renewing"; BAD=1; return 0
  fi
  level=$(field "$m" level)
  expires=$(date -u -d "$(field "$m" expires)" +%s)
  [ $(( expires - NOW )) -lt $(( RENEW_DAYS * 86400 )) ] || return 0
  if revoked "$kver" "$level"; then log "$kver level $level is revoked; letting its $ring manifest expire"; return 0; fi
  if hvpatch-tool renew --manifest "$m" --valid-days "$VALID_DAYS" --out "$TMP/manifest.json" \
    && publish_ring "$REPO" "$kver" "$ring" "$TMP/manifest.json" "$level" "kernel:$kver level:$level ring:$ring renewed"; then
    RENEWED=$(( RENEWED + 1 ))
  else
    log "renewing $kver $ring failed"; BAD=1
  fi
}

PROMOTED=""; RENEWED=0
for base in "$REPO"/v1/*/; do
  kver=$(basename "$base")
  [[ "$kver" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve$ ]] || continue
  if [ "${PROMOTE:-1}" = 1 ]; then
    # Higher ring first: a level moves at most one ring per run.
    promote "$kver" early stable "$STABLE_DAYS"
    promote "$kver" canary early "$EARLY_DAYS"
  fi
  for ring in canary early stable; do renew "$kver" "$ring"; done
done
log "ring maintenance: promoted:${PROMOTED:- none}; renewed: $RENEWED"
exit "$BAD"
