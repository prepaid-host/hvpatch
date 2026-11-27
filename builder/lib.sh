# shellcheck shell=bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# 7.3.5-1-pve -> 7.3.5-1
pkgver() { printf '%s' "${1%-pve}"; }
# 7.3.5-1-pve -> 7.3
series() { local v="${1%%-*}"; printf '%s' "${v%.*}"; }

require() { for c in "$@"; do command -v "$c" >/dev/null || die "missing tool: $c"; done; }

# A repository URL without credentials (user:token@), for anything that is
# written to logs or published.
public_url() { printf '%s' "$1" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#'; }

# Files written by an earlier, less trusted stage (the build container runs
# kernel Makefiles and catalog patches) are only read if they are regular
# files, not symlinks: a planted link to a key would otherwise be read in
# the signing container or published by publish.sh.
regular() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ ! -L "$f" ] || die "$f is not a regular file (symlink or missing)"
  done
}

# Kernels the pipeline serves, newest first per series: the NEWEST (default
# 2) releases of each series in SERIES (default "7.0 7.3") that the Proxmox
# repository has (apt-cache; run apt-get update first).
served_kernels() {
  local s
  for s in ${SERIES:-7.0 7.3}; do
    apt-cache search --names-only "^proxmox-kernel-${s//./\\.}\.[0-9]+-[0-9]+-pve-signed$" \
      | sed -E 's/^proxmox-kernel-([^ ]+)-signed .*/\1/' | sort -V | tail -n "${NEWEST:-2}" | sort -rV
  done
}

# Level of the manifest a ring currently points to (0 if none).
ring_level() {
  local m="$1/v1/$2/$3/manifest.json"
  [ -f "$m" ] || { echo 0; return; }
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["level"])' "$m"
}

# Sign a manifest and make <repo>/v1/<kver>/<ring> point to it atomically.
#   <ring>            symlink -> <ring>.versions/<level>-<timestamp>/
#   <ring>.versions/  every manifest ever published to this ring
# Readers never see a manifest without its signature, and earlier versions
# stay available for audits. Static hosts must follow symlinks (rsync -L,
# or `aws s3 sync` on a dereferenced copy).
#
# Signing: MANIFEST_KEY (hvpatch-tool key) or MINISIGN_KEY (minisign secret
# key, e.g. on an offline machine or token).
publish_ring() {
  local repo="$1" kver="$2" ring="$3" manifest="$4" level="$5" comment="$6"
  local base="$repo/v1/$kver" stamp target
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  target="$ring.versions/$level-$stamp"
  mkdir -p "$base/$target"
  cp "$manifest" "$base/$target/manifest.json"
  if [ -n "${MINISIGN_KEY:-}" ]; then
    minisign -S -s "$MINISIGN_KEY" -m "$base/$target/manifest.json" -t "$comment"
  else
    hvpatch-tool sign --key "${MANIFEST_KEY:?MANIFEST_KEY or MINISIGN_KEY not set}" \
      --trusted-comment "$comment" "$base/$target/manifest.json"
  fi
  # Repositories from before 0.2.2 have <ring> as a plain directory.
  if [ -d "$base/$ring" ] && [ ! -L "$base/$ring" ]; then
    mkdir -p "$base/$ring.versions"
    mv "$base/$ring" "$base/$ring.versions/legacy-$stamp"
  fi
  ln -sfn "$target" "$base/$ring.new"
  mv -T "$base/$ring.new" "$base/$ring"
  log "published $kver level $level to ring $ring ($target)"
}

# Sign a revocation list (<new-list>, already updated) and publish it as
# <list>. Prints the sequence. Signing: MINISIGN_KEY or MANIFEST_KEY, as above.
publish_revocations() {
  local new="$1" list="$2" seq
  seq=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["sequence"])' "$new") || return 1
  # Explicit returns: callers may run this in an `if`, where set -e is off,
  # and a list must never be published without its new signature.
  if [ -n "${MINISIGN_KEY:-}" ]; then
    minisign -S -s "$MINISIGN_KEY" -m "$new" -t "revocations sequence:$seq" || return 1
  elif [ -n "${MANIFEST_KEY:-}" ]; then
    hvpatch-tool sign --key "$MANIFEST_KEY" \
      --trusted-comment "revocations sequence:$seq" "$new" || return 1
  else
    log "MANIFEST_KEY or MINISIGN_KEY not set"; return 1
  fi
  # Both copies are staged before either is moved, so that a full disk
  # cannot leave a new signature next to the old list. Signature first,
  # then the list: agents fetch the list first and retry once on a mismatch.
  cp "$new.minisig" "$list.minisig.tmp" && cp "$new" "$list.tmp" || return 1
  mv "$list.minisig.tmp" "$list.minisig" && mv "$list.tmp" "$list" || return 1
  # shellcheck disable=SC2034 # read by the caller
  REVOCATIONS_SEQUENCE=$seq
}

# Copy a file into the repository, never replacing different content.
publish_file() {
  local src="$1" dst="$2"
  regular "$src"
  if [ -e "$dst" ]; then
    cmp -s "$src" "$dst" || die "$dst is already published with different content; publish a new level instead"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst.tmp.$$"
  mv "$dst.tmp.$$" "$dst"
}
