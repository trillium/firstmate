---
name: stale-branch-repair
description: >-
  Agent-only procedure for repairing a long-lived branch or PR that has gone conflicting,
  and for verifying a crewmate's claim that it was repaired.
  Use before briefing any rebase, conflict resolution, or "PR is conflicting" task,
  and before accepting any crewmate report that a branch was fixed.
  Owns the contribution-first triage that decides rebase vs rebuild vs close,
  the four-marker diff3 hazard, the firstmate-resolves-it escalation for semantic conflicts,
  and the repo-derived verification that replaces trusting a worker's summary.
user-invocable: false
metadata:
  internal: true
---

# stale-branch-repair

Use this procedure before briefing a rebase or conflict-resolution task, and before accepting a
crewmate's report that a conflicting branch is fixed.
This skill is the single owner of Firstmate's stale-branch triage and crew-claim verification.

It sits beside `diagnostic-reasoning` (which owns reasoning about reported bugs) and
`stuck-crewmate-recovery` (which owns a wedged or unresponsive worker).
Use this one when the *work itself* is a branch that will not merge.

## 1. Triage before dispatch: what does the branch still contribute?

A conflicting long-lived branch is usually not a merge problem. It is a branch whose purpose was
partly or wholly overtaken while it sat. Establish that before briefing anyone to rebase.

The diagnostic is two commands (run both, always fetch first):

```sh
git fetch origin --prune
git diff --stat origin/<default-branch> HEAD
```

This compares the remote default branch tip to your current HEAD, not your working tree. **A stale `origin/<default-branch>` reference can misclassify the branch; always fetch first.**

Also run:

```sh
git status --short
```

This reports any uncommitted changes, which must be resolved before verifying contribution.


**Not** the diff since the merge-base, which is what `gh pr diff` and the GitHub PR view show.
The merge-base diff answers "what did this branch do?"; only the diff against the current default
branch answers the question that decides the work: **"what does this branch still contribute?"**

Read the result and classify:

- **Contributes nothing** — the default branch already satisfies the branch's stated purpose.
  Make a recommendation with evidence (e.g. exit code/output of the check). Only close the PR if the captain explicitly authorizes it.
- **Contributes a small subset** — most files are drift, a few are the real work.
  Make a recommendation (list the files and evidence). Only reset the branch (after creating a backup ref or saving the worktree) if the captain explicitly authorizes it. See AGENTS.md hard rule 3.
- **Contributes broadly and genuinely conflicts** — a real rebase or merge is warranted.
  Continue to section 2.

### The drift trap

A branch cut before a large merge landed is now *older* than the default branch on every file it
did not touch on purpose. Carrying those files over silently reverts work that has since landed:
pinned tool versions, deliberate lint-rule disables, dependency bumps, CI runner settings.

This reversion is invisible in review. It arrives as "resolved the conflicts", it is buried in a
large diff, and nothing fails. Enumerating the contributing paths in the brief — and requiring the
worker to paste `git diff --stat origin/<default-branch> HEAD` showing *exactly* those paths and
nothing else (after `git fetch origin --prune`) — is what catches it.

Always run `git status --short` and resolve any working tree changes before triage; a "clean branch" must be truly clean.

Ask "what does this branch still contribute over the default branch?" before ever asking
"how do I resolve these conflicts?" The answer is usually far smaller than the conflict count
implies, and is sometimes nothing.

## 2. The four-marker hazard

Repositories configured with `diff3` or `zdiff3` conflict style emit **four** marker types, not
three:

```text
<<<<<<<      ours
|||||||      common ancestor      <-- the one agents miss
=======      theirs
>>>>>>>
```

Models reliably know the three-marker `merge` style and scrub `<<<<<<<`, `=======`, `>>>>>>>`
while leaving `|||||||` lines committed in the file. In a shell script that is a syntax error; in
other languages it can be worse, because it may parse.

Require this check after any agent-resolved conflict, before trusting the branch:

```text
git grep -n -E '^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)' HEAD
```

It must return nothing. Add a syntax check on every touched file — `bash -n` for shell, the
project's own typecheck otherwise. A worker asserting "all merge markers are removed" is not
evidence; the grep is.

## 3. When the crewmate cannot resolve it, Firstmate resolves it

A worker that has failed the same conflict twice will not succeed on the third try. It will
delete real code and leave unbalanced blocks. Escalating steers do not help.

