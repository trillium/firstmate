# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
On the default tasks-axi backlog backend the command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
On `config/backlog-backend=beads` the command instead uses beads-native primitives, described below.
Decision holds are not supported on the manual backlog backend.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
On tasks-axi it creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
On beads it creates a labeled anchor bead carrying the hold identity when absent, then ensures an open `task gate create --type=human` blocks that anchor, self-healing if a prior attempt created the anchor but not the gate.
The anchor stores the hold reason as its own `metadata.hold_reason` at creation time.
Both paths reject an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity as durable, against tasks-axi or against the beads anchor and gate, before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task that is durably blocked by the hold.
On tasks-axi it records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
On beads it records the same retry identity as structured metadata on the anchor (`metadata.decision_digest`, `metadata.routed_identities`), removes the `task dep` edge from each routed task and from the anchor itself to the gate, then resolves the gate and closes the anchor.
An exact retry can finish a partial routing operation on either backend, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

On the beads backend, `bin/fm-fleet-snapshot.sh` reads captain-hold visibility from structured gate state, never scraped prose.
A record carrying the `captain-hold` label is a hold anchor; its presence in the open/in_progress/blocked fleet query is itself proof the hold is active, since `fm-decision-hold.sh` never leaves an anchor open without an active gate.
The anchor's `metadata.hold_reason` and its labels are enough to populate `hold_kind`, `hold_reason`, `current_role: "held"`, and `captain_actionable`, all from the one `task list --json` read used for the rest of the fleet query, with no extra beads calls per record.
A resolved hold closes its anchor, which then drops out of that same query and disappears from the snapshot with no further work needed.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Beads-native gate/dep hold path and structured Bearings visibility verification date: 2026-08-01.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```

The beads-native path regression uses a real, isolated beads store, never the shared federated store.
It covers anchor and gate creation, hold idempotency and title-collision rejection, `complete`/`verify` recognition of a beads-durable hold, `resolve`'s dependency-edge clearing and gate/anchor closing with idempotency on an exact retry, rejection of a changed decision or an undurably-blocked routed task, and rejection of reopening an already-resolved identity.
It also covers the structured Bearings visibility contract: a `captain-hold`-labeled record surfaces `hold_kind`, `hold_reason`, `current_role`, and `captain_actionable`, while an ordinary bead does not.

```text
$ bash tests/fm-decision-hold-beads.test.sh
ok - hold creates a labeled anchor bead with an open human gate and recorded hold_reason
ok - hold is idempotent on an identical retry: no duplicate gate is created
ok - hold rejects a retry that changes the recorded title
ok - complete and verify recognize an actively-held beads decision as durable
ok - resolve records the decision, clears dependency edges, and closes the gate and anchor
ok - resolve is idempotent on an exact retry of the same decision and routed set
ok - resolve rejects a retry that changes the recorded captain decision
ok - resolve rejects a routed task that is not durably blocked by the hold's gate
ok - hold rejects reopening an already-resolved decision identity
# all fm-decision-hold-beads tests passed

$ bash tests/fm-decision-hold-lifecycle.test.sh
(all 9 markdown-path cases above unchanged and still passing, confirming the tasks-axi backend is byte-for-byte unaffected)

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - beads backend snapshot reads fleet-scoped in-flight/queued beads
ok - beads backend snapshot surfaces structured captain-hold fields from gate-anchor metadata
ok - default backend backlog_json carries no beads-only fields
(all other cases above unchanged and still passing)

$ bash tests/fm-beads-backend.test.sh
ok - all beads backend tests passed

$ bash tests/fm-bearings-snapshot.test.sh
(all cases above unchanged and still passing)

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=64 local_links=169

$ git diff --check
(no output)
```
