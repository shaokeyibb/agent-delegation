#!/usr/bin/env bash
# Report one state per run across every agent sentinel directory.
#
# The case this exists to catch: a run that died without writing .exit. A rate limit,
# an auth failure, or a dropped stream ends the process with the sentinel incomplete,
# and anything waiting on .exit waits forever.
set -uo pipefail
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
MAIN="${AGENT_MAIN_REPO:-$(dirname "$COMMON")}"
BASE="${AGENT_RUNS_ROOT:-$MAIN/.agent-runs}"
for dir in "$BASE"/*; do
  [ -d "$dir" ] || continue
  agent=$(basename "$dir")
  for log in "$dir"/*.log; do
    [ -e "$log" ] || continue
    name=$(basename "$log" .log)
    exitf="$dir/$name.exit"; outf="$dir/$name.out"
    if [ -f "$exitf" ]; then
      code=$(tr -d '[:space:]' < "$exitf")
      if [ ! -s "$outf" ]; then
        # An auth failure writes a COMPLETE sentinel, so a monitor says DONE, not DEAD.
        # The only signal is the missing deliverable -- read the log before retrying.
        if grep -qiE 'invalid[_ ]api[_ ]key|401 unauthorized' "$log" 2>/dev/null; then
          echo "DONE $agent/$name exit=$code result=MISSING cause=AUTH"
        else
          echo "DONE $agent/$name exit=$code result=MISSING"
        fi
      else
        echo "DONE $agent/$name exit=$code result=$(wc -c < "$outf" | tr -d ' ')"
      fi
    else
      echo "RUNNING $agent/$name log=$(wc -c < "$log" | tr -d ' ')"
    fi
  done
done
