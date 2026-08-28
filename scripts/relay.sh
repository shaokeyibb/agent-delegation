#!/usr/bin/env bash
# Resume a finished run in its own session, with a new brief.
#
# When a read-only reviewer finishes and its findings ARE the follow-up work, resume that
# same session rather than briefing a fresh one: it already holds the whole branch in
# context. The invariant this preserves -- whoever changed the code is never the one who
# signs off on it -- still holds, because the review was written and harvested BEFORE the
# run gained write access. Relaying AGAIN to bless that fix is not sound; dispatch fresh.
#
# A relay that cannot find the session id MUST fail loudly. Starting a fresh session
# instead looks identical from the outside while carrying none of the context that
# justified relaying at all.
#
# cursor-agent has no session-resume lane here; dispatch fresh and restate the context.
set -uo pipefail

AGENT= FROM= NAME= WORKTREE= BRIEF= MODEL= EFFORT=medium
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$AGENT" ] && [ -n "$FROM" ] && [ -n "$NAME" ] && [ -n "$WORKTREE" ] && [ -n "$BRIEF" ] || {
  echo "usage: relay.sh --agent <codex|codebuddy|claude> --from <prev-run> --name <run> --worktree <path> --brief <file> [--model M]" >&2
  exit 2
}
case "$AGENT" in
  codex|codebuddy|claude) ;;
  cursor) echo "cursor has no resume lane: dispatch a fresh run instead" >&2; exit 2 ;;
  *) echo "unsupported agent: $AGENT" >&2; exit 2 ;;
esac

if [ -z "$MODEL" ]; then
  UP=$(printf '%s' "$AGENT" | tr 'a-z' 'A-Z')
  eval "MODEL=\${AGENT_MODEL_${UP}:-\${AGENT_MODEL:-}}"
fi
[ -n "$MODEL" ] || { echo "no model: pass --model, or set AGENT_MODEL_<AGENT> / AGENT_MODEL" >&2; exit 2; }

[ -d "$WORKTREE" ] || { echo "worktree does not exist: $WORKTREE" >&2; exit 2; }
WT=$(cd "$WORKTREE" && pwd -P)
TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
[ "$TOP" = "$WT" ] || { echo "preflight FAILED: '$WT' resolves to '$TOP' -- refusing" >&2; exit 1; }
COMMON=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
MAIN=$(dirname "$COMMON")
[ "$WT" != "$MAIN" ] || { echo "preflight FAILED: target is the MAIN repository -- refusing" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "brief not found: $BRIEF" >&2; exit 2; }
BRIEF_ABS=$(cd "$(dirname "$BRIEF")" && pwd -P)/$(basename "$BRIEF")

RUNS="${AGENT_RUNS:-$MAIN/.agent-runs/$AGENT}"
FROM_LOG="$RUNS/$FROM.log"
[ -f "$FROM_LOG" ] || { echo "no transcript for the previous run: $FROM_LOG" >&2; exit 2; }

# Session id shapes differ per CLI; a miss must throw rather than silently start fresh.
SID=$(grep -oiE 'session[_ -]?id["'"'"':[:space:]]+[0-9a-f-]{16,}' "$FROM_LOG" | head -1 | grep -oE '[0-9a-f-]{16,}' | head -1 || true)
[ -n "$SID" ] || SID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$FROM_LOG" | head -1 || true)
[ -n "$SID" ] || { echo "relay FAILED: no session id in $FROM.log -- refusing to degrade into a fresh session (that discards the entire reason to relay)" >&2; exit 1; }

mkdir -p "$RUNS"
LOG="$RUNS/$NAME.log"; OUT="$RUNS/$NAME.out"
BEFORE="$RUNS/$NAME.before"; EXITF="$RUNS/$NAME.exit"
for f in "$LOG" "$OUT" "$BEFORE" "$EXITF"; do [ -e "$f" ] && unlink "$f"; done
git -C "$WT" status --porcelain --ignored > "$BEFORE"

TMP="${TMPDIR:-/tmp}"
POINTER="Read the file $BRIEF_ABS -- it is your complete brief for this run. Follow every requirement in it."
RUNNER="$TMP/agent-relay-$AGENT-$NAME.sh"
{
  echo '#!/usr/bin/env bash'
  echo "cd '$WT' || exit 1"
  case "$AGENT" in
    codex)     echo "codex exec resume '$SID' -m '$MODEL' -c model_reasoning_effort='\"$EFFORT\"' --dangerously-bypass-approvals-and-sandbox -o '$OUT' - < '$BRIEF_ABS' > '$LOG' 2>&1" ;;
    codebuddy) echo "codebuddy -p --output-format text --model '$MODEL' -y --resume '$SID' '$POINTER' > '$LOG' 2>&1" ;;
    claude)    echo "claude -p --model '$MODEL' --dangerously-skip-permissions -r '$SID' '$POINTER' > '$LOG' 2>&1" ;;
  esac
  echo "code=\$?"
  [ "$AGENT" = codex ] || echo "[ -f '$LOG' ] && tail -n 400 '$LOG' > '$OUT'"
  echo "printf '%s' \"\$code\" > '$EXITF'"
} > "$RUNNER"
chmod +x "$RUNNER"
nohup "$RUNNER" >/dev/null 2>&1 &
echo "preflight ok: $WT (relay $SID from $FROM)"
echo "$NAME PID=$! agent=$AGENT worktree=$(basename "$WT") relayed=$SID"
