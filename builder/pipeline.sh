#!/usr/bin/env bash
# One stage of the unattended pipeline (Kubernetes CronJob, see
# docs/pipeline.md). Every stage runs in its own container of the same pod,
# one after the other, sharing the volume WORK:
#
#   prepare  clone/update the repository, fetch the published repository,
#            decide what to build (plan.sh)
#   fetch    shipped kernel packages (fetch-shipped.sh)
#   build    klp-build, Gate A, source bundle (build.sh); no keys
#   sign     module signature (sign-module.sh); only the module key
#   test     QEMU stage (qemu-test.sh); no keys
#   publish  sign the manifest and upload (publish.sh + rsync), then
#            promote and renew (rings.sh); only the manifest key and the
#            upload key
#
# Pull request test builds (PR_TESTS=1): when main has nothing to build,
# prepare takes the oldest open pull request that changes catalog/ and has a
# kernel left to test (pr-list.sh, same-repository branches only), and the
# stages build it like main, with three differences: lint lets
# reviewed_by: ["pending-review"] pass, sign uses a throwaway key instead of
# the module key, and publish uploads nothing but reports the result to the
# pull request (github-report.sh). Markers live in STATE/pr.
#
# The build container of a pull request build can write all of WORK/build
# (trees, objects, cached original builds, source tarballs of every kernel),
# and main builds would otherwise reuse it. prepare marks WORK/build tainted
# (LOCK_DIR/tainted, which the build container does not mount) before the
# pull request runs, and the next main run removes every kernel directory.
# The commit list for cve-watch.sh comes from main builds only, made fresh
# each time and kept in STATE/commits.
#
# usage: pipeline.sh <stage>
#
# A failed stage records it and later stages skip; publish then marks the
# kernel as failed for this catalog commit (plan.sh does not retry it until
# the catalog changes) and exits non-zero, so the job shows as failed.
#
# The build stage runs kernel Makefiles and catalog patches. Mount only what
# it needs, and the repository checkout read-only (see the CronJob). The
# plan and the checksums of the shipped artifacts live in TRUST, which the
# build container does not get; sign, test and publish check the shipped
# artifacts against them, because Gate A and the QEMU stage rely on them.
#
# Environment:
#   WORK            shared volume (default /work)
#   GIT_URL         repository to build from (default the public GitHub one)
#   GIT_REF         branch or tag (default main)
#   REPO_REMOTE     rsync target of the published repository, e.g.
#                   hvpatch@mirror.mirror.svc:   (rrsync on the mirror)
#   SSH_DIR         id_ed25519 + known_hosts for REPO_REMOTE (default /ssh)
#   SSH_PORT        port of REPO_REMOTE (default 22)
#   KEEP_TREES      kernel trees kept as build cache (default: kernels
#                   served, words in SERIES times NEWEST, at least 3); older
#                   ones are removed before a build
#   MODULE_KEY, MODULE_CERT, MANIFEST_KEY   as in sign-module.sh / publish.sh
#   SERIES, NEWEST  passed to plan.sh; the fetch stage reads them too (set
#                   them for every stage; defaults 7.0 7.3 and 2)
#   BUILDER_IMAGE   recorded in the source bundle
#   TRUST           volume for the plan and checksums (default /trusted)
#   MANIFEST_PUB    public manifest key for rings.sh (default the checkout's
#                   project-keys/manifest.pub)
#   HOLDS           promotion holds (default the checkout's rings/holds)
#   RING_MAINTENANCE, PROMOTE, PROMOTE_EARLY_DAYS, PROMOTE_STABLE_DAYS,
#   RENEW_DAYS, VALID_DAYS   as in rings.sh
#   LOCK_DIR        directory for the run lock (default WORK/lock); not
#                   mounted into the build container
#   POD_NAME        owner of the run lock (default the host name)
#   PR_TESTS        1: test-build pull requests when main is idle (default 0)
#   GITHUB_REPO     owner/name for pull requests (default prepaid-host/hvpatch)
#   GITHUB_TOKEN_FILE  token for commit statuses and comments (publish only)
#   LOCK_STALE_MIN  age in minutes after which a lock is taken over (420)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
STAGE=${1:?usage: pipeline.sh <stage>}
WORK=${WORK:-/work}
RUN=$WORK/run; SRC=$WORK/hvpatch; PUB=$WORK/published; STATE=$WORK/state
TRUST=${TRUST:-/trusted}

