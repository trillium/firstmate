---
name: coderabbit-pr-gate
description: >-
  Agent-only policy for reacting to CodeRabbit's PR review advice, beyond a bare pass/fail check,
  and for handling CodeRabbit's rate-limiting without treating it as review failure.
  Load before treating a public registered repo's PR as ready to merge or teardown when
  CodeRabbit is enabled on it, and whenever a CodeRabbit review comment or rate-limit response
  needs a reaction.
user-invocable: false
metadata:
  internal: true
---

# CodeRabbit review-gate routine

This skill applies to every public registered repo with CodeRabbit enabled.
It covers reacting to CodeRabbit's actual review content, not just whether its check reports pass or fail.
The watcher's PR poll already wakes firstmate on a new bot review comment (see `state/<id>.pr-review-seen` in `AGENTS.md` section 2); this skill is the reaction policy layered on top of that wake, not a second wake mechanism.

## Policy

A green CodeRabbit check is not evidence of a review at all, let alone a clean one.
CodeRabbit reports its status context as `pass` when it is rate limited, with the description `Review rate limited`, while submitting no review and no review comments — the green check is byte-for-byte indistinguishable from a genuine clean review (observed on `trillium/firstmate#67`, `robots-6bsj`).
It can also pass a PR while leaving actionable suggestion comments (bugs, security notes, missed edge cases) that a bare status check does not surface.
Never read the check conclusion as review state; ask the reviews API.

`bin/fm-coderabbit-review-state.sh <owner> <repo> <pr-number>` is the one place that decision lives.
It prints `reviewed`, `rate-limited`, `pending`, or `absent`, and exits `3` when the forge could not be read — an unknown state, never a verdict.
`bin/fm-pr-merge.sh` gates every merge on it and refuses on anything but `reviewed` or `absent`; `FM_CODERABBIT_GATE=skip` is the deliberate, typed waiver for a stalled review the captain has decided to merge past.

Before treating a PR as merge-ready on a CodeRabbit-enabled repo:

1. Read CodeRabbit's review comments on the PR (via `gh-axi`), not just its check conclusion.
2. Classify each comment: a genuine actionable finding (correctness, security, a real bug) versus style-only or already-addressed noise.
3. Route actionable findings the same way any other review finding is routed under `AGENTS.md` section 7 and `ask-user-authority`.
   A routine, reversible fix within accepted task criteria is autonomous under `yolo`; anything that would expand scope, or is destructive, irreversible, or security-sensitive, escalates to the captain as a decision rather than being silently applied or silently ignored.
4. Do not merge past an unresolved actionable CodeRabbit finding without either fixing it or getting an explicit captain or `yolo`-authorized decision to proceed anyway.

## Rate-limit handling

CodeRabbit rate-limits review requests on busy repos or accounts.
A rate-limited or not-yet-reviewed state is not a failure and not silence to route around:

- Treat a CodeRabbit rate-limit or pending-review response as a `paused:`-class external wait (`AGENTS.md` section 8's distinction between `paused:` and `blocked:`), not a `blocked:` or `failed:` one.
- Re-check on a bounded backoff rather than polling tightly or repeatedly re-requesting a review, which extends the rate limit; let the watcher's own wake cadence carry the recheck instead of arming a dedicated poll loop for it.
- Detect the rate limit from `bin/fm-coderabbit-review-state.sh`, not from the check: a rate-limited PR shows a green CodeRabbit check, so treating the check as the signal reads the wait as a completed review.
- If CodeRabbit still has not produced a review after a reasonable number of backoff cycles, do not block merge readiness on it indefinitely.
  Report the stalled review to the captain as evidence rather than silently merging without it or silently waiting forever.
  Merging past it is a captain or `yolo`-authorized decision recorded as `FM_CODERABBIT_GATE=skip` on the merge, not an assumption.
- Never spam re-requests at CodeRabbit to work around a rate limit; that worsens the limit for every repo sharing the account.

## Scope

Applies to every public registered repo, including non-owned repos dispatched to via a fork (see `AGENTS.md` section 7 and `night-ops-directive`).
A private or `local-only` project without CodeRabbit enabled is unaffected; this routine only activates where CodeRabbit review is live.