At that point Firstmate resolves the conflict itself **in the scratchpad, never in the project**,
and hands the worker finished files to copy in. This stays inside hard rule 1: Firstmate writes
only to its own scratch space, and the crewmate is still the one that changes the project.

**Repair writes must only happen in an isolated disposable worktree. If you are in the primary checkout, stop and refuse the operation. This matches the ship-brief isolation assertion and prevents overwriting another agent’s unlanded work.**

Reconstruct a clean conflict from the three inputs — a partially-scrubbed committed file is not a
usable starting point:

```sh
git show "<merge-base>:<path>"  > base
git show "origin/<default>:<path>" > ours
git show "<pr-tip>:<path>"      > theirs
git merge-file -p --diff3 ours base theirs > conflict
```

Then choose per hunk:

- **Both sides pure additions** — keep both. Confirm it *is* pure addition with
  `git diff --stat <merge-base> <side>` on each side showing no deletions. Concatenate by dropping
  the ancestor section and all four marker lines.
- **Either side modified or deleted shared lines** — this is a semantic merge and needs a real
  decision. Read both sides, identify the intent each was implementing, and compose a result that
  preserves both. Two bug fixes landing on the same block usually compose as one wrapping the
  other, not as one replacing the other.

**`git merge-file --union` is not a safe "keep both".** It aligns similar lines across the two
sides and will interleave them, silently dropping a closing brace or `fi`. Verified failure:
union output passed the marker grep and failed `bash -n`. Use the marker-driven concatenation on
real `--diff3` output instead, and syntax-check the result before handing it over.

Verify the resolution yourself before the worker touches it — syntax check, marker grep, line
count. Then instruct the worker to copy the files in verbatim and explicitly forbid further edits.

## 4. Verify against the repository, never against the report

A crewmate's `done:` is a claim. Derive the outcome from the repository instead. This costs
seconds and has repeatedly caught confident, entirely false success reports — including one
delivered on the same screen that printed the failing test count.

| Claim | The check that settles it |
|---|---|
| "commit touches only X" | `git show --stat HEAD` |
| "pushed" | `git rev-parse HEAD origin/<branch>` — both sides must match |
| "removed/added <string>" | `grep -n '<the exact string>' <file>` |
| "tests pass" | output and exit code of the exact gate/test command, or rerun the gate yourself in the repository |
| "markers gone" | the four-marker grep in section 2 |
| "lint clean" | the exit code of the *whole* chained lint command, not one step of it |
| "conflict resolved as instructed" | `diff` the worktree file against the scratchpad resolution |

When a worker quotes one step of a multi-step gate, treat it as unverified. A chained
`a && b && c` command has a single exit code that covers all of it; ask for that.

Require pasted command output, not a summary. State plainly that a claim without output will be
sent back — and follow through, because the alternative is a broken branch treated as merge-ready.

## 5. Two environment hazards that masquerade as a stuck worker

- **An editor-opening git command hangs forever.** Where the configured git editor waits on a GUI
  (`code --wait` and similar), any command that opens an editor blocks on a human who does not
  exist: `commit` without `-m`, `rebase --continue`, `merge`, `revert`, `tag -a`,
  `cherry-pick --continue`. It is silent, a wedged pane looks like a thinking pane, and the
  worker's natural retry stacks more orphaned waiters.
Diagnose with `ps -eo pid,etime,command | grep COMMIT_EDITMSG`. Killing the waiters unblocks the pane, but the pending git command may fail rather than complete. Capture state with `git status` first, then rerun the pending command with `GIT_EDITOR=true`. Put `GIT_EDITOR=true` in the brief for every such command.
- **A branch "checked out in another worktree" is not a blocker.** Pushing does not require a
  checkout: `git push origin HEAD:<branch>` works from a detached HEAD, and
  `--force-with-lease=<branch>:<expected-sha>` still applies.
  Brief this explicitly, because the tempting workaround is removing the other worktree — which
  destroys another agent's in-flight work and violates the brief's own isolation rule.

## 6. A red check often names the wrong problem

Before scoping work from a failing check, read the job log rather than the check name. A job named
for what it *would* have done, had it gotten that far, commonly dies during setup instead —
dependency install being the usual culprit. Several red checks are frequently one cause reported
several times, because deploy sub-checks cannot pass while their deploy fails.

Reading the log rather than the label both finds the real cause and avoids escalating a needless
credential or access request for a build that never reached the step a credential would matter to.