rsync_remote() {
  rsync -rlt --delete --delay-updates --safe-links --timeout=300 --exclude=/stats.json \
    -e "ssh -p ${SSH_PORT:-22} -i $SSH_DIR/id_ed25519 -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20" \
    "$@"
}
SSH_DIR=${SSH_DIR:-/ssh}

# One run at a time: the volume is shared, and the CronJob's Forbid policy
# does not cover jobs created by hand. prepare takes the lock; it is released
# when publish ends or a stage fails. LOCK_DIR must not be mounted into the
# build container (it could otherwise hold the lock forever). The lock records
# its owner and when it was taken; a lock older than LOCK_STALE_MIN minutes
# (default 420, longer than the job deadline), or dated in the future, is left
# over from a killed pod and is taken over.
ME=${POD_NAME:-$(hostname)}
LOCK=${LOCK_DIR:-$WORK/lock}/run
TAINTED=${LOCK_DIR:-$WORK/lock}/tainted
release_lock() {
  local owner _
  read -r owner _ < "$LOCK/owner" 2>/dev/null || return 0
  if [ "$owner" = "$ME" ]; then rm -rf "$LOCK"; fi
  return 0
}
release_on_error() {
  local rc=$?
  [ "$rc" -eq 0 ] || release_lock
  exit "$rc"
}

if [ "$STAGE" = prepare ]; then
  mkdir -p "$RUN" "$STATE"
  rm -f "$TRUST/plan" "$TRUST/pr"
  mkdir -p "$(dirname "$LOCK")"
  NOW=$(date +%s)
  if ! mkdir "$LOCK" 2>/dev/null; then
    OWNER=unknown; SINCE=0
    read -r OWNER SINCE < "$LOCK/owner" 2>/dev/null || true
    [[ "$SINCE" =~ ^[0-9]{1,12}$ ]] || SINCE=0
    AGE=$(( (NOW - SINCE) / 60 ))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "${LOCK_STALE_MIN:-420}" ]; then
      log "another run (${OWNER//[^A-Za-z0-9._-]/?}, ${AGE} min) is active; nothing to do"
      exit 0
    fi
    log "taking over the stale lock of ${OWNER//[^A-Za-z0-9._-]/?} (${AGE} min)"
    rm -rf "$LOCK"; mkdir "$LOCK"
  fi
  echo "$ME $NOW" > "$LOCK/owner"
  trap release_on_error EXIT
  rm -f "$RUN/failed" "$RUN/none"
  G=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false)
  if [ -d "$SRC/.git" ]; then
    "${G[@]}" -C "$SRC" fetch -q origin "${GIT_REF:-main}"
    "${G[@]}" -C "$SRC" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
    "${G[@]}" -C "$SRC" clean -fdxq
  else
    "${G[@]}" clone -q --branch "${GIT_REF:-main}" "${GIT_URL:-https://github.com/prepaid-host/hvpatch.git}" "$SRC"
  fi
  log "repository at $(git -C "$SRC" rev-parse --short HEAD)"
  mkdir -p "$PUB"
  rsync_remote "${REPO_REMOTE:?REPO_REMOTE not set}" "$PUB/"
  CATALOG="$SRC/catalog" STATE="$STATE" "$HERE/plan.sh" "$PUB" > "$TRUST/plan"
  git -C "$SRC" rev-parse HEAD > "$TRUST/commit"
  if [ ! -s "$TRUST/plan" ] && [ "${PR_TESTS:-0}" = 1 ]; then
    MAIN=$(git -C "$SRC" rev-parse HEAD)
    # Markers of finished pull request builds; publish creates the directory
    # (STATE is read-only here).
    PRSTATE=$STATE/pr
    [ -d "$PRSTATE" ] || PRSTATE=$(mktemp -d)
    PRS=$("$HERE/pr-list.sh") || { log "listing pull requests failed; no test builds this run"; PRS=; }
    while read -r N SHA; do
      [ -n "$N" ] || continue
      "${G[@]}" -C "$SRC" fetch -q origin "+refs/pull/$N/head" || continue
      # Moved since the listing: the next run sees the new head.
      [ "$(git -C "$SRC" rev-parse FETCH_HEAD)" = "$SHA" ] || continue
      # Only catalog changes: the builder itself comes from the image.
      if git -C "$SRC" diff --quiet "$MAIN...$SHA" -- catalog; then continue; fi
      "${G[@]}" -C "$SRC" -c advice.detachedHead=false checkout -q --force "$SHA"
      "${G[@]}" -C "$SRC" clean -fdxq
      CATALOG="$SRC/catalog" STATE="$PRSTATE" "$HERE/plan.sh" "$PUB" > "$TRUST/plan"
      if [ -s "$TRUST/plan" ]; then
        echo "$N $SHA" > "$TRUST/pr"
        echo "$SHA" > "$TRUST/commit"
        # Before anything of the pull request runs: main must not reuse
        # anything its build container can write.
        mkdir -p "$TAINTED"; touch "$TAINTED/build"
        log "test build for pull request #$N at ${SHA:0:12}"
        break
      fi
    done <<< "$PRS"
    if [ ! -s "$TRUST/pr" ]; then
      : > "$TRUST/plan"
      "${G[@]}" -C "$SRC" -c advice.detachedHead=false checkout -q --force "$MAIN"
      "${G[@]}" -C "$SRC" clean -fdxq
    fi
  fi
  if [ -s "$TRUST/plan" ]; then log "plan: $(cat "$TRUST/plan")"; else log "nothing to build"; fi
  exit 0
