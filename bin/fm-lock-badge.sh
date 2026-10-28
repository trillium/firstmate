#!/usr/bin/env bash
# Mark this pane in the herdr sidebar with the session-lock outcome.
#
# Usage: fm-lock-badge.sh held | refused | clear
#
# Called by bin/fm-lock.sh after it decides ownership, so two primary firstmate
# panes (same harness, same agent colour) are told apart by lock state:
#   held     sets sidebar token $hs_lock_held and display-agent "firstmate (lock)",
#            and drops $hs_lock_ro.
#   refused  sets sidebar token $hs_lock_ro and display-agent "firstmate (read-only)",
#            and drops $hs_lock_held.
#   clear    drops both tokens and the display-agent override.
# The colour comes from the captain's herdr sidebar row config, which gives each
# token its own fg (docs/herdr-backend.md "Session-lock badge"); this script only
# reports the text. It reports under its own --source so it never touches the
# agent lifecycle state herdr derives from the harness.
# Best-effort and display-only: outside herdr (no HERDR_PANE_ID), without a herdr
# binary, or on any herdr error it exits 0 and never changes lock behavior.
set -u

mode=${1:-}
case "$mode" in held | refused | clear) ;; *)
  echo "usage: fm-lock-badge.sh held|refused|clear" >&2
  exit 2
  ;;
esac

[ -n "${HERDR_PANE_ID:-}" ] || exit 0
herdr_bin=${HERDR_BIN_PATH:-herdr}
command -v "$herdr_bin" >/dev/null 2>&1 || exit 0

args=(pane report-metadata --source firstmate-lock)
case "$mode" in
  held) args+=(--token lock_held=LOCK --clear-token lock_ro --display-agent "firstmate (lock)") ;;
  refused) args+=(--token lock_ro=READ-ONLY --clear-token lock_held --display-agent "firstmate (read-only)") ;;
  clear) args+=(--clear-token lock_held --clear-token lock_ro --clear-display-agent) ;;
esac

"$herdr_bin" "${args[@]}" "$HERDR_PANE_ID" >/dev/null 2>&1 || true
exit 0
