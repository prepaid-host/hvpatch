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
  # The published copy comes from the mirror: treat every field as untrusted
  # and pass on only values of a strict form (they reach shell arithmetic
  # and file paths).
  fields=$(python3 -I -c '
import json, re, sys
m = json.load(open(sys.argv[1]))
level, module, commit = m["level"], m["module"], m.get("catalog_commit") or "unknown"
if type(level) is not int or not 0 < level < 1000000:
    sys.exit("bad level")
if not isinstance(module, str) or not re.fullmatch(r"klp_[A-Za-z0-9_]{1,100}\.ko", module):
    sys.exit("bad module name")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}(-dirty)?|unknown", commit):
    sys.exit("bad catalog_commit")
print(level, module, commit)' "$m") || die "$m: unexpected manifest content"
  read -r level module built_from <<< "$fields"
  [[ $level =~ ^[0-9]{1,6}$ ]] || die "$m: bad level"
  if [ "$built_from" != unknown ] && git -C "$CATALOG" cat-file -e "${built_from%-dirty}^{commit}" 2>/dev/null \
     && git -C "$CATALOG" diff --quiet "${built_from%-dirty}" "$COMMIT" -- .; then
    continue
  fi
  prev="$REPO/v1/$kver/$module"
  [ -f "$prev" ] || prev=-
  log "$kver: catalog changed since level $level ($built_from)"
  echo "$kver $((level + 1)) $prev"; exit 0
done
