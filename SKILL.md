---
name: agent-delegation
description: Run any coding-agent CLI (codex, cursor, codebuddy, claude) as a detached background worker on a git worktree — dispatch it, watch the sentinel it writes, relay a finished reviewer into its own fix, and prove what it claims. Use when handing a long task to an agent CLI, when a dispatched run needs watching or has gone quiet, when a review's findings should become the next run, or when a run reports a lock it never proved.
---

# Agent Delegation

A subagent shares your context budget and your turn; a detached CLI worker does neither.
It gets its own window, runs for hours after your turn ends, and costs you only the brief
you write and the result you read. That makes it the right shape for work measured in
hours — and the wrong shape for anything you'd rather just do.

This skill covers the **running** of such a worker, across four CLIs behind one entry
point. Scripts come in both `.sh` and `.ps1`; they behave identically.

## The four lanes

| agent | CLI | write flag | read-only lane | resume |
|---|---|---|---|---|
| `codex` | `codex exec` | `--dangerously-bypass-approvals-and-sandbox` | omit it | `codex exec resume <sid>` |
| `cursor` | `cursor-agent` | `--force` | `--plan --trust` | none — dispatch fresh |
| `codebuddy` | `codebuddy` | `-y` | omit it | `--resume <sid>` |
| `claude` | `claude` | `--dangerously-skip-permissions` | omit it | `-r <sid>` |

**No model id is hard-coded anywhere in this skill.** Pass `--model`, or set
`AGENT_MODEL_<AGENT>` / `AGENT_MODEL`. Ids change; a stale default fails late and looks
like a task problem rather than a config one.

Two differences fail **silently** if you get them wrong:

**How the brief reaches the agent.** `codex` takes it on stdin, so multi-line quoting
never has to survive a shell. The other three take argv — and passing a large brief as an
argv element makes the CLI return immediately with a few-byte log and **exit code 0**,
which a monitor reports as `DONE`. So they are handed the brief's **path** and read the
file themselves. The dispatch scripts already do this.

**The read-only lane.** `cursor --plan` still demands Workspace Trust, so it needs
`--trust` (which grants no execution). A **freshly created** worktree has never been
trusted, and the run exits instantly with an empty deliverable.

## Preflight

**Never dispatch into a path you have not made git resolve.** A worktree removal that
fails partway leaves the files but drops the `.git` pointer, and from then on git walks
*up* and resolves that directory to the **main repository**. An existence check passes.
A dispatch into it edits the trunk.

The dispatch scripts make git resolve the path and refuse to launch when
`rev-parse --show-toplevel` disagrees with the directory they were handed.

**That check cannot catch the main repo being passed in** — a repo resolves to itself, so
it prints `preflight ok` and dispatches straight into the trunk. It is guarded separately,
by comparing against the parent of `--git-common-dir`. Keep both; they catch different
things.

## The sentinel quartet

Every run writes four files named for it, so its state is answerable from disk rather than
from the agent's own account:

| file | written | what it answers |
|---|---|---|
| `.before` | at dispatch | the tree's `git status --porcelain --ignored` |
| `.log` | streaming | what happened, in full |
| `.out` | at the end | the deliverable — the run's final message |
| `.exit` | **last** | it finished, and with what code |

`.exit` is written after everything else precisely so its existence *is* the completion
signal. `scripts/watch.sh` reads the quartet across **all** run directories.

**An empty `.out` is a failed run, whatever the exit code says.** The transcript is not the
deliverable; a run that ended without producing one produced nothing.

**Watch for the run that died on credentials.** An upstream 401 ends the run with a
*complete* sentinel — `.exit` is written, `.out` is empty — so the monitor reports `DONE`,
not `DEAD`, and only `result=MISSING` distinguishes it. Split the two cases at a glance:

```
.out empty  +  log has 401/INVALID_API_KEY   =>  credentials/upstream. Re-dispatch.
.out empty  +  log has no 401                =>  it really produced nothing. Read the brief.
```

**Do not conclude "transient" from the other runs still going.** Sessions already
established do not re-authenticate — the token is in the session, and only *new*
connections refresh. So "the others are fine" is not evidence about credentials at all.
Judge from **newly dispatched** runs; two new ones failing means the config changed.

**Not every CLI streams.** Some print only at the end, so `.log` stays at zero bytes for
the whole run and log growth cannot tell you whether it is alive. Fall back to process CPU
time and the tree's own state (HEAD, dirty count, branch pointer).

