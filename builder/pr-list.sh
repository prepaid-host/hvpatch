#!/usr/bin/env bash
# Open pull requests the pipeline may test-build: "<number> <head sha>" per
# line, oldest first.
#
# usage: pr-list.sh
#
# Only pull requests whose head branch lives in GITHUB_REPO itself: a branch
# there needs write access, while anyone can open one from a fork, and the
# build stage runs the patches of the pull request. The GitHub API response
# is untrusted; only values of a strict form are passed on.
#
# Environment:
#   GITHUB_REPO   owner/name (default prepaid-host/hvpatch)
#   GITHUB_API    API base URL (default https://api.github.com)
source "$(dirname "$0")/lib.sh"
REPO=${GITHUB_REPO:-prepaid-host/hvpatch}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad GITHUB_REPO"
require curl python3
curl -fsS --retry 2 --max-time 30 -H 'Accept: application/vnd.github+json' \
  "${GITHUB_API:-https://api.github.com}/repos/$REPO/pulls?state=open&sort=created&direction=asc&per_page=50" \
  | python3 -I -c '
import json, re, sys
repo = sys.argv[1]
for p in json.load(sys.stdin):
    n, head = p.get("number"), p.get("head") or {}
    sha, hrepo = head.get("sha"), (head.get("repo") or {}).get("full_name")
    if type(n) is int and 0 < n < 10**7 and isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) and hrepo == repo:
        print(n, sha)
' "$REPO"