fi

# Pull request test build: "<number> <sha>", written by prepare.
PR_NUM=; PR_SHA=
if [ -s "$TRUST/pr" ]; then
  read -r PR_NUM PR_SHA < "$TRUST/pr"
  [[ $PR_NUM =~ ^[0-9]{1,7}$ && $PR_SHA =~ ^[0-9a-f]{40}$ ]] || die "unexpected $TRUST/pr"
fi

# Promotions and renewals (rings.sh) run in every publish, with or without
# a build. PROMOTE=0 only renews; RING_MAINTENANCE=0 turns both off. Their
# state (STATE/rings) guards against rollbacks on the web server: STATE must
# not be mounted into the build container, like TRUST and LOCK_DIR.
# The commit list of a main build, for cve-watch.sh (see the build stage).
keep_commits() {
  local c="$WORK/build/$1/commits.txt"
  if [ -f "$c" ] && [ ! -L "$c" ]; then
    mkdir -p "$STATE/commits"
    cp -- "$c" "$STATE/commits/$1.txt.tmp" && mv "$STATE/commits/$1.txt.tmp" "$STATE/commits/$1.txt"
  fi
  return 0
}
ring_maintenance() {
  [ "${RING_MAINTENANCE:-1}" = 1 ] || return 0
  "$HERE/rings.sh" "$PUB" "${MANIFEST_PUB:-$SRC/project-keys/manifest.pub}" "$STATE/rings" "${HOLDS:-$SRC/rings/holds}"
}
if [ "$STAGE" = publish ]; then trap release_lock EXIT; else trap release_on_error EXIT; fi
if [ "$STAGE" = publish ] && [ -n "$PR_NUM" ]; then
  # Nothing of a pull request build is uploaded or signed for real.
  read -r KVER _ < "$TRUST/plan"
  if [ -e "$RUN/failed" ]; then RESULT="failed:$(cat "$RUN/failed")"
  elif [ -e "$RUN/none" ]; then RESULT=none
  else RESULT=passed; fi
  mkdir -p "$STATE/pr"
  case $RESULT in failed:*) touch "$STATE/pr/$KVER@$PR_SHA.failed" ;; *) touch "$STATE/pr/$KVER@$PR_SHA.none" ;; esac
  log "pull request #$PR_NUM, $KVER: $RESULT"
  "$HERE/github-report.sh" "$PR_NUM" "$PR_SHA" "$KVER" "$RESULT" "$WORK/build/$KVER/out" \
    || log "reporting to the pull request failed"
  exit 0
