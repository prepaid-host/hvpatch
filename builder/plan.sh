#!/usr/bin/env bash
# Decide what an unattended pipeline builds next: at most one kernel per run.
#
# usage: plan.sh <published-repo-dir>
#
# Prints "<kver> <level> <previous-module-or-->" for the first kernel that
# needs a build, or nothing. A kernel needs a build when it is one of the
# NEWEST releases of a SERIES in the Proxmox repository (apt, signature
# checked) and either has no published level yet, or the catalog changed
# since the commit its published level was built from.
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

for s in $SERIES; do
  apt-cache search --names-only "^proxmox-kernel-${s//./\\.}\.[0-9]+-[0-9]+-pve-signed$" \
    | sed -E 's/^proxmox-kernel-([^ ]+)-signed .*/\1/' | sort -V | tail -n "$NEWEST" | sort -rV
done | while read -r kver; do
  [ -e "$STATE/$kver@$COMMIT.failed" ] && { log "$kver: failed at $COMMIT before, skipped"; continue; }
  [ -e "$STATE/$kver@$COMMIT.none" ] && continue
  m="$REPO/v1/$kver/canary/manifest.json"
  if [ ! -f "$m" ]; then
    log "$kver: nothing published yet"
    echo "$kver 1 -"; exit 0
  fi
  read -r level module built_from < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["level"], m["module"], m.get("catalog_commit") or "unknown")' "$m")
  if [ "$built_from" != unknown ] && git -C "$CATALOG" cat-file -e "${built_from%-dirty}^{commit}" 2>/dev/null \
     && git -C "$CATALOG" diff --quiet "${built_from%-dirty}" "$COMMIT" -- .; then
    continue
  fi
  prev="$REPO/v1/$kver/$module"
  [ -f "$prev" ] || prev=-
  log "$kver: catalog changed since level $level ($built_from)"
  echo "$kver $((level + 1)) $prev"; exit 0
done