**Measure logs with a stat call, not a directory listing.** Some shells' listing commands
report a cached directory entry — `0` bytes — for a file being actively written, which
reads exactly like a dead run.

**Requirements:** the chosen CLI on `PATH`, a git repository, and bash or PowerShell.
Set `AGENT_RUNS` to relocate the sentinel directory (default `<repo>/.agent-runs/<agent>/`).

## Wiring it into an agent host

**Arm one persistent watcher for all runs, before the first dispatch** — for example, in
Claude Code:

```
Monitor({command: "bash <skill>/scripts/watch-loop.sh", persistent: true,
         timeout_ms: 3600000, description: "agent runs finishing or dying"})
```

One watcher covers every run, including ones dispatched later. Per-run watchers multiply
notifications for nothing and risk a flood cut-off.

**Never block on a run.** Not a foreground wait, not a sleep loop. Runs last hours; the
watcher is what tells you, and your turn ends long before they do.

**The notification is a pointer, not the content.** `DONE codex/name exit=0 result=12268`
says a deliverable exists — it does not say what it concluded. Read `.out` before deciding.

**Refill the slot the moment one frees.** The costly failure is not running too many at
once — it is several finishing together, you harvesting them all, and nothing new going
out while you write up results. Dispatch the next brief *before* writing the summary.

Parallelism ceilings are per-account and differ per lane. Find each one: raise the count
until runs start failing on rate limits, then stay one below. Heavy-IO work (rebases,
repeated test collection, full static runs) belongs on the slowest-contended disk you have.

## The loop

Each completion runs the same cycle:

1. **Read `.out`.** Missing or empty → treat as failed, whatever the exit code says.
2. **Harvest** (below) — diff the tree against `.before`, verify the claims.
3. **Route** by what you find:
   - clean → dispatch a **fresh** run to review it (`templates/review.md`)
   - review found real defects → **relay** that reviewer into fixing them
   - review passed → merge, and dispatch the next piece of work
4. **Refill** the slot in the same turn.

The invariant that holds the loop together: **the run that changed the code is never the
run that approves it.** Everything else here is machinery serving that one rule.

## Harvest

**Diff `.before` against the tree's `git status --porcelain --ignored` now.** Plain
`--porcelain` hides ignored paths — a run that wrote a large dependency tree shows a clean
status, and the snapshot proves nothing. Read the two lists against a stated allowance:
tool caches are expected; installed dependencies, writes outside the tree, and any
tracked-file change the brief did not authorise are violations.

State that allowance **in the brief**, as two explicit lists. "Modify nothing" and "run the
test suite" contradict each other, and a run given both will either skip the tests or
declare its own work invalid over a cache directory.

**Check the staged set against what the change should touch.** If the run rebased or reset
onto a moving trunk, the index can quietly contain the *reverse* of someone else's commit —
and nothing goes red. Measured twice: a run's staged set silently reverted a commit that
had landed an hour earlier, restoring a deleted assertion and rolling back a hash table.
Reading `git diff --cached --name-status` line by line is the check, and it is the only
thing that caught it.

**A conflict inside a test file is the highest-risk resolution there is.** When both sides
appended tests, picking a side deletes a whole block of them and **produces no red light**.
Require a union, and verify by comparing the set of test function names on both sides.

**A green static gate does not mean nothing is red.** Measured: a full static tier reported
45/45 with zero failures, and on the very same tree a consumer test failed immediately —
the trunk had introduced a map that exhaustively enumerates an enum, and the branch's new
enum member was not registered. No step in a "rebase → edit → re-measure → verify staged
set → commit" checklist touches that. What finds it is asking **"who reads the shape this
module writes out?"** and running those tests — not grepping for imports of the module,
which measured about half the surface.

**Replaying a commit is not the same as making one.** `git rebase` does not fire
pre-commit hooks, so "the gate was green after the rebase" is an empty sentence. Read the
**commit** date, not the author date — rebase preserves the author date, so stale-looking
timestamps mean nothing. Adjacent commits landing seconds apart, when the gate takes
minutes, is the signal that no gate ran. The only reliable check is running it yourself.

## Relay

When a read-only reviewer finishes and its findings *are* the follow-up work, resume that
same session rather than briefing a fresh one — it already holds the whole branch in
context. `scripts/relay.sh` (or `.ps1`) extracts the session id from the previous `.log`
and continues it. `cursor` has no resume lane here; dispatch fresh and restate the context.

