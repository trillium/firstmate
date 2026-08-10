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

# fm_beads_fleet_label - the label firstmate's own dispatched-work beads are
# meant to carry once bead creation is wired to it (beads-authority migration
# Stage 0; see data/beads-authority-migration-scout/report.md section 4 and
# docs/configuration.md "Backlog backend"). A `task list --label <this>` call
# scopes to firstmate's fleet instead of the shared federated store's full
# cross-project set. As of Stage 4, fm-decision-hold.sh's beads-native
# captain-hold anchor is the only bin/ code that creates a bead with this
# label; fm-fleet-snapshot.sh and fm-bearings-snapshot.sh read it.
# FM_BEADS_FLEET_LABEL is an override for test fixtures; production code
# should call this function rather than hardcoding the label.
fm_beads_fleet_label() {
  printf '%s\n' "${FM_BEADS_FLEET_LABEL:-fleet:firstmate}"
}

# fm_beads_resolve_or_create <task_id> [title] - beads-authority migration
# Stage 3 (see data/beads-authority-migration-scout/report.md section "Stage
# 3"): under config/backlog-backend=beads, every firstmate task must have a
# linked bead without requiring an explicit --beads flag. Looks up an
# existing bead carrying the idempotency label "task:<task_id>" first (so
# fm-brief.sh and fm-spawn.sh converge on the same bead regardless of call
# order) and mints one with that label plus the fleet label
# (fm_beads_fleet_label) only if none is found. Echoes the resolved bead id on
# success. Fails open like the rest of the beads integration: prints nothing
# and returns 1 on any missing tool or failure, never blocking dispatch.
fm_beads_resolve_or_create() {
  local task_id=$1 title=${2:-"firstmate: $1"} task_label existing id
  command -v task >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  task_label="task:$task_id"
  existing=$(task list --label "$task_label" --all --limit 1 --json 2>/dev/null) || existing=
  id=$(printf '%s' "$existing" | jq -r 'if type=="array" and length>0 then .[0].id else empty end' 2>/dev/null) || id=
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  id=$(task create --title "$title" --labels "$(fm_beads_fleet_label),$task_label" --silent 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}
