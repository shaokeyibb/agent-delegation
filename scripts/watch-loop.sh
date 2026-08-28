#!/usr/bin/env bash
# Emit only STATE CHANGES, so one persistent monitor covers every run including ones
# dispatched later. Runs already finished at startup are baselined, not replayed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -A seen
while IFS= read -r line; do seen["$line"]=1; done < <("$HERE/watch.sh" | grep '^DONE ' || true)
while true; do
  while IFS= read -r line; do
    case "$line" in
      DONE*) [ -n "${seen[$line]:-}" ] || { echo "$line"; seen["$line"]=1; } ;;
    esac
  done < <("$HERE/watch.sh" || true)
  sleep "${AGENT_WATCH_INTERVAL:-20}"
done
