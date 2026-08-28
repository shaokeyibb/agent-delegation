#!/usr/bin/env bash
# Dispatch a coding-agent CLI as a detached background worker on a git worktree.
#
# Usage:
#   dispatch.sh --agent <codex|cursor|codebuddy|claude> --name <run> \
#               --worktree <path> --brief <file> [--model M] [--effort E] [--read-only]
#
# The model is REQUIRED: pass --model, or set AGENT_MODEL (or AGENT_MODEL_<AGENT>).
# This skill deliberately hard-codes no model id -- ids change, and a stale default
# fails late in a way that looks like a task problem rather than a config one.
#
# Writes a sentinel quartet so a run's state is answerable from disk:
#   <runs>/<name>.before  tree snapshot at dispatch (--ignored, so vendored writes show)
#   <runs>/<name>.log     streaming transcript
#   <runs>/<name>.out     the deliverable (final message)
#   <runs>/<name>.exit    written LAST -- its existence IS the completion signal
set -uo pipefail

AGENT= NAME= WORKTREE= BRIEF= MODEL= EFFORT=medium READ_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --read-only) READ_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$AGENT" ] && [ -n "$NAME" ] && [ -n "$WORKTREE" ] && [ -n "$BRIEF" ] || {
  echo "usage: dispatch.sh --agent <codex|cursor|codebuddy|claude> --name <run> --worktree <path> --brief <file> [--model M] [--effort E] [--read-only]" >&2
  exit 2
}

case "$AGENT" in
  codex) EXE=codex ;;
  cursor) EXE=cursor-agent ;;
  codebuddy) EXE=codebuddy ;;
  claude) EXE=claude ;;
  *) echo "unsupported agent: $AGENT" >&2; exit 2 ;;
esac
command -v "$EXE" >/dev/null 2>&1 || { echo "$AGENT CLI not on PATH: $EXE" >&2; exit 2; }

if [ -z "$MODEL" ]; then
  UP=$(printf '%s' "$AGENT" | tr 'a-z' 'A-Z')
  eval "MODEL=\${AGENT_MODEL_${UP}:-\${AGENT_MODEL:-}}"
fi
[ -n "$MODEL" ] || { echo "no model: pass --model, or set AGENT_MODEL_<AGENT> / AGENT_MODEL" >&2; exit 2; }

# --- preflight ---------------------------------------------------------------
# A half-removed worktree keeps its files but loses its .git pointer, so git walks UP
# and resolves it to the MAIN repository. An existence check passes; a dispatch there
# edits the trunk. Only git's own resolution can see this.
[ -d "$WORKTREE" ] || { echo "worktree does not exist: $WORKTREE" >&2; exit 2; }
WT=$(cd "$WORKTREE" && pwd -P)
TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
[ "$TOP" = "$WT" ] || { echo "preflight FAILED: '$WT' resolves to '$TOP' -- refusing (likely a half-removed worktree)" >&2; exit 1; }
# The check above cannot catch the main repo being passed in: a repo resolves to itself.
COMMON=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
MAIN=$(dirname "$COMMON")
[ "$WT" != "$MAIN" ] || { echo "preflight FAILED: target is the MAIN repository -- refusing. Workers go in worktrees, read-only included." >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "brief not found: $BRIEF" >&2; exit 2; }
BRIEF_ABS=$(cd "$(dirname "$BRIEF")" && pwd -P)/$(basename "$BRIEF")

RUNS="${AGENT_RUNS:-$MAIN/.agent-runs/$AGENT}"
mkdir -p "$RUNS"
LOG="$RUNS/$NAME.log"; OUT="$RUNS/$NAME.out"
BEFORE="$RUNS/$NAME.before"; EXITF="$RUNS/$NAME.exit"
for f in "$LOG" "$OUT" "$BEFORE" "$EXITF"; do [ -e "$f" ] && unlink "$f"; done
# --ignored is required: plain --porcelain hides ignored paths, so a run that wrote a
# large dependency tree shows a clean status and the snapshot proves nothing.
git -C "$WT" status --porcelain --ignored > "$BEFORE"

TMP="${TMPDIR:-" + chr(47) + "tmp}"
# How the brief reaches the agent differs, and getting it wrong fails SILENTLY:
#   codex  -- stdin, so multi-line quoting never has to survive a shell.
#   others -- measured: passing a large brief as an argv element makes the CLI return
#             immediately with a few-byte log and exit code 0, which a monitor reports
#             as DONE. So they get the PATH and read the file themselves.
POINTER="Read the file $BRIEF_ABS -- it is your complete brief for this run. Follow every requirement in it. When done, answer in the form its delivery section asks for; your final message IS the deliverable."

RUNNER="$TMP/agent-runner-$AGENT-$NAME.sh"
{
  echo '#!/usr/bin/env bash'
  echo "cd '$WT' || exit 1"
  case "$AGENT" in
    codex)
      echo "codex exec -m '$MODEL' -c model_reasoning_effort='\"$EFFORT\"' --dangerously-bypass-approvals-and-sandbox -o '$OUT' - < '$BRIEF_ABS' > '$LOG' 2>&1"
      ;;
    cursor)
      # Workspace Trust is required even for the read-only plan lane; --trust grants no exec.
      if [ "$READ_ONLY" = 1 ]; then MODE="--plan --trust"; else MODE="--force"; fi
      echo "cursor-agent -p --output-format text --model '$MODEL' $MODE '$POINTER' > '$LOG' 2>&1"
      ;;
    codebuddy)
      if [ "$READ_ONLY" = 1 ]; then PERM=""; else PERM="-y"; fi
      echo "codebuddy -p --output-format text --model '$MODEL' $PERM '$POINTER' > '$LOG' 2>&1"
      ;;
    claude)
      if [ "$READ_ONLY" = 1 ]; then PERM=""; else PERM="--dangerously-skip-permissions"; fi
      echo "claude -p --model '$MODEL' $PERM '$POINTER' > '$LOG' 2>&1"
      ;;
  esac
  echo "code=\$?"
  [ "$AGENT" = codex ] || echo "[ -f '$LOG' ] && tail -n 400 '$LOG' > '$OUT'"
  # .exit is written LAST on purpose: its existence is the completion signal.
  echo "printf '%s' \"\$code\" > '$EXITF'"
} > "$RUNNER"
chmod +x "$RUNNER"
nohup "$RUNNER" >/dev/null 2>&1 &
PID=$!

echo "preflight ok: $WT"
if [ "$READ_ONLY" = 1 ]; then MODE_LABEL=readonly; else MODE_LABEL=write; fi
echo "$NAME PID=$PID agent=$AGENT worktree=$(basename "$WT") model=$MODEL mode=$MODE_LABEL"
echo "sentinel: $RUNS/$NAME.{log,out,before,exit}"
