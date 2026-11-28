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
# The repository may come from a host this script does not trust (it is
# synced from the web server). So:
#   - every manifest must verify with the public key and name the kernel and
#     ring it is served as; expired manifests are never renewed
#   - STATE (a directory only this pipeline writes) records per kernel and
#     ring the highest level seen and since when. A ring that serves a lower
#     level than recorded is a rollback and is left alone, and the time a
#     level spent in a ring is counted from STATE, not from file names
#   - v1/revoked.json must verify too, and its sequence must not go back or
#     the file vanish; otherwise nothing is promoted or renewed
#
# Renewal also covers v1/revoked.json (if there is one): it is re-issued
# (same entries, sequence + 1, new issued time) once it is
# REVOCATIONS_REISSUE_DAYS (default 3) old. Agents refuse to load anything
# new when the list they have is older than revocation_max_age_days
# (default 14). Runs with PROMOTE=0 too.
#
# Nothing is promoted that is revoked or held. The holds file lists
# "<kernel|*> <level|*> <reason>" per line (# starts a comment); "* * <reason>"
# stops all promotions. Revoked levels are not renewed either.
#
# usage: rings.sh <repo-root> <manifest-pubkey> <state-dir> [holds-file]
#
# MANIFEST_KEY (hvpatch-tool key) or MINISIGN_KEY (minisign) signs.
# PROMOTE=0 only renews. Exits 1 if anything looked wrong or could not be
# changed (after doing everything else that is safe).
source "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?usage: rings.sh <repo-root> <manifest-pubkey> <state-dir> [holds-file]}
PUB=${2:?pubkey}; STATE=${3:?state dir}; HOLDS=${4:-}
require hvpatch-tool python3 date
EARLY_DAYS=${PROMOTE_EARLY_DAYS:-3}; STABLE_DAYS=${PROMOTE_STABLE_DAYS:-7}
RENEW_DAYS=${RENEW_DAYS:-10}; VALID_DAYS=${VALID_DAYS:-30}
REISSUE_DAYS=${REVOCATIONS_REISSUE_DAYS:-3}
for n in "$EARLY_DAYS" "$STABLE_DAYS" "$RENEW_DAYS" "$VALID_DAYS" "$REISSUE_DAYS"; do
  [[ "$n" =~ ^[0-9]{1,3}$ ]] || die "day counts must be small integers"
done
[ -z "$HOLDS" ] || [ -f "$HOLDS" ] || die "holds file $HOLDS not found"
mkdir -p "$STATE"
NOW=$(date -u +%s)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BAD=0

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

# Recorded "<level> <since>" for a kernel and ring ("0 0" if none).
recorded() {
  local f="$STATE/$1.$2" l s
  if read -r l s 2>/dev/null < "$f" && [[ "$l" =~ ^[0-9]{1,6}$ ]] && [[ "$s" =~ ^[0-9]{1,12}$ ]]; then
    echo "$l $s"
  else
    echo "0 0"
  fi
}
record() { echo "$3 $4" > "$STATE/$1.$2.tmp" && mv "$STATE/$1.$2.tmp" "$STATE/$1.$2"; }

# Revocations: verified, sequence never lower than recorded.
SEQ_FILE=$STATE/revoked.sequence
SEQ_SEEN=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
[[ "$SEQ_SEEN" =~ ^[0-9]{1,12}$ ]] || SEQ_SEEN=0
LIST=$REPO/v1/revoked.json
if [ -f "$LIST" ]; then
  hvpatch-tool verify --pubkey "$PUB" "$LIST" >/dev/null || die "v1/revoked.json does not verify; not promoting or renewing anything"
  SEQ=$(field "$LIST" sequence)
  [[ "$SEQ" =~ ^[0-9]{1,12}$ ]] || die "v1/revoked.json: bad sequence"
  [ "$SEQ" -ge "$SEQ_SEEN" ] || die "v1/revoked.json went back from sequence $SEQ_SEEN to $SEQ; not promoting or renewing anything"
  echo "$SEQ" > "$SEQ_FILE"
  # Agents refuse new loads when the list is older than their
  # revocation_max_age_days (default 14), so it is re-issued before that.
  ISSUED=$(date -u -d "$(field "$LIST" issued)" +%s) || die "v1/revoked.json: bad issued"
  if [ $(( NOW - ISSUED )) -ge $(( REISSUE_DAYS * 86400 )) ]; then
    cp "$LIST" "$TMP/revoked.json"
    if hvpatch-tool reissue-revocations --list "$TMP/revoked.json" >/dev/null \
      && publish_revocations "$TMP/revoked.json" "$LIST"; then
      # Not recorded in SEQ_FILE: only what the mirror serves counts, or a
      # failed push leaves later runs dying on "went back".
      log "re-issued v1/revoked.json (sequence $REVOCATIONS_SEQUENCE)"
    else
      log "re-issuing v1/revoked.json failed; agents stop loading when it gets too old"; BAD=1
    fi
  fi
