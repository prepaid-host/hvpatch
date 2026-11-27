#!/usr/bin/env bash
# Keep an APT repository of the agent package next to the livepatches.
#
# usage: apt-repo.sh <repository-root> <archive-key>
#
# Looks up the latest GitHub release, and when its package is not in
# <root>/apt yet: downloads it, checks it against the release's SHA256SUMS,
# checks that GitHub holds a build attestation for exactly these bytes and
# that the package is hvpatch at the release's version, adds it to the pool
# and writes and signs the index (dists/trixie: InRelease, Release.gpg).
# Older versions stay in the pool. Nothing changes when the release is
# already there, so the index is only re-signed for a new package.
#
# <archive-key> is the armored OpenPGP secret key of the archive (no
# passphrase); it is imported into a temporary keyring that is removed
# afterwards. The public key is published as <root>/apt/hvpatch-archive.asc.
#
# Nodes:
#   curl -fsSL https://mirror.prepaid-host.io/hvpatch/apt/hvpatch-archive.asc \
#     -o /usr/share/keyrings/hvpatch-archive.asc
#   echo "deb [signed-by=/usr/share/keyrings/hvpatch-archive.asc] https://mirror.prepaid-host.io/hvpatch/apt trixie main" \
#     > /etc/apt/sources.list.d/hvpatch.list
#
# Environment:
#   GITHUB_REPO   owner/name (default prepaid-host/hvpatch)
#   GITHUB_API    API base URL (default https://api.github.com)
source "$(dirname "$0")/lib.sh"
ROOT=${1:?repository root}; KEY=${2:?archive key}
REPO=${GITHUB_REPO:-prepaid-host/hvpatch}; API=${GITHUB_API:-https://api.github.com}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad GITHUB_REPO"
require curl gpg dpkg-deb dpkg-scanpackages gzip sha256sum python3
[ -f "$KEY" ] || die "archive key $KEY not found"
APT=$ROOT/apt; DIST=$APT/dists/trixie; POOL=$APT/pool/main/h/hvpatch
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
C=(curl -fsSL --retry 2 --max-time 120)

# The latest release, from the redirect of /releases/latest (no API quota).
url=$(curl -fsS -o /dev/null -w '%{redirect_url}' --max-time 30 "https://github.com/$REPO/releases/latest") \
  || die "cannot look up the latest release"
TAG=${url##*/}
[[ $TAG =~ ^v([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]] || die "unexpected latest release '$TAG'"
VER=${BASH_REMATCH[1]}
DL="https://github.com/$REPO/releases/download/$TAG"
"${C[@]}" -o "$TMP/SHA256SUMS" "$DL/SHA256SUMS"
# One package per release: hvpatch_<version>-<debian revision>_amd64.deb.
line=$(grep -E "^[0-9a-f]{64}  hvpatch_${VER//./\\.}-[0-9]{1,3}_amd64\.deb$" "$TMP/SHA256SUMS" | head -n1) \
  || die "$TAG: no package in SHA256SUMS"
SUM=${line%% *}; DEB=${line##* }

if [ ! -f "$POOL/$DEB" ]; then
  log "apt: adding $DEB ($TAG)"
  "${C[@]}" -o "$TMP/$DEB" "$DL/$DEB"
  echo "$SUM  $TMP/$DEB" | sha256sum -c --quiet - || die "$DEB does not match SHA256SUMS"
  # SHA256SUMS comes from the same place as the package: also require a
  # build attestation from this repository's release workflow for the bytes.
  "${C[@]}" -H 'Accept: application/vnd.github+json' "$API/repos/$REPO/attestations/sha256:$SUM" -o "$TMP/att.json" \
    || die "$DEB: no build attestation on GitHub"
  python3 -I -c '
import json, sys
a = json.load(open(sys.argv[1])).get("attestations") or []
sys.exit(0 if a else 1)' "$TMP/att.json" || die "$DEB: no build attestation on GitHub"
  [ "$(dpkg-deb -f "$TMP/$DEB" Package)" = hvpatch ] || die "$DEB is not the hvpatch package"
  v=$(dpkg-deb -f "$TMP/$DEB" Version)
  [[ $v == "$VER"-* ]] || die "$DEB has version $v, not $VER"
  mkdir -p "$POOL"
  mv "$TMP/$DEB" "$POOL/$DEB.tmp" && mv "$POOL/$DEB.tmp" "$POOL/$DEB"
elif [ -s "$DIST/InRelease" ]; then
  exit 0
fi

# Index: Packages for all versions in the pool, then Release, signed.
export GNUPGHOME=$TMP/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$KEY" 2>/dev/null || die "cannot import the archive key"
FPR=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $FPR =~ ^[0-9A-F]{40}$ ]] || die "no secret key in $KEY"
NEW=$TMP/apt; mkdir -p "$NEW/main/binary-amd64"
(cd "$APT" && dpkg-scanpackages --multiversion pool /dev/null 2>/dev/null) > "$NEW/main/binary-amd64/Packages"
grep -q '^Package: hvpatch$' "$NEW/main/binary-amd64/Packages" || die "empty package index"
gzip -9nk "$NEW/main/binary-amd64/Packages"
{
  printf 'Origin: hvpatch\nLabel: hvpatch\nSuite: trixie\nCodename: trixie\n'
  printf 'Date: %s\nArchitectures: amd64\nComponents: main\n' "$(LC_ALL=C date -u -R)"
  printf 'Description: hvpatch agent for Proxmox VE 9\nSHA256:\n'
  for f in main/binary-amd64/Packages main/binary-amd64/Packages.gz; do
    printf ' %s %16d %s\n' "$(sha256sum < "$NEW/$f" | cut -d' ' -f1)" "$(stat -c %s "$NEW/$f")" "$f"
  done
} > "$NEW/Release"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA512 --clearsign -o "$NEW/InRelease" "$NEW/Release"
gpg --batch --yes --local-user "$FPR" --digest-algo SHA512 --armor --detach-sign -o "$NEW/Release.gpg" "$NEW/Release"
gpg --batch --armor --export "$FPR" > "$TMP/hvpatch-archive.asc"

# Packages first, the signed Release last: a reader sees the old index or
# the new one (dists is replaced as a whole, then the key file).
mkdir -p "$APT/dists"
rm -rf "$APT/dists/trixie.new"; cp -r "$NEW" "$APT/dists/trixie.new"
rm -rf "$APT/dists/trixie.old"; [ -d "$DIST" ] && mv "$DIST" "$APT/dists/trixie.old"
mv "$APT/dists/trixie.new" "$DIST"; rm -rf "$APT/dists/trixie.old"
cp "$TMP/hvpatch-archive.asc" "$APT/hvpatch-archive.asc.tmp" && mv "$APT/hvpatch-archive.asc.tmp" "$APT/hvpatch-archive.asc"
log "apt: index signed by $FPR ($(grep -c '^Package:' "$DIST/main/binary-amd64/Packages") package(s))"
