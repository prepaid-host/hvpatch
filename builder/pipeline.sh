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
#   publish  sign the manifest and upload (publish.sh + rsync); only the
#            manifest key and the upload key
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
#   KEEP_TREES      kernel trees kept as build cache (default 3); older ones
#                   are removed before a build
#   MODULE_KEY, MODULE_CERT, MANIFEST_KEY   as in sign-module.sh / publish.sh
#   SERIES, NEWEST  passed to plan.sh
#   BUILDER_IMAGE   recorded in the source bundle
#   TRUST           volume for the plan and checksums (default /trusted)
#   POD_NAME        owner of the run lock (default the host name)
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
# does not cover jobs created by hand. prepare takes the lock in RUN; it is
# released when publish ends or a stage fails. A lock older than
# LOCK_STALE_MIN minutes (default 420, longer than the job deadline) is left
# over from a killed pod and is taken over.
ME=${POD_NAME:-$(hostname)}
LOCK=$RUN/lock
release_lock() {
  if [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$ME" ]; then rm -rf "$LOCK"; fi
  return 0
}
release_on_error() {
  local rc=$?
  [ "$rc" -eq 0 ] || release_lock
  exit "$rc"
}

if [ "$STAGE" = prepare ]; then
  mkdir -p "$RUN" "$STATE"
  rm -f "$TRUST/plan"
  if ! mkdir "$LOCK" 2>/dev/null; then
    OWNER=$(cat "$LOCK/owner" 2>/dev/null || echo unknown)
    if [ -z "$(find "$LOCK" -maxdepth 0 -mmin +"${LOCK_STALE_MIN:-420}")" ]; then
      log "another run ($OWNER) is active; nothing to do"
      exit 0
    fi
    log "taking over the stale lock of $OWNER"
    rm -rf "$LOCK"; mkdir "$LOCK"
  fi
  echo "$ME" > "$LOCK/owner"
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
  if [ -s "$TRUST/plan" ]; then log "plan: $(cat "$TRUST/plan")"; else log "nothing to build"; fi
  exit 0
fi

if [ "$STAGE" = publish ]; then trap release_lock EXIT; else trap release_on_error EXIT; fi
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
    # Build cache (this stage has no keys; /work/build is written by earlier
    # builds): keep the newest KEEP_TREES kernel trees, always the planned one.
    mkdir -p "$W"; touch "$W"
    find "$WORK/build" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- \
      | tail -n +"$(( ${KEEP_TREES:-3} + 1 ))" | while read -r d; do
      [ "$d" = "$W" ] && continue
      [ -d "$d/src" ] && ! [ -L "$d/src" ] && { log "removing cached kernel tree $d/src"; rm -rf --one-file-system "$d/src"; }
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
    # build.sh exits 0 without a module when nothing applies to this kernel.
    ( cd "$SRC" && CATALOG="$SRC/catalog" AUTO_LOCK=1 "$HERE/build.sh" "$KVER" "$LEVEL" "$W" ) \
      || { echo build > "$RUN/failed"; log "build failed for $KVER level $LEVEL"; exit 0; }
    if ! compgen -G "$W/out/klp_*.ko" >/dev/null; then
      touch "$RUN/none"
      log "nothing to livepatch for $KVER at $COMMIT"
    fi
    ;;
  sign)
    [ -e "$RUN/none" ] && exit 0
    verify_shipped
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
    if [ -e "$RUN/none" ] && [ ! -e "$RUN/failed" ]; then
      touch "$STATE/$KVER@$COMMIT.none"
      exit 0
    fi
    if [ -e "$RUN/failed" ]; then
      touch "$STATE/$KVER@$COMMIT.failed"
      die "$(cat "$RUN/failed") failed for $KVER level $LEVEL at $COMMIT; not retried until the catalog changes"
    fi
    # The published copy may be older than the remote if another publisher
    # ran meanwhile: fetch again right before publishing.
    verify_shipped
    rsync_remote "$REPO_REMOTE" "$PUB/"
    "$HERE/publish.sh" "$W/out" "$PUB"
    rsync_remote "$PUB/" "$REPO_REMOTE"
    log "published $KVER level $LEVEL"
    ;;
  *) die "unknown stage $STAGE" ;;
esac