fi
if [ "$STAGE" = publish ] && { [ ! -s "$TRUST/plan" ] || { [ -e "$RUN/none" ] && [ ! -e "$RUN/failed" ]; }; }; then
  if [ -s "$TRUST/plan" ]; then
    read -r KVER _ < "$TRUST/plan"
    touch "$STATE/$KVER@$(cat "$TRUST/commit").none"
    keep_commits "$KVER"
  fi
  [ "${RING_MAINTENANCE:-1}" = 1 ] || exit 0
  rsync_remote "${REPO_REMOTE:?REPO_REMOTE not set}" "$PUB/"
  rc=0; ring_maintenance || rc=$?
  rsync_remote "$PUB/" "$REPO_REMOTE"
  exit "$rc"
fi
[ -s "$TRUST/plan" ] || { log "$STAGE: nothing planned"; exit 0; }
read -r KVER LEVEL PREV < "$TRUST/plan"
W=$WORK/build/$KVER
COMMIT=$(cat "$TRUST/commit")
# Files Gate A and the QEMU stage read from the shipped packages.
SHIPPED_FILES=(config System.map Module.symvers build-id vmlinuz modules)
verify_shipped() {
  ( cd "$W/shipped" && find -L "${SHIPPED_FILES[@]}" -type f | LC_ALL=C sort | cmp -s - "$TRUST/shipped.list" \
      && sha256sum --quiet -c "$TRUST/shipped.sha256" ) \
    || die "the shipped artifacts of $KVER changed after the fetch stage"
}
if [ -e "$RUN/failed" ] && [ "$STAGE" != publish ]; then
  log "$STAGE: skipped, $(cat "$RUN/failed") failed"
  exit 0
fi

run_stage() {
  if ! "$@"; then
    echo "$STAGE" > "$RUN/failed"
    log "$STAGE failed for $KVER level $LEVEL"
  fi
  exit 0
}

