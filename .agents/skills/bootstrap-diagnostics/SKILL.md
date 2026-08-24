---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, DEGRADED, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, BEADS_WRITE_QUEUE, BEADS_LABEL_MIGRATION, BEADS_SYNC, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` or `config/backlog-backend=beads` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `task` (the beads CLI), this reports the missing tool only when `config/backlog-backend=beads` is set.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
  For the beads task store (`config/backlog-backend=beads`), a missing `task` CLI or an unreachable/broken store only reaches `MISSING:` when no fresh local mirror exists (see `DEGRADED:` below); do not offer the install command as the only option without checking whether the mirror already covers it.
  The unreachable-store line names `task bootstrap --yes` because that is the non-destructive provisioning verb; never reach for `bd init --force`, and never run bootstrap against a store that answers a read, since its own detection cannot see a Dolt server-mode store and would create an empty database beside the live one.
  On a remote host the usual cause is a missing `task` wrapper rather than a missing store, which `bin/fm-remote-doctor.sh --fix` repairs; see [`docs/remote-secondmates.md`](../../../docs/remote-secondmates.md) "The beads store on a remote host".
- `DEGRADED: task CLI not found (beads store; install: <command>); using local mirror from <ts> until it is` / `DEGRADED: task store is unreachable or broken (beads backend configured, cannot run 'task list'); using local mirror from <ts> until it is` - the beads task store (`config/backlog-backend=beads`) is down, but a local mirror fresh enough to use exists (`docs/configuration.md` owns the mirror age threshold and files).
  Do not block dispatch on this alone: relay it as a plain-English notice that fleet status is running on a recent cached snapshot rather than live data, and any beads write attempted meanwhile is queued for automatic replay once the store recovers, not lost.
  Investigate the underlying store outage if it persists across multiple bootstraps rather than treating a one-off as actionable.
  This escalates to `MISSING:` only once the mirror itself goes stale (or never existed), at which point handle it exactly like an ordinary `MISSING:` install/instructions gap.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote secondmate host - and the stage stopped rather than letting it wedge; a `lock was no longer held` line means the session that asked for the sweeps no longer owns them, so leave them to the session that does.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after same-host connectivity returns; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
- `BEADS_WRITE_QUEUE: reconciled queued write for <id> (<description>)` - a beads write that failed during an earlier outage (dispatch stamp, assignment, or a task-close) replayed cleanly against the recovered store on this bootstrap's mutating sweep; no action needed, it is reported only so the recovery is visible.
  `(bead already closed)` on a queued close means the bead was already closed - by the outage's original close attempt landing after all, or by someone else - and firstmate reconciled instead of retrying it forever.
- `BEADS_WRITE_QUEUE: task CLI not found, N write(s) remain queued` / `BEADS_WRITE_QUEUE: store still unreachable, N write(s) remain queued` - the beads store outage is still ongoing; treat the same as an unresolved `DEGRADED:`/`MISSING:` beads line above rather than a new problem, and expect the queue to keep draining on later bootstraps once the store recovers.
- `BEADS_WRITE_QUEUE: replay failed for <id> (<description>); re-queued` - a queued write hit a genuine replay failure (not just an unreachable store) and was left queued for the next attempt.

- `BEADS_LABEL_MIGRATION: re-tagged <bead> onto task:<scope>:<id>` / `BEADS_LABEL_MIGRATION: complete: N bead(s) re-tagged, M left to another home` - the one-shot migration off the pre-home-scoping `task:<id>` label ran and finished; no action needed, it is reported only so the one-time rescue of this home's in-flight beads is visible ([`docs/configuration.md`](../../../docs/configuration.md) "Backlog backend" owns the scheme and what the sweep will and will not touch).

- `BEADS_LABEL_MIGRATION: left <bead> alone: another home already claimed it for <id>` / `BEADS_LABEL_MIGRATION: left <bead> alone: this home's own record for <id> names <other-bead>` - expected and correct, not a failure: the unscoped label records no home, so a bead another home has already scoped, or one this home's own record contradicts, is deliberately not claimed and this home mints its own bead for that task on its next dispatch.

