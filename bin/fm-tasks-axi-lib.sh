# shellcheck shell=bash
# Shared backlog backend selection (tasks-axi, beads, or manual) and tasks-axi
# compatibility probe for bootstrap, teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations; `config/backlog-backend=beads` uses the federated task store
# instead. Validated secondmate handoffs always use `tasks-axi mv` when on the
# tasks-axi backend. Absent or invalid values keep the default tasks-axi backend
# path, falling back to manual mutation when the tool is not compatible.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.4

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  [ "$(fm_backlog_backend_value "$config_dir")" = beads ] && return 1
  fm_tasks_axi_compatible
}

fm_beads_backend_available() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = beads ] || return 1
  command -v task >/dev/null 2>&1 || return 1
  task list --limit 1 >/dev/null 2>&1
}

# --- Beads store provisioning and Dolt sync (config/backlog-backend=beads only) ---
#
# Every function below is inert on the tasks-axi and manual backends: callers
# gate on fm_backlog_backend_value before invoking them, and none of them runs
# unless a `task` CLI is on PATH. The beads store stays the single write
# authority throughout; provisioning only creates a store where none answers,
# and sync only moves that store's own commits to and from a Dolt remote the
# operator configured, exactly the availability-not-authority doctrine
# bin/fm-beads-resilience-lib.sh states for the mirror and write queue.
#
# STORE RESOLUTION IS THE CLI'S JOB, NOT FIRSTMATE'S. The `task` wrapper pins
# BEADS_DIR for the whole federation, so firstmate never derives, guesses, or
# hardcodes a store path; it asks the CLI whether the store answers and reports
# what it says. That is why a home with no local .beads/ directory is not
# evidence of a missing store: the shared store the wrapper points at can live
# anywhere, including a Dolt sql-server this host merely connects to.

# fm_beads_store_reachable - true when the beads store answers a cheap read.
# This, not the presence of a .beads/ directory, is the store-usable test.
fm_beads_store_reachable() {
  command -v task >/dev/null 2>&1 || return 1
  task list --limit 1 >/dev/null 2>&1
}

# fm_beads_bootstrap_store - provision a store non-destructively with
# `task bootstrap`, the verb whose own help documents that it never deletes
# existing issues (unlike the forbidden `bd init --force`).
#
# REFUSES WHEN THE STORE ALREADY ANSWERS. This guard is the whole safety
# margin, because bootstrap's own auto-detection reads the .beads/ directory
# and does NOT see a store served by a Dolt sql-server: against a healthy
# server-mode store it reports `"action":"init","has_existing":false` and would
# create a fresh empty database beside the live one. Firstmate therefore
# decides reachability itself and only ever bootstraps a store that is
# genuinely not answering, so a working home can never be bootstrapped over.
fm_beads_bootstrap_store() {
  command -v task >/dev/null 2>&1 || return 1
  if fm_beads_store_reachable; then
    printf 'BEADS_STORE: store already reachable; bootstrap refused (never bootstrap over a live store)\n'
    return 1
  fi
  BD_NON_INTERACTIVE=1 task bootstrap --yes >/dev/null 2>&1 || return 1
  fm_beads_store_reachable
}

# fm_beads_sync_remote_count - number of configured Dolt remotes, from the
# machine-readable listing (`[]` when none). Prints 0 on any failure, so a
# caller treats an unreadable remote list the same as an unconfigured one and
# stays inert rather than guessing a destination.
fm_beads_sync_remote_count() {
  local out count
  command -v task >/dev/null 2>&1 || { printf '0\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0\n'; return 0; }
  out=$(task dolt remote list --json 2>/dev/null) || { printf '0\n'; return 0; }
  count=$(printf '%s' "$out" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null) || count=0
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  printf '%s\n' "$count"
}

# fm_beads_sync_configured - true when at least one Dolt remote exists, which
# is the only condition under which firstmate syncs at all. Firstmate never
# adds a remote: choosing a destination publishes the captain's task store to
# that destination, so it is a captain decision, and until one is made every
# sync path below is a reported no-op rather than a guess.
fm_beads_sync_configured() {
  [ "$(fm_beads_sync_remote_count)" -gt 0 ]
}

