# agent-delegation

*[English](README.md) · [简体中文](README.zh-CN.md)*

**Run any coding-agent CLI as a detached background worker on a git worktree — and be able
to prove, afterwards, what it actually did.**

One entry point for `codex`, `cursor-agent`, `codebuddy`, and `claude`. Each run writes the
same four-file sentinel, so its state is answerable from disk instead of from the agent's
own summary of itself.

## Why

A subagent shares your context budget and your turn. A detached CLI worker does neither: it
gets its own window, keeps running after your turn ends, and costs you only the brief you
write and the result you read.

The hard part was never launching one. It is everything after:

- A worktree whose `.git` pointer went missing resolves **upward to your main repository** —
  an existence check passes, and the dispatch edits your trunk.
- A brief passed as a command-line argument makes some CLIs return instantly with an empty
  log and **exit code 0**, which every monitor reports as success.
- An upstream auth failure writes a *complete* sentinel, so it reports `DONE`, not `DEAD`.
- `git rebase` does not fire pre-commit hooks, so "the gate was green after the rebase" is
  an empty sentence — and the commit timestamps look fine either way.
- A green static gate and a red test suite coexist happily, if you took the consumer
  surface by grepping imports.
- And a lock that guards nothing passes exactly as loudly as one that guards everything.

Every guard in this skill exists because one of those actually happened.

## Quick start

```bash
# 1. Make a worktree for the work (never dispatch into your trunk)
git worktree add ../wt-feature -b feature/thing

# 2. Write a brief (templates/brief.md and templates/review.md are starting points)
cp ~/.agents/skills/agent-delegation/templates/brief.md /tmp/brief.md
$EDITOR /tmp/brief.md

# 3. Dispatch. The model is required — this skill hard-codes none.
export AGENT_MODEL=<your-model-id>
scripts/dispatch.sh --agent codex --name fixthing \
                    --worktree ../wt-feature --brief /tmp/brief.md

# 4. Watch every run, across every agent, in one command
scripts/watch.sh
# DONE codex/fixthing exit=0 result=12268
# RUNNING cursor/probe log=48213

# 5. Read the deliverable — the notification is a pointer, not the content
cat ../.agent-runs/codex/fixthing.out

# 6. A reviewer whose findings ARE the next task: resume its session, don't re-brief it
scripts/relay.sh --agent codex --from review1 --name fix1 \
                 --worktree ../wt-feature --brief /tmp/fix.md
```

PowerShell users: every script has a `.ps1` twin with the same parameters
(`dispatch.ps1 -Agent codex -Name fixthing -Worktree ..\wt-feature -Brief brief.md`).

### Configuration

| variable | meaning |
|---|---|
| `AGENT_MODEL` | model id for every lane |
| `AGENT_MODEL_<AGENT>` | per-lane override, e.g. `AGENT_MODEL_CODEX` |
| `AGENT_RUNS` | where the sentinel lives (default `<repo>/.agent-runs/<agent>/`) |
| `AGENT_WATCH_INTERVAL` | poll seconds for `watch-loop.sh` (default 20) |

## The one rule everything else serves

> **The run that changed the code is never the run that approves it.**

Dispatch a fresh run to review work. Relay a *reviewer* into fixing what it found — that is
sound, because its review was written and harvested before it gained write access. Relaying
again to bless its own fix is not.

## Where it pays off

**Long refactors you cannot hold in context.** Dispatch, go do something else, harvest a
diff hours later against a snapshot taken at dispatch time — so a run that quietly
installed 100 MB of dependencies cannot show you a clean tree.

**Review that is not theatre.** The review template demands that a claimed lock be *broken*
and shown going red, with `git diff` proof the mutation landed. It also asks the durable
question rather than the convenient proxy: *what invariant does this lock guard — break it,
does anything go red?* Counting edit sites answers "two" for every string assertion and for
every equality lock ever written.

**Fan-out with an honest ledger.** Run several agents on several worktrees; `watch.sh`
reports one line per run across all of them, and tells apart *finished with nothing*,
*died on credentials*, and *still going* — three states that otherwise look identical.

**Catching your own briefs being wrong.** Every brief ends by inviting the run to argue
back. Those rebuttals are frequently right and occasionally, confidently wrong — so the
skill also tells you to verify them: anything checkable by one command, check yourself.

## Layout

```
agent-delegation/
├── SKILL.md              the operational guide (read this)
├── README.md
├── LICENSE               MIT
├── scripts/
│   ├── dispatch.sh/.ps1  launch a run (preflight + sentinel)
│   ├── relay.sh/.ps1     resume a finished run in its own session
│   ├── watch.sh          one state line per run, across all agents
│   └── watch-loop.sh     emit only state changes, for a persistent monitor
└── templates/
    ├── brief.md          implementation brief
    └── review.md         read-only review brief
```

## Install

Drop the directory anywhere your agent host discovers skills — for example
`~/.agents/skills/` with a symlink from `~/.claude/skills/`, or straight into
`~/.claude/skills/`. The scripts are standalone: they can be run by hand with no host at all.

## License

MIT © HikariLan <i@hikarilan.life> — see [LICENSE](LICENSE).
