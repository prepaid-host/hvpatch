#!/usr/bin/env bash
# Decide what an unattended pipeline builds next: at most one kernel per run.
#
# usage: plan.sh <published-repo-dir>
#
# Prints "<kver> <level> <previous-module-or-->" for the first kernel that
# needs a build, or nothing. A kernel needs a build when it is one of the
# NEWEST releases of a SERIES in the Proxmox repository (apt, signature
# checked) and either has no published level yet, or the catalog changed
# since the commit its published level was built from. The new level is one
# above the highest published module file, even if the canary ring serves a
# lower one (after a revocation).
#
# Environment:
#   CATALOG   catalog directory inside a full git clone (default ./catalog)
#   SERIES    kernel series to serve (default "7.0 7.3")
#   NEWEST    releases per series (default 2)
#   STATE     directory for markers of finished attempts; a kernel that
#             failed or had nothing to livepatch at a catalog commit is not
#             tried again until the catalog changes (default ./state)
source "$(dirname "$0")/lib.sh"
REPO=${1:?usage: plan.sh <published-repo-dir>}
CATALOG=${CATALOG:-$PWD/catalog}
SERIES=${SERIES:-"7.0 7.3"}
NEWEST=${NEWEST:-2}
STATE=${STATE:-$PWD/state}
require apt-get apt-cache git python3
mkdir -p "$STATE"

apt-get update -qq >/dev/null 2>&1 || die "apt-get update failed (Proxmox repository)"
COMMIT=$(git -C "$CATALOG" rev-parse HEAD)

# manifest_fields <file>: print "<level> <module> <catalog_commit>". The
# published copy comes from the mirror: treat every field as untrusted and
# pass on only values of a strict form (they reach shell arithmetic and file
# paths).
manifest_fields() {
  python3 -I -c '
import json, re, sys
m = json.load(open(sys.argv[1]))
level, module, commit = m["level"], m["module"], m.get("catalog_commit") or "unknown"
if type(level) is not int or not 0 < level < 1000000:
    sys.exit("bad level")
if not isinstance(module, str) or not re.fullmatch(r"klp_[A-Za-z0-9_]{1,100}\.ko", module):
    sys.exit("bad module name")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}(-dirty)?|unknown", commit):
    sys.exit("bad catalog_commit")
print(level, module, commit)' "$1"
}

# catalog_unchanged <commit>: the catalog is the same as at <commit>.
catalog_unchanged() {
  [ "$1" != unknown ] && git -C "$CATALOG" cat-file -e "${1%-dirty}^{commit}" 2>/dev/null \
    && git -C "$CATALOG" diff --quiet "${1%-dirty}" "$COMMIT" -- .
}

# Collect first: leaving a `cmd | while` loop early would SIGPIPE the
# producer, and pipefail turns that into a failure.
KERNELS=()
mapfile -t KERNELS < <(SERIES=$SERIES NEWEST=$NEWEST served_kernels)
for kver in ${KERNELS[@]+"${KERNELS[@]}"}; do
  [ -e "$STATE/$kver@$COMMIT.failed" ] && { log "$kver: failed at $COMMIT before, skipped"; continue; }
  [ -e "$STATE/$kver@$COMMIT.none" ] && continue
  m="$REPO/v1/$kver/canary/manifest.json"
  if [ ! -f "$m" ]; then
    log "$kver: nothing published yet"
    echo "$kver 1 -"; exit 0
  fi
  fields=$(manifest_fields "$m") || die "$m: unexpected manifest content"
  read -r level module built_from <<< "$fields"
  [[ $level =~ ^[0-9]{1,6}$ ]] || die "$m: bad level"
  catalog_unchanged "$built_from" && continue
  prev="$REPO/v1/$kver/$module"
  [ -f "$prev" ] || prev=-
  # After a revocation the canary ring may serve a lower level than the
  # highest published one: never plan a level number that already exists.
  top=$level
  base=${module%_p*}
  for f in "$REPO/v1/$kver/${base}_p"*.ko; do
    n=${f##*_p}; n=${n%.ko}
    [[ $n =~ ^[0-9]{1,6}$ ]] && [ "$((10#$n))" -gt "$top" ] && top=$((10#$n))
  done
  if [ "$top" -gt "$level" ]; then
    # Canary was moved back (revocation): the catalog may be unchanged since
    # the level above it, whose code is the revoked one. Do not rebuild it
    # under a new number, no revocation entry would match it.
    for tm in "$REPO/v1/$kver/"*.versions/"$top"-*/manifest.json; do
      if fields=$(manifest_fields "$tm" 2>/dev/null); then
        read -r tl _ tc <<< "$fields"
        if [ "$tl" = "$top" ] && catalog_unchanged "$tc"; then
          log "$kver: catalog unchanged since level $top ($tc), which canary no longer serves; not rebuilding"
          continue 2
        fi
      fi
      break
    done
  fi
  log "$kver: catalog changed since level $level ($built_from)"
  echo "$kver $((top + 1)) $prev"; exit 0
done