**The one invariant: whoever changed the code is never the one who signs off on it.**
Relaying a reviewer into a fix is sound — its review was written and harvested before it
gained write access, so the fix cannot have coloured a conclusion that already exists on
disk. Relaying *again* to bless that fix is not.

A relay that cannot find the session id must fail loudly. Starting a fresh session instead
looks identical from the outside while carrying none of the context that justified relaying.

## Prove it broke

**Green is the default state.** A test suite that passes proves nothing about a lock that
was just written — an assertion that checks nothing passes exactly as loudly as one that
guards the invariant.

So require, in the brief and again when reading the result: **break the thing the lock
guards, and show it going red.** Paste the failure text, not a claim that it failed.

**Ask the question at the level of the invariant, not the edit count.** "How many places
would I have to change to silence this lock?" is a proxy, and it was measured wrong in both
directions: every string assertion answers "two", and every equality lock is built from two
copies by construction. The durable form is:

> **What invariant does this lock claim to guard? Break that invariant — does anything go red?**

Two operational faces of the same question, and a lock should survive both:
- change **only production** — can that silence it? (if yes, it never covered the case)
- degrade the assertion to **trivially true** — does anything else still go red? (if yes,
  something other than that assertion is load-bearing)

Two sharper forms, for when a run reports N locks:

- **Independence.** Breaking guard *i* must turn guard *i* red **and leave the other N−1
  green**. `1 failed, N-1 passed` is the shape that proves the guards can tell the cases
  apart; N reds from one break means one guard wearing N names.
- **Reachability.** Ask for the assertion sites as `file:line` **before** asking about
  mutations. A run that mutated N times and went red N times will otherwise report "N
  locks" when it has two. Red count is not lock count; **site** count is.

**"It cannot be mutated" is a claim to distrust.** Measured: a run reported a negative
assertion as impossible to mutate. The real cause was a badly chosen mutation point — the
naive edit crashed in unrelated setup before the assertion ran, and a leaked subprocess
kept the test framework from printing the traceback. Two masking layers stacked. A
different mutation point flipped it cleanly. Conclusions that cancel work need the
strongest evidence, not the weakest.

**Require proof the mutation landed.** A replacement that missed its anchor produces a
green run indistinguishable from a lock that guards nothing — so demand `git diff` output
after each mutation, before the test run.

**And require a restore point.** `git checkout -- <file>` restores from the **index**, so
on a tree with uncommitted work it wipes the run's own fix along with the mutation. Stage
first.

## Writing the brief

Start from `templates/brief.md` (implementation) or `templates/review.md` (read-only
review). Both encode the demands above; fill in the task-specific parts.

Four things belong in every brief and are easy to leave out:

**Falsify first.** Open with a probe that reproduces the defect on the current trunk, and
an instruction to stop and report if it is already fixed. Work dispatched against a defect
that no longer exists comes back as a plausible change to something else.

**Name the tool by its exact invocation, not by its name.** Pointing at a checker by name
invites the wrong invocation, and the wrong invocation can *fabricate* failures rather than
miss them: one type checker invoked directly reported hundreds of errors on a clean tree —
all in unrelated files — while the project's own wrapper reported zero. Three separate runs
stalled on that phantom before anyone ran the real command. Paste the exact line the gate
config uses.

**Check the brief against itself before sending.** Measured four times in one day: a title
that presupposed the answer to a question the body asked the run to decide; an environment
block pinned to a different tree than the one the experiment names; a requirement and a
prohibition that cannot both be satisfied. Three mechanical passes catch all of them —
title vs. body, environment block vs. task, every requirement against every prohibition.
And keep the title free of conclusions: name the subject, not the verdict.

**Invite the rebuttal — then verify it.** End with "tell me where this brief is wrong —
argue it and show evidence." Briefs carry the author's causal guesses, and those fail far
more often than the numbers in them do. But that section is a **claim, not a finding**.
Split it on arrival: anything checkable by one command, **check yourself**; the rest is an
unverified assertion and should be labelled one. Measured repeatedly: a run's correction
("that field does not exist in the artifacts", "those values appear nowhere in history")
was itself wrong, was believed, and was written into the record. In each case the
*recommendation* was right, which is exactly why nobody re-examined the reason.