case "$STAGE" in
  fetch)
    # A pull request build ran since the last main build: start main from
    # scratch (fresh trees and original builds, no cached tarballs), for
    # every kernel, since its build container could write all of them.
    # Any marker counts, whatever its name.
    if [ -z "$PR_NUM" ] && [ -n "$(ls -A "$TAINTED" 2>/dev/null)" ]; then
      log "a pull request test build ran: removing all kernel build directories"
      find "$WORK/build" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system {} +
      find "$TAINTED" -mindepth 1 -delete
    fi
    # Build cache (this stage has no keys; /work/build is written by earlier
    # builds): keep the newest KEEP_TREES kernel trees, always the planned one.
    mkdir -p "$W"; touch "$W"
    SERVED=$(( $(wc -w <<< "${SERIES:-7.0 7.3}") * ${NEWEST:-2} ))
    KEEP=${KEEP_TREES:-$(( SERVED < 3 ? 3 : SERVED ))}
    find "$WORK/build" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- \
      | tail -n +"$(( KEEP + 1 ))" | while read -r d; do
      [ "$d" = "$W" ] && continue
      # An if, not &&: a false test as the last command would end the loop
      # (and with pipefail the stage) with a failure.
      if [ -d "$d/src" ] && [ ! -L "$d/src" ]; then
        log "removing cached kernel tree $d/src"
        rm -rf --one-file-system "$d/src"
      fi
    done
    # Always fresh: a cached copy could have been changed by an earlier build.
    rm -rf "$W/shipped"; mkdir -p "$W/shipped"
    if ! "$HERE/fetch-shipped.sh" "$KVER" "$W/shipped"; then echo fetch > "$RUN/failed"; exit 0; fi
    ( cd "$W/shipped" && find -L "${SHIPPED_FILES[@]}" -type f | LC_ALL=C sort > "$TRUST/shipped.list" \
      && tr '\n' '\0' < "$TRUST/shipped.list" | xargs -0 sha256sum > "$TRUST/shipped.sha256" )
    log "shipped artifacts of $KVER: $(wc -l < "$TRUST/shipped.list") files recorded"
    ;;
  build)
    mkdir -p "$W/src" "$W/out" "$W/cache"
    # A pull request may still carry the review placeholder (see lint).
    if [ -n "$PR_NUM" ]; then export HVPATCH_ALLOW_PENDING_REVIEW=1; fi
    # build.sh exits 0 without a module when nothing applies to this kernel.
    ( cd "$SRC" && CATALOG="$SRC/catalog" AUTO_LOCK=1 "$HERE/build.sh" "$KVER" "$LEVEL" "$W" ) \
      || { echo build > "$RUN/failed"; log "build failed for $KVER level $LEVEL"; exit 0; }
    # Commit list of the kernel tree for cve-watch.sh (7.0 backports fixes
    # without changing the upstream version). Made here, where the tree's
    # git config is the build's own business, and only in main builds;
    # publish copies it to STATE/commits, which the watcher reads.
    rm -f "$W/commits.txt"
    if [ -z "$PR_NUM" ] && [ -d "$W/src/.git" ]; then
      git -C "$W/src" log --format='%x00%H%n%B' HEAD | python3 -I "$HERE/commit-refs.py" > "$W/commits.txt.tmp" \
        && mv "$W/commits.txt.tmp" "$W/commits.txt"
    fi
    if ! compgen -G "$W/out/klp_*.ko" >/dev/null; then
      touch "$RUN/none"
      log "nothing to livepatch for $KVER at $COMMIT"
    fi
    ;;
  sign)
    [ -e "$RUN/none" ] && exit 0
    verify_shipped
    if [ -n "$PR_NUM" ]; then
      # Unreviewed code never gets the real module key: a throwaway key and
      # certificate, gone with the container.
      K=$(mktemp -d)
      openssl req -new -x509 -nodes -batch -utf8 -sha256 -days 1 -newkey rsa:2048 \
        -subj "/CN=hvpatch pull request test build (untrusted)" \
        -keyout "$K/key.pem" -outform DER -out "$K/cert.der" 2>/dev/null
      export MODULE_KEY=$K/key.pem MODULE_CERT=$K/cert.der
    fi
    run_stage "$HERE/sign-module.sh" "$KVER" "$LEVEL" "$W"
    ;;
  test)
    [ -e "$RUN/none" ] && exit 0
    verify_shipped
    P=()
    [ "$PREV" != - ] && P=("$PREV")
    run_stage env CATALOG="$SRC/catalog" "$HERE/qemu-test.sh" "$KVER" "$W" ${P[@]+"${P[@]}"}
    ;;
  publish)
    # The published copy may be older than the remote if another publisher
    # ran meanwhile: fetch again right before changing it.
    rsync_remote "$REPO_REMOTE" "$PUB/"
    if [ -e "$RUN/failed" ]; then
      touch "$STATE/$KVER@$COMMIT.failed"
      ring_maintenance || true
      rsync_remote "$PUB/" "$REPO_REMOTE"
      die "$(cat "$RUN/failed") failed for $KVER level $LEVEL at $COMMIT; not retried until the catalog changes"
    fi
    verify_shipped
    keep_commits "$KVER"
    "$HERE/publish.sh" "$W/out" "$PUB"
    rc=0; ring_maintenance || rc=$?
    rsync_remote "$PUB/" "$REPO_REMOTE"
    log "published $KVER level $LEVEL"
    exit "$rc"
    ;;
  *) die "unknown stage $STAGE" ;;
esac
