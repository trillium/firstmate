---
name: coderabbit-pr-gate
description: >-
  Agent-only policy for reacting to CodeRabbit's PR review advice, beyond a bare pass/fail
  check, and for handling CodeRabbit's rate-limiting without treating it as review failure.
  Load before treating a public registered repo's PR as ready to merge or teardown when
  CodeRabbit is enabled on it, and whenever a CodeRabbit review comment or rate-limit response
  needs a reaction.
user-invocable: false
metadata:
  internal: true
---

# CodeRabbit review-gate routine

This skill applies to every public registered repo with CodeRabbit enabled. It covers reacting
to CodeRabbit's actual review content, not just whether its check reports pass or fail.

## Policy

A green CodeRabbit check is necessary but not sufficient: CodeRabbit can pass a PR while still
leaving actionable suggestion comments (bugs, security notes, missed edge cases) that a bare
status check does not surface. Before treating a PR as merge-ready on a CodeRabbit-enabled repo:

1. Read CodeRabbit's review comments on the PR (via `gh-axi`), not just its check conclusion.
2. Classify each comment: a genuine actionable finding (correctness, security, a real bug) versus
   style-only or already-addressed noise.
3. Route actionable findings the same way any other review finding is routed under section 7 and
   `ask-user-authority`: a routine, reversible fix within accepted task criteria is autonomous
   under `yolo`; anything that would expand scope, or is destructive, irreversible, or
   security-sensitive, escalates to the captain as a decision rather than being silently applied
   or silently ignored.
4. Do not merge past an unresolved actionable CodeRabbit finding without either fixing it or
   getting an explicit captain or `yolo`-authorized decision to proceed anyway.

## Rate-limit handling

CodeRabbit rate-limits review requests on busy repos or accounts. A rate-limited or
not-yet-reviewed state is not a failure and not silence to route around:

- Treat a CodeRabbit rate-limit or pending-review response as a `paused:`-class external wait
  (section 8's distinction between `paused:` and `blocked:`), not a `blocked:` or `failed:` one.
- Re-check on a bounded backoff rather than polling tightly or repeatedly re-requesting a review,
  which extends the rate limit; let the watcher's own wake cadence carry the recheck instead of
  arming a dedicated poll loop for it.
- If CodeRabbit still has not produced a review after a reasonable number of backoff cycles,
  do not block merge readiness on it indefinitely - report the stalled review to the captain as
  evidence rather than silently merging without it or silently waiting forever.
- Never spam re-requests at CodeRabbit to work around a rate limit; that worsens the limit for
  every repo sharing the account.

## Scope

Applies to every public registered repo, including non-owned repos dispatched to via a fork
(see `AGENTS.md` section 7 and `night-ops-directive`). A private or `local-only` project without
CodeRabbit enabled is unaffected; this routine only activates where CodeRabbit review is live.