- `BEADS_LABEL_MIGRATION: task CLI or jq not found, ...` / `BEADS_LABEL_MIGRATION: store unreachable, ...` / `BEADS_LABEL_MIGRATION: the store's label list could not be read, ...` / `BEADS_LABEL_MIGRATION: timeout library unavailable, ...` - the same underlying beads outage as the `DEGRADED:`/`MISSING:` beads lines above rather than a new problem; the sweep writes no completion marker and retries on a later bootstrap once the store recovers.

- `BEADS_LABEL_MIGRATION: the <N>s budget was spent, so the rest stays unmigrated and retries next session` - the sweep stopped itself at its own bound rather than holding the bootstrap phase open; whatever it re-tagged before that point is durable, no completion marker was written, and the remaining candidates are picked up next session. Investigate only if the same sweep keeps exhausting its budget across several sessions, which points at a store answering far slower than the per-read bound expects.

- `BEADS_LABEL_MIGRATION: could not read <bead>'s labels, so <id> stays unmigrated and retries next session` / `BEADS_LABEL_MIGRATION: re-tagging <bead> onto task:<scope>:<id> failed; it retries next session` - one candidate failed while the store was otherwise reachable; nothing is lost, because that task keeps resolving through its own scoped label or mints a fresh bead, and the sweep retries next session.

- `BEADS_LABEL_MIGRATION: this home's scope could not be derived, ...` - unlike the store lines above this one is local: `FM_HOME` is unset or empty, or no SHA-256 tool is on PATH, so the home-scoped label cannot be built at all. Under the beads backend that also means dispatch cannot link beads, so treat it as blocking and fix the environment before dispatching.
  Investigate if the same id keeps failing to replay across multiple bootstraps rather than treating a one-off as actionable.
- `BEADS_SYNC: pushed local commits to the configured Dolt remote` / `BEADS_SYNC: pulled remote commits into the local store` - the routine store sync ran; no action needed, it is reported only so the sync is visible.
- `BEADS_SYNC: skipped: no Dolt remote configured, so this store is single-machine only` - expected on every home today, because firstmate configures no Dolt remote: adding one publishes the task store to that destination and the destination is the captain's decision ([`docs/beads-sync-topology.md`](../../../docs/beads-sync-topology.md) owns the recommendation and the one question to ask).
  Do not configure a remote to clear this line; surface the durability gap to the captain only if they ask about off-machine backup, and never treat it as a failure.
- `BEADS_SYNC: push failed: <reason>` / `BEADS_SYNC: pull failed: <reason>` / `BEADS_SYNC: commit failed: timed out after <n>s` - the store is fine locally and only the remote leg failed, so nothing is lost and dispatch is unaffected.
  The sweep is best-effort and already backed off, so treat a one-off as informational and investigate the named remote only if the same step keeps failing across multiple sessions.
- `BEADS_SYNC: commit failed: 'task dolt commit' exited <n>: <reason>` - unlike the lines above, this one is local, not remote: the commit step could not commit (a Dolt error, schema skew, or a permission problem), so this home's writes are still sitting uncommitted in the Dolt working set and any push that follows did not carry them.
  A clean working set exits 0 and is never reported here, so this line always means the commit itself failed; investigate the named error rather than waiting for the next sweep, because backing off does not clear it.
- `BEADS_SYNC: <step> skipped: the <n>s sync budget was spent` / `BEADS_SYNC: skipped: the <n>s sync budget was spent before the Dolt remote list could be read` - an earlier part of this same sweep consumed the whole sweep's share of the session-start network budget, so the named step, or the sweep itself, never ran.
  Nothing is lost and no other sweep was starved, which is the point of the bound; investigate the step that ran long only if the same one keeps exhausting the budget across sessions.
- `BEADS_SYNC: skipped: could not read the Dolt remote list, so a configured remote is indistinguishable from none (<reason>)` - do NOT read this as the benign single-machine line above.
  The listing itself failed (`jq` absent, an unreachable store, or a `bd` too old for `dolt remote list --json`), so this home may have a remote configured and be silently not syncing to it; fix the named cause, then confirm the next sweep reports either a push/pull or the explicit no-remote line.
