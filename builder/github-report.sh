#!/usr/bin/env bash
# Report a pull request test build: a commit status per kernel and, unless
# nothing applied, a comment with Gate A, the patched functions and the QEMU
# result, or the end of the log of the stage that failed.
#
# usage: github-report.sh <pr-number> <head-sha> <kver> <passed|none|failed:STAGE> <out-dir>
#
# <out-dir> was written by the build container, which ran the pull request's
# patches: only regular files are read, each with a size cap, and they go
# into the comment as code blocks.
#
# Environment:
#   GITHUB_REPO        owner/name (default prepaid-host/hvpatch)
#   GITHUB_API         API base URL (default https://api.github.com)
#   GITHUB_TOKEN_FILE  token with commit status and pull request write
#                      access (default /gh/token); without it the result
#                      stays in the job log only
source "$(dirname "$0")/lib.sh"
N=${1:?pr}; SHA=${2:?sha}; KVER=${3:?kver}; RESULT=${4:?result}; OUT=${5:?out dir}
REPO=${GITHUB_REPO:-prepaid-host/hvpatch}; API=${GITHUB_API:-https://api.github.com}
TOKEN_FILE=${GITHUB_TOKEN_FILE:-/gh/token}
[[ $N =~ ^[0-9]{1,7}$ && $SHA =~ ^[0-9a-f]{40}$ && $KVER =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve$ ]] || die "bad arguments"
[[ $RESULT =~ ^(passed|none|failed:[a-z]+)$ ]] || die "bad result $RESULT"
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad GITHUB_REPO"
[ -r "$TOKEN_FILE" ] || { log "no GitHub token ($TOKEN_FILE): result not reported"; exit 0; }
require curl python3

# The build container could have replaced a directory on the way with a
# symlink (to the mounted keys, say): OUT must be its own canonical path.
# The stages run one after the other, so nothing changes it meanwhile.
{ [ -d "$OUT" ] && [ "$(readlink -f -- "$OUT")" = "$OUT" ]; } || die "$OUT is not a plain directory path"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Regular files only (see lib.sh), at most the last 64 KiB.
snippet() { if [ -f "$OUT/$1" ] && [ ! -L "$OUT/$1" ]; then tail -c 65536 "$OUT/$1"; fi; }
snippet gate-a.txt > "$TMP/gate-a"
snippet functions.txt > "$TMP/functions"
snippet qemu.ok > "$TMP/qemu"
case $RESULT in
  failed:test) snippet qemu.log | tail -n 40 > "$TMP/log" ;;
  failed:*) snippet build.log | grep -v -e 'disabling unsupported' | tail -n 40 > "$TMP/log" ;;
  *) : > "$TMP/log" ;;
esac

python3 -I - "$TMP" "$N" "$SHA" "$KVER" "$RESULT" <<'PY'
import json, os, sys
tmp, n, sha, kver, result = sys.argv[1:]
read = lambda f: open(os.path.join(tmp, f), errors="replace").read().strip()
fence = lambda t: "```\n" + t.replace("```", "'''") + "\n```"
functions = [l for l in read("functions").splitlines() if l.strip()]
if result == "passed":
    state, desc = "success", f"passed: {len(functions)} functions, Gate A and QEMU ok"
elif result == "none":
    state, desc = "success", "nothing in the catalog applies to this kernel"
else:
    state, desc = "failure", f"failed in the {result.split(':', 1)[1]} stage"
json.dump({"state": state, "context": f"hvpatch/test-build {kver}", "description": desc[:140]},
          open(os.path.join(tmp, "status.json"), "w"))
body = None
if result == "passed":
    body = (f"**Test build {kver}: passed** (`{sha[:12]}`, signed with a throwaway key, not published)\n\n"
            f"Gate A:\n{fence(read('gate-a'))}\n\nPatched functions:\n{fence(chr(10).join(functions))}\n\n"
            f"QEMU:\n{fence(read('qemu'))}\n")
elif result != "none":
    body = (f"**Test build {kver}: {desc}** (`{sha[:12]}`)\n\n"
            + (f"End of the log:\n{fence(read('log'))}\n" if read("log") else "No log in the output directory; see the job log.\n"))
if body is not None:
    json.dump({"body": body[:60000]}, open(os.path.join(tmp, "comment.json"), "w"))
PY

# The token goes to curl on stdin, not on its command line.
gh_post() {
  printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")" \
    | curl -fsS --retry 2 --max-time 30 -K - -o /dev/null -X POST \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        --data-binary "@$2" "$API/repos/$REPO/$1"
}
gh_post "statuses/$SHA" "$TMP/status.json"
if [ -f "$TMP/comment.json" ]; then gh_post "issues/$N/comments" "$TMP/comment.json"; fi
log "reported $KVER ($RESULT) to pull request #$N"
