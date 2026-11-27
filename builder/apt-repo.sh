#!/usr/bin/env bash
# Keep an APT repository of the agent package next to the livepatches.
#
# usage: apt-repo.sh <repository-root> <archive-key>
#
# Looks up the latest GitHub release, and when its package is not in
# <root>/apt yet: downloads it, checks it against the release's SHA256SUMS,
# verifies the release's signed build provenance (hvpatch.intoto.jsonl, a
# Sigstore bundle) with cosign: signed by the release workflow
# (.github/workflows/release.yml) at exactly this tag, for exactly these
# bytes. Then checks that the package is hvpatch at the release's version,
# adds it to the pool
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
#   GITHUB_REPO   owner/name (default prepaid-host/hvpatch); the signer
#                 identity is derived from it
source "$(dirname "$0")/lib.sh"
ROOT=${1:?repository root}; KEY=${2:?archive key}
REPO=${GITHUB_REPO:-prepaid-host/hvpatch}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad GITHUB_REPO"
require curl gpg cosign dpkg-deb dpkg-scanpackages gzip sha256sum python3
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
  # SHA256SUMS comes from the same place as the package. The provenance
  # is signed with a short-lived certificate for the workflow run (Sigstore):
  # require the release workflow at this tag as the signer.
  "${C[@]}" -o "$TMP/bundles.jsonl" "$DL/hvpatch.intoto.jsonl"
  python3 -I -c '
import base64, json, sys
for line in open(sys.argv[1]):
    b = json.loads(line)
    p = json.loads(base64.b64decode(b["dsseEnvelope"]["payload"]))
    if p.get("predicateType") == "https://slsa.dev/provenance/v1":
        open(sys.argv[2], "w").write(line)
        sys.exit(0)
sys.exit(1)' "$TMP/bundles.jsonl" "$TMP/bundle.json" 2>/dev/null || die "$TAG: no build provenance in hvpatch.intoto.jsonl"
  TUF_ROOT=$TMP/tuf cosign verify-blob-attestation --new-bundle-format --bundle "$TMP/bundle.json" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity "https://github.com/$REPO/.github/workflows/release.yml@refs/tags/$TAG" \
    --type https://slsa.dev/provenance/v1 "$TMP/$DEB" >/dev/null 2>"$TMP/cosign.log" \
    || { cat "$TMP/cosign.log" >&2; die "$DEB: build provenance does not verify"; }
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
