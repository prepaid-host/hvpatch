"""Filter `git log --format='%x00%H%n%B'` (stdin) to what `hvpatch-tool
cve-scan --contained` reads: the header line of each commit (NUL + hash) and
the lines that name a commit. Every marker the parser looks for contains
"commit", so the result is the same; a full kernel history shrinks from
about 1 GB to a few percent of that. Streams, so memory stays small.
"""
import sys

out = sys.stdout.buffer
for line in sys.stdin.buffer:
    if line.startswith(b"\0") or b"commit" in line.lower():
        out.write(line)
