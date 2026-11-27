#!/usr/bin/env bash
# Revoke a published module: nodes stop loading it, and nodes that run it
# put the highest cached level below it back (or unload it) on their next
# `hvpatch apply` (the timer).
#
# usage: revoke.sh <repo-root> <kver> <level> <reason>
#
# Updates <repo>/v1/revoked.json (sequence + 1) and signs it with
# MANIFEST_KEY (hvpatch-tool key) or MINISIGN_KEY (minisign). Then publish a
# fixed level, or point the rings at a level that is not revoked.
source "$(dirname "$0")/lib.sh"
REPO=${1:?usage: revoke.sh <repo-root> <kver> <level> <reason>}; KVER=${2:?kver}; LEVEL=${3:?level}; REASON=${4:?reason}
require hvpatch-tool
NAME=$(hvpatch-tool module-name --kernel "$KVER" --level "$LEVEL")
KO="$REPO/v1/$KVER/$NAME.ko"
regular "$KO"
LIST="$REPO/v1/revoked.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ -f "$LIST" ] && cp "$LIST" "$TMP/revoked.json"
hvpatch-tool revoke --list "$TMP/revoked.json" --module "$KO" --kernel "$KVER" --level "$LEVEL" --reason "$REASON"
publish_revocations "$TMP/revoked.json" "$LIST"
SEQ=$REVOCATIONS_SEQUENCE
log "revoked $KVER level $LEVEL (list sequence $SEQ)"