FM_BEADS_SYNC_TIMEOUT=${FM_BEADS_SYNC_TIMEOUT:-45}
case "$FM_BEADS_SYNC_TIMEOUT" in '' | *[!0-9]* | 0) FM_BEADS_SYNC_TIMEOUT=45 ;; esac

# fm-timeout-lib.sh is loaded lazily by the sync path alone. Every other
# consumer of this library (bootstrap's detect-only pass, teardown, the
# secondmate handoff, the remote doctor) must not pay for a library it never
# calls, the same discipline fm-beads-resilience-lib.sh applies to its own
# lazily-sourced lock library.
_FM_BEADS_TIMEOUT_LIB_LOADED=0
fm_beads_require_timeout_lib() {
  [ "$_FM_BEADS_TIMEOUT_LIB_LOADED" = 1 ] && return 0
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$lib_dir/fm-timeout-lib.sh"
  _FM_BEADS_TIMEOUT_LIB_LOADED=1
}

# fm_beads_sync_once - best-effort commit, push, then pull against the
# configured Dolt remote, printing one BEADS_SYNC: line per outcome.
#
# BEST-EFFORT IS THE CONTRACT, NOT A WEAKNESS. Every step is hard-bounded by
# fm_run_timed (exit 124 means the bound was hit) and every failure is a
# reported diagnostic, so an unreachable remote, a stalled network, or a broken
# Dolt server degrades to a printed line and never wedges the caller. The
# function returns non-zero only to tell the caller a step failed; the caller's
# own work continues either way.
#
# Order is commit, push, pull. The commit comes first because the default
# `--dolt-auto-commit` policy is `off`, so a home's writes sit in the Dolt
# working set and a push without it would publish nothing. Push precedes pull
# because durability - getting this home's own commits off this machine - is
# the gap being closed, and a pull failure must not prevent that.
fm_beads_sync_once() {
  local rc=0 step_rc
  command -v task >/dev/null 2>&1 || {
    echo "BEADS_SYNC: skipped: task CLI not found"
    return 1
  }
  if ! fm_beads_sync_configured; then
    echo "BEADS_SYNC: skipped: no Dolt remote configured, so this store is single-machine only"
    return 0
  fi
  fm_beads_require_timeout_lib

  # Each step captures its status with `|| step_rc=$?` rather than a bare call
  # followed by `$?`, so a failing step is exempt from `set -e` no matter which
  # caller sourced this library. Best-effort must not depend on the caller
  # happening to invoke this function inside an `if` or a `|| true`.
  step_rc=0
  fm_run_timed "$FM_BEADS_SYNC_TIMEOUT" task dolt commit >/dev/null 2>&1 || step_rc=$?
  # A clean working set makes `dolt commit` non-zero with nothing to do, which
  # is not a failure; only the timeout is reported, and push still runs because
  # previously committed work may still be unpushed.
  if [ "$step_rc" -eq 124 ]; then
    echo "BEADS_SYNC: commit failed: timed out after ${FM_BEADS_SYNC_TIMEOUT}s"
    rc=1
  fi

  step_rc=0
  fm_run_timed "$FM_BEADS_SYNC_TIMEOUT" task dolt push >/dev/null 2>&1 || step_rc=$?
  if [ "$step_rc" -eq 0 ]; then
    echo "BEADS_SYNC: pushed local commits to the configured Dolt remote"
  elif [ "$step_rc" -eq 124 ]; then
    echo "BEADS_SYNC: push failed: timed out after ${FM_BEADS_SYNC_TIMEOUT}s"
    rc=1
  else
    echo "BEADS_SYNC: push failed: 'task dolt push' exited $step_rc"
    rc=1
  fi

  step_rc=0
  fm_run_timed "$FM_BEADS_SYNC_TIMEOUT" task dolt pull >/dev/null 2>&1 || step_rc=$?
  if [ "$step_rc" -eq 0 ]; then
    echo "BEADS_SYNC: pulled remote commits into the local store"
  elif [ "$step_rc" -eq 124 ]; then
    echo "BEADS_SYNC: pull failed: timed out after ${FM_BEADS_SYNC_TIMEOUT}s"
    rc=1
  else
    echo "BEADS_SYNC: pull failed: 'task dolt pull' exited $step_rc"
    rc=1
  fi

  return "$rc"
}