elif [ "$SEQ_SEEN" -gt 0 ]; then
  die "v1/revoked.json is gone (sequence $SEQ_SEEN was published); not promoting or renewing anything"
fi
# revoked <kver> <level> <sha256>
revoked() {
  [ -f "$LIST" ] || return 1
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
k, l, h = sys.argv[2], int(sys.argv[3]), sys.argv[4]
sys.exit(0 if any(r.get("sha256") == h or (r.get("kernel") == k and r.get("level") == l) for r in d.get("revoked", [])) else 1)
' "$LIST" "$1" "$2" "$3"
}

held() {
  [ -n "$HOLDS" ] || return 1
  local k l _
  while read -r k l _ || [ -n "$k" ]; do
    case "$k" in '' | '#'*) continue ;; esac
    if { [ "$k" = '*' ] || [ "$k" = "$1" ]; } && { [ "$l" = '*' ] || [ "$l" = "$2" ]; }; then return 0; fi
  done < "$HOLDS"
  return 1
}

# check <kver> <ring>: verify what the ring serves and update STATE. Sets
# LEVEL (0 if the ring is empty or must be left alone) and SHA.
check() {
  local kver=$1 ring=$2 m rl
  LEVEL=0; SHA=""
  m="$REPO/v1/$kver/$ring/manifest.json"
  [ -f "$m" ] || return 0
  if ! hvpatch-tool verify --pubkey "$PUB" "$m" >/dev/null; then
    log "$kver $ring: the manifest does not verify with $PUB; leaving it alone"; BAD=1; return 0
  fi
  if [ "$(field "$m" kernel)" != "$kver" ] || [ "$(field "$m" ring)" != "$ring" ]; then
    log "$kver $ring: the manifest is for $(field "$m" kernel) ring $(field "$m" ring); leaving it alone"; BAD=1; return 0
  fi
  local level; level=$(field "$m" level)
  read -r rl _ <<< "$(recorded "$kver" "$ring")"
  if [ "$level" -lt "$rl" ]; then
    # Going back is fine after revocations (revoke.sh), to the highest level
    # below that is not revoked: every level above it must be revoked.
    local l
    for (( l = level + 1; l <= rl; l++ )); do
      if ! revoked "$kver" "$l" ""; then
        log "$kver $ring serves level $level, but level $l was published there and is not revoked: rollback? leaving it alone"
        BAD=1; return 0
      fi
    done
    record "$kver" "$ring" "$level" "$NOW"
  elif [ "$level" -gt "$rl" ]; then
    record "$kver" "$ring" "$level" "$NOW"
  fi
  LEVEL=$level; SHA=$(field "$m" sha256)
}

# promote <kver> <from> <to> <days>
promote() {
  local kver=$1 from=$2 to=$3 days=$4 level sha to_level rl since
  check "$kver" "$from"; level=$LEVEL; sha=$SHA
  [ "$level" -gt 0 ] || return 0
  check "$kver" "$to"; to_level=$LEVEL
  read -r rl _ <<< "$(recorded "$kver" "$to")"
  [ "$level" -gt "$to_level" ] && [ "$level" -gt "$rl" ] || return 0
  read -r _ since <<< "$(recorded "$kver" "$from")"
  [ $(( NOW - since )) -ge $(( days * 86400 )) ] || return 0
  if revoked "$kver" "$level" "$sha"; then log "$kver level $level is revoked; not promoting"; return 0; fi
  if held "$kver" "$level"; then log "$kver level $level is held; not promoting to $to"; return 0; fi
  if VALID_DAYS=$VALID_DAYS "$HERE/promote.sh" "$REPO" "$kver" "$to" "$PUB"; then
    record "$kver" "$to" "$level" "$NOW"
    PROMOTED="$PROMOTED $kver/$to"
  else
    log "promoting $kver level $level to $to failed"; BAD=1
  fi
}

# renew <kver> <ring>
renew() {
  local kver=$1 ring=$2 m expires
  check "$kver" "$ring"
  [ "$LEVEL" -gt 0 ] || return 0
  m="$REPO/v1/$kver/$ring/manifest.json"
  expires=$(date -u -d "$(field "$m" expires)" +%s)
  [ $(( expires - NOW )) -lt $(( RENEW_DAYS * 86400 )) ] || return 0
  if [ "$expires" -le "$NOW" ]; then
    log "$kver $ring: level $LEVEL expired; it is not renewed (publish a fresh level)"; BAD=1; return 0
  fi
  if revoked "$kver" "$LEVEL" "$SHA"; then log "$kver level $LEVEL is revoked; letting its $ring manifest expire"; return 0; fi
  if hvpatch-tool renew --manifest "$m" --valid-days "$VALID_DAYS" --out "$TMP/manifest.json" \
    && publish_ring "$REPO" "$kver" "$ring" "$TMP/manifest.json" "$LEVEL" "kernel:$kver level:$LEVEL ring:$ring renewed"; then
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
