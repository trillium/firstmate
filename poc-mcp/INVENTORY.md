First Mate capability inventory and MCP mapping (PoC)

This is exploratory scaffolding for task-gluj4, not a production contract.

The behavior owners remain the script headers, `AGENTS.md`, and `docs/scripts.md`.

## Read and inspection surface (highest MCP value, no side effects)

`bin/fm-fleet-snapshot.sh --json` is the canonical whole-fleet read with schema `fm-fleet-snapshot.v1`.

`bin/fm-bearings-snapshot.sh` is the pre-digested pick-up-where-you-left-off projection over the same snapshot.

`bin/fm-fleet-view.sh` is a Markdown renderer over the snapshot with no independent state.

`bin/fm-crew-state.sh <id>` is the deterministic current-state read that reconciles run-step, pane, and status log.

`bin/fm-peek.sh <target> [lines]` prints a bounded endpoint tail for cheap diagnosis.

`bin/fm-review-diff.sh <id> [--stat]` diffs a crew branch against its authoritative base.

`bin/fm-no-mistakes-liveness.sh` and `bin/fm-ledger.sh` expose pipeline liveness and the dropped-bead safety net.

`bin/fm-agent-axi.sh`, `bin/fm-guard.sh`, `bin/fm-harness.sh`, `bin/fm-project-mode.sh`, and `bin/fm-lock.sh status` answer triage, health, harness, posture, and lock questions.

`bin/fm-wake-memo.sh consult` and `bin/fm-session-start.sh` compose durable outcomes and the session digest from the same primitives.

## Control surface (writes, ranked by reversibility)

`bin/fm-send.sh <target> <text>` steers one crew with a verified literal line and is the safest exposed write.

`bin/fm-decision-hold.sh` records and resolves durable captain-held decisions with `fm-send --resolve-key` closing the loop.

`bin/fm-review-decision.sh` records a captain approve, decline, or comment and wakes firstmate.

`bin/fm-control.sh <id> interrupt|exit|relaunch|suspend|resume` drives agent lifecycle and kills or replaces workers.

`bin/fm-spawn.sh`, `bin/fm-brief.sh`, `bin/fm-promote.sh`, and `bin/fm-teardown.sh` create, launch, convert, and clean up tasks with worktree and endpoint side effects.

`bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, and `bin/fm-merge-local.sh` arm polls and land code through merge guards.

`bin/fm-x-reply.sh`, `bin/fm-x-dismiss.sh`, `bin/fm-x-followup.sh`, and `bin/fm-public-followup.sh` send public replies and are inert without relay consent.

`bin/fm-procevent.sh`, `bin/fm-home-seed.sh`, `bin/fm-on.sh`, `bin/fm-fleet-sync.sh`, `bin/fm-watch.sh`, and `bin/fm-bootstrap.sh` own event sources, homes, remotes, clones, supervision, and installs.

## Proposed typed mapping

Every read above maps to one MCP tool that takes typed ids and returns typed JSON instead of rendered text.

Every write maps to one MCP tool whose schema carries only the safe subset of flags (plain text for send, never `--key` or `--raw`).

Reads require no permission tier beyond home visibility, while writes require an explicit write grant plus the underlying firstmate authority (yolo posture, merge authority, relay consent).

The status log tail is exposed only as labeled wake-event history, never as current state, because `bin/fm-crew-state.sh` owns that reconciliation.

Raw state files, the wake queue, poll sidecars, and bead mirrors are never exposed for direct write, and the mirror is never presented as current.

## PoC coverage

The PoC exposes `fleet_snapshot`, `backlog`, `crew_state`, and `status_tail` as reads plus `send_message` as the single safe control op.

`fleet_snapshot` shells to `bin/fm-fleet-snapshot.sh --json` and validates the schema id before returning.

`backlog` derives records and per-state counts from the same snapshot instead of reimplementing either backend.

`crew_state` shells to `bin/fm-crew-state.sh` and parses its stable line without touching the log directly.

`status_tail` reads `state/<id>.status` with id validation, path confinement, and a 50-line cap.

`send_message` wraps only the plain-text `bin/fm-send.sh <target> <text>` path with a 500-char single-line cap and a slash-command refusal.
