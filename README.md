# agent-delegation

*[English](README.md) · [简体中文](README.zh-CN.md)*

**A skill that teaches your coding agent to delegate long work to other agent CLIs — and to
prove, afterwards, what they actually did.**

Your agent already knows how to write code. What it does not know is how to hand three hours
of work to `codex` or `cursor-agent`, walk away, and come back able to tell the difference
between *finished*, *finished but produced nothing*, *died on credentials*, and *lying about
a test it never ran*. This skill is that knowledge, packaged.

Install it and your agent gains a working method: isolate the work in a git worktree,
dispatch a detached CLI worker, watch a four-file sentinel, and refuse to believe any claim
it can check itself.

## Install

```bash
npx skills add shaokeyibb/agent-delegation
```

Useful flags: `-g` installs to your user directory instead of the current project,
`-a claude-code` (repeatable) targets specific agents, `-y` skips confirmation.

```bash
npx skills add shaokeyibb/agent-delegation -g -a claude-code -y
```

## Usage

There is nothing to run. Skills load themselves when they are relevant — just talk to your
agent about the work, and it will reach for this one:

> "This refactor will take hours. Farm it out to codex on a worktree and check on it later."

> "The codex run says DONE but I don't see any output. What happened?"

> "The reviewer found three real bugs. Have it fix them instead of writing a new brief."

> "It claims it added four locks. Verify that before we merge."

Each of those lands in a different part of the skill: dispatching, diagnosing a run that
reported success while producing nothing, relaying a reviewer into its own fix, and forcing
a claimed test to be broken and shown going red.

### Configuration

Set the model before your agent dispatches anything — **the skill hard-codes none**, because
model ids change and a stale default fails late in a way that looks like a task problem
rather than a config one.

| variable | meaning |
|---|---|
| `AGENT_MODEL` | model id for every lane |
| `AGENT_MODEL_<AGENT>` | per-lane override, e.g. `AGENT_MODEL_CODEX` |
| `AGENT_RUNS` | where the sentinel lives (default `<repo>/.agent-runs/<agent>/`) |
| `AGENT_WATCH_INTERVAL` | poll seconds for the watcher (default 20) |

The bundled scripts are plain bash and PowerShell — your agent runs them, but you can too,
with no agent host at all.

## What your agent learns

**Four CLIs, one interface.** `codex`, `cursor-agent`, `codebuddy`, and `claude` differ in
ways that fail *silently* if you get them wrong — only one takes the brief on stdin, and the
other three return instantly with exit code 0 if you pass a large brief as an argument. The
skill normalises that.

**A sentinel it can read instead of trusting.** Every run writes `.before` (tree snapshot),
`.log`, `.out` (the deliverable), and `.exit` — written *last*, so its existence is the
completion signal. An empty `.out` is a failed run no matter what the exit code says.

**One rule everything else serves:**

> **The run that changed the code is never the run that approves it.**

Relaying a reviewer into fixing what it found is sound — its review was written and harvested
*before* it gained write access. Relaying again to bless its own fix is not.

**How to disbelieve a green test suite.** A lock that guards nothing passes exactly as loudly
as one that guards everything, so the skill makes the agent break the invariant and show it
going red — with `git diff` proof the mutation actually landed.

## Why it exists

Launching a background worker is easy. Everything after it is where the failures live, and
every guard in this skill is there because the thing it guards against actually happened:

- A worktree whose `.git` pointer went missing resolves **upward to the main repository** —
  an existence check passes, and the dispatch edits your trunk.
- An upstream auth failure writes a *complete* sentinel, so it reports `DONE`, not `DEAD`.
  The missing deliverable is the only signal.
- `git rebase` does not fire pre-commit hooks, so "the gate was green after the rebase" is an
  empty sentence — and because rebase preserves the author date, the timestamps look fine.
- A `reset --soft` onto a moving trunk can stage the *reverse* of someone else's commit, and
  nothing goes red.
- A green static gate and a red test suite coexist happily, if the consumer surface was taken
  by grepping imports.

## What's inside

```
SKILL.md              the operational guide your agent reads
scripts/
  dispatch.sh/.ps1    launch a run (preflight + sentinel)
  relay.sh/.ps1       resume a finished run in its own session
  watch.sh            one state line per run, across all agents
  watch-loop.sh       emit only state changes, for a persistent monitor
templates/
  brief.md            implementation brief
  review.md           read-only review brief
```

Both shells are first-class: every script ships as `.sh` and `.ps1` with identical behaviour.

## License

MIT © HikariLan <i@hikarilan.life> — see [LICENSE](LICENSE).