# fm_beads_fleet_label - the label firstmate's own dispatched-work beads are
# meant to carry once bead creation is wired to it (beads-authority migration
# Stage 0; see data/beads-authority-migration-scout/report.md section 4 and
# docs/configuration.md "Backlog backend"). A `task list --label <this>` call
# scopes to firstmate's fleet instead of the shared federated store's full
# cross-project set. Multiple bin/ scripts call fm_beads_resolve_or_create to
# mint fleet-labeled beads: fm-decision-hold.sh (captain-hold anchor), fm-brief.sh
# (intake capture), and fm-spawn.sh (dispatch). fm-fleet-snapshot.sh and
# fm-bearings-snapshot.sh read it.
# FM_BEADS_FLEET_LABEL is an override for test fixtures; production code
# should call this function rather than hardcoding the label.
fm_beads_fleet_label() {
  printf '%s\n' "${FM_BEADS_FLEET_LABEL:-fleet:firstmate}"
}

# fm_beads_resolve_or_create <task_id> [title] - beads-authority migration
# Stage 3 (see data/beads-authority-migration-scout/report.md section "Stage
# 3"): under config/backlog-backend=beads, every firstmate task must have a
# linked bead without requiring an explicit --beads flag. Looks up an
# existing OPEN bead carrying the idempotency label "task:<task_id>" first (so
# fm-brief.sh and fm-spawn.sh converge on the same bead regardless of call
# order) and mints one with that label plus the fleet label
# (fm_beads_fleet_label) only if none is found. Echoes the resolved bead id on
# success. Fails open like the rest of the beads integration: prints nothing
# and returns 1 on any missing tool or failure, never blocking dispatch.
#
# A CLOSED bead is never adopted. Task ids are reusable slugs, and
# fm-teardown.sh closes a task's bead without stripping its "task:<id>" label,
# so that record outlives the task in the federated store forever. Adopting it
# would link brand-new work to a bead that was already closed before the task
# existed - and a closed bead is the authoritative "task complete" signal
# bin/fm-crew-state.sh reads under this backend, so the fresh crew would
# reconcile as done before its worker made a single commit. Omitting --all
# leaves the store's own default filter in place, so closed predecessors are
# excluded server side and no client-side ordering or page depth can decide
# the match.
fm_beads_resolve_or_create() {
  local task_id=$1 title=${2:-"firstmate: $1"} task_label existing id
  command -v task >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  task_label="task:$task_id"
  existing=$(task list --label "$task_label" --limit 1 --json 2>/dev/null) || existing=
  id=$(printf '%s' "$existing" \
    | jq -r 'if type=="array" and length>0 then .[0].id else empty end' 2>/dev/null) || id=
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  id=$(task create --title "$title" --labels "$(fm_beads_fleet_label),$task_label" --silent 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# fm_beads_status <bead-id> - the single owner of reading one bead's status.
# `task show <id> --json` returns a JSON ARRAY ([{...}]), so the status lives at
# .[0].status; every other bin/ reader of a single bead unwraps it the same way
# (fm-decision-hold.sh, fm-backlog-import-beads.sh). Prints the status token to
# stdout, or nothing when the bead is absent, unreadable, or the tools are
# missing. The read is bounded by FM_BEADS_STATUS_TIMEOUT so a wedged Dolt store
# can never stall a caller on the fleet-snapshot/heartbeat path - the same
# bounded-read discipline as FM_CREW_STATE_NM_TIMEOUT / FM_SNAPSHOT_BEADS_TIMEOUT.
#
# The EXIT STATUS distinguishes the three outcomes a caller must not conflate,
# because "the bead is gone" and "the read never completed" are opposite evidence:
#   0                            the read completed; stdout is the status token
#                                (empty when the record carries none)
#   FM_BEADS_STATUS_RC_ABSENT    the read completed and the bead is not there
#   FM_BEADS_STATUS_RC_UNREADABLE  no answer: timeout, missing tool, missing
#                                bound, unparseable output, or a store that could
#                                not be reached to confirm the bead is gone
#
# `task show` exits non-zero for a missing bead AND for a store that is down,
# locked, or unauthenticated, so a failed read alone cannot distinguish them. Only
# a reachable store turns a failed read into ABSENT: fm_beads_store_reachable
# re-probes with the same `task list --limit 1` liveness predicate the write-queue
# reconcile uses, and an unreachable store keeps the outcome UNREADABLE. The probe
# is paid only on the failure path, never on a successful read.
# Stdout still fails open in every non-zero case (nothing printed), so a caller
# that only reads stdout sees "not closed" / "no evidence" rather than a
# completion; a caller deciding whether a write is already applied must check the
# status too.
#
# The bound comes from fm-timeout-lib.sh, sourced only when it is co-located:
# this library is copied on its own into partially-synced remote code roots
# (bin/fm-remote-doctor.sh, bin/fm-backlog-receive.sh both run there under
# `set -eu`), and an unguarded source would abort those scripts at load time
# instead of letting them reach the report that names what is missing. Without
# the bound, fm_beads_status refuses the read rather than running it unbounded.
_FM_TASKS_AXI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f fm_run_timed >/dev/null 2>&1 && [ -f "$_FM_TASKS_AXI_LIB_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$_FM_TASKS_AXI_LIB_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound
fi
FM_BEADS_STATUS_TIMEOUT=${FM_BEADS_STATUS_TIMEOUT:-4}
case "$FM_BEADS_STATUS_TIMEOUT" in
  ''|*[!0-9]*) FM_BEADS_STATUS_TIMEOUT=4 ;;
  *) [ "$FM_BEADS_STATUS_TIMEOUT" -gt 0 ] 2>/dev/null || FM_BEADS_STATUS_TIMEOUT=4 ;;
esac
FM_BEADS_STATUS_RC_ABSENT=1
FM_BEADS_STATUS_RC_UNREADABLE=2

# fm_beads_store_reachable - bounded liveness probe for the beads store, the same
# `task list --limit 1` predicate fm_beads_write_queue_reconcile gates its whole
# replay on. True only when the store actually answered.
fm_beads_store_reachable() {
  command -v task >/dev/null 2>&1 || return 1
  declare -f fm_run_timed >/dev/null 2>&1 || return 1
  fm_run_timed "$FM_BEADS_STATUS_TIMEOUT" task list --limit 1 >/dev/null 2>&1
}

fm_beads_status() { # <bead-id> - print the bead's status token, empty if unreadable
  local id=${1:-} out rc status
  [ -n "$id" ] || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  command -v task >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  command -v jq >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  declare -f fm_run_timed >/dev/null 2>&1 || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  out=$(fm_run_timed "$FM_BEADS_STATUS_TIMEOUT" task show "$id" --json 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    fm_beads_store_reachable || return "$FM_BEADS_STATUS_RC_UNREADABLE"
    return "$FM_BEADS_STATUS_RC_ABSENT"
  fi
  status=$(printf '%s' "$out" | jq -r '.[0].status // empty' 2>/dev/null) \
    || return "$FM_BEADS_STATUS_RC_UNREADABLE"
  printf '%s\n' "$status"
}

# fm_beads_is_closed <bead-id> - true ONLY when the bead exists and its status is
# closed. This is the authoritative task-completion signal read by
# bin/fm-crew-state.sh under config/backlog-backend=beads: the worker closes its
# linked bead as the terminal lifecycle step before reporting done, and
# fm-teardown.sh/fm-ledger.sh close it on confirmed landing or drop-recovery, so a
# closed bead means the task is complete regardless of a stale status-event tail.
# Distinct from fm-beads-resilience-lib.sh's fm_beads_close_already_applied, which
# treats an ABSENT bead as "already applied" for idempotent write-queue replay:
# here an absent, open, or unreadable bead is NOT closed, so reconciliation falls
# through to the existing pane/run-step logic rather than inventing a completion.
# Reads status through fm_beads_status (the one array-unwrap owner) and treats
# every non-zero read - absent bead as much as an unanswered one - as "not
# closed", so it fails open the same way and never marks live work done.
fm_beads_is_closed() { # <bead-id>
  local id=${1:-} status
  [ -n "$id" ] || return 1
  status=$(fm_beads_status "$id") || return 1
  [ "$status" = closed ]
}
