#!/usr/bin/env bash
# Open pull requests the pipeline may test-build: "<number> <head sha>" per
# line, oldest first. Draft pull requests only with the label "test-build"
# (drafts from the CVE watcher are not buildable until someone completes
# them).
#
# usage: pr-list.sh
#
# Only pull requests whose head branch lives in GITHUB_REPO itself: a branch
# there needs write access, while anyone can open one from a fork, and the
# build stage runs the patches of the pull request. The GitHub API response
# is untrusted; only values of a strict form are passed on.
#
# All pages are read (100 per page, at most 20 pages, so 2000 pull requests).
#
# Environment:
#   GITHUB_REPO   owner/name (default prepaid-host/hvpatch)
#   GITHUB_API    API base URL (default https://api.github.com)
source "$(dirname "$0")/lib.sh"
REPO=${GITHUB_REPO:-prepaid-host/hvpatch}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad GITHUB_REPO"
require curl python3
PAGE=$(mktemp)
trap 'rm -f "$PAGE"' EXIT
MAX_PAGES=20
for ((p = 1; ; p++)); do
  if [ "$p" -gt "$MAX_PAGES" ]; then
    log "more than $((MAX_PAGES * 100)) open pull requests: the newer ones are not listed"
    break
  fi
  curl -fsS --retry 2 --max-time 30 -H 'Accept: application/vnd.github+json' -o "$PAGE" \
    "${GITHUB_API:-https://api.github.com}/repos/$REPO/pulls?state=open&sort=created&direction=asc&per_page=100&page=$p"
  python3 -I -c '
import json, re, sys
repo = sys.argv[1]
for p in json.load(sys.stdin):
    n, head = p.get("number"), p.get("head") or {}
    sha, hrepo = head.get("sha"), (head.get("repo") or {}).get("full_name")
    labels = {l.get("name") for l in p.get("labels") or [] if isinstance(l, dict)}
    if p.get("draft") is not False and "test-build" not in labels:
        continue
    if type(n) is int and 0 < n < 10**7 and isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) and hrepo == repo:
        print(n, sha)
' "$REPO" < "$PAGE"
  # A short page is the last one.
  [ "$(python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))' < "$PAGE")" -ge 100 ] || break
done
