# No-mistakes Run Liveness Checks

These helpers provide reliable, fast ways to answer two related questions about the shared no-mistakes daemon without relying on guesswork or waiting out crewmate timeouts:

1. **Before daemon-affecting actions** (init, update, daemon restart): Which "running" no-mistakes runs are genuinely live, and which task (if any) owns each one?
2. **During supervision**: Is an in-flight no-mistakes run genuinely progressing, or has it silently hung?

## Tools

### `bin/fm-no-mistakes-liveness.sh` - full run inventory

Comprehensive check of all running no-mistakes runs. Lists each run's ownership, status, and elapsed time in the active step.

```bash
# Check all running runs and their liveness
fm-no-mistakes-liveness.sh --all

# Check a specific task's run
fm-no-mistakes-liveness.sh <task-id>

# Show help
fm-no-mistakes-liveness.sh --help
```

**Output format** (one line per run):
```
run: <run-id> · branch: <branch> · status: <live|hung|unknown> · owned-by: <task-id> · last-activity: <seconds>s
```

**Exit codes:**
- 0 = success, all checked runs are live
- 1 = at least one run is hung
- 2 = usage error or precondition failure

### `bin/fm-nm-run-is-live.sh` - lightweight single-run check

Fast liveness check for a specific run ID. Designed for integration into supervision loops.

```bash
# Check if a run is live
fm-nm-run-is-live.sh <run-id>
```

**Exit codes:**
- 0 = run is live/progressing (or not in a step that can hang)
- 1 = run is hung (step inactive for > 5 minutes)
- 2 = usage error

## Liveness Detection Logic

A run is considered **live** if:
- It has a terminal outcome (passed, failed, cancelled, checks-passed)
- It is parked at a gate awaiting agent input (`awaiting_agent:` marker)
- Its active step (running/fixing) has been active for less than the stale threshold (5 minutes by default)

A run is considered **hung** if:
- An active step (running/fixing) has not had activity for more than the stale threshold
- The step duration or log timestamps indicate stagnation

## Integration Points

### Before Daemon-Affecting Actions

Before calling `no-mistakes init`, `no-mistakes update`, or restarting the shared daemon:

```bash
fm-no-mistakes-liveness.sh --all || exit 1
```

Check the output: if any run shows `status: hung` or `status: unknown`, investigate before proceeding. This prevents accidentally killing a genuinely in-flight validation run.

### During Supervision (fm-watch.sh)

When supervising a no-mistakes task with `kind=ship` and an active run:

```bash
run_id=$(grep "^id=" state/<id>.meta | cut -d= -f2)
if ! fm-nm-run-is-live.sh "$run_id"; then
  # Run is hung - escalate to firstmate
fi
```

This provides an independent liveness signal that catches hung runs faster than waiting for the crewmate's own tool timeout (which can be 15-30 minutes).

### From fm-crew-state.sh

When determining current state for a task with an active no-mistakes run, `fm-crew-state.sh` already reads the run's step activity and duration. The liveness helpers provide a reusable check for the same logic.

## Timeout Tuning

The default stale threshold is 300 seconds (5 minutes). Adjust via environment variable:

```bash
FM_NM_LIVENESS_STALE=600 fm-no-mistakes-liveness.sh --all
```

The CLI timeout (default 15 seconds) can also be tuned:

```bash
FM_NM_LIVENESS_TIMEOUT=20 fm-no-mistakes-liveness.sh --all
```

## Task Ownership Resolution

Run ownership is determined by matching the run's branch name to `state/<id>.meta` files in:
- The primary FM_HOME's state directory
- The current git repository's state directory (when called from a project)
- Registered secondmate homes (if secondmates.md exists)

A task is reported as `owned-by: unknown` when:
- No task's worktree is on the run's branch
- The run's branch is a temporary or abandoned branch
- The task's metadata is missing or corrupt

## Incident Prevention

This tool was created to prevent incidents like the 2026-07-31 case where a genuinely live no-mistakes run (`fold-slice4-shims`) was silently killed by a daemon restart because firstmate had no way to distinguish it from an old stale entry in `no-mistakes runs`.

**Usage protocol before daemon mutations:**
1. Run `fm-no-mistakes-liveness.sh --all`
2. For each run, verify either:
   - It is owned by an active task under way (known from the backlog or supervision state)
   - OR you are confident it is abandoned and safe to lose
3. Only then proceed with daemon init/update/restart

**Usage protocol during supervision:**
1. When a no-mistakes task appears to hang (pane shows waiting on validation), call the liveness check
2. If it reports hung, escalate rather than waiting for the crewmate's own timeout
3. Proceed with diagnostic/repair/teardown as needed

## See Also

- `bin/fm-crew-state.sh` - current-state reconciliation for a task (includes no-mistakes run details)
- `docs/configuration.md` - runtime backend and metadata schema
- `AGENTS.md` section 8 - supervision protocols
