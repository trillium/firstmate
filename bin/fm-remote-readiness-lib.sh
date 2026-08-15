#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# A gap that does not gate readiness still gets repaired. The doctor prints
# `repairable-advisory: <check>` for a non-gating gap --fix can close, and this
# gate runs its repair pass on that line even though the read-only run exited
# 0. Otherwise the only automatic provisioning path would be reachable solely
# on hosts that are broken in some OTHER way, and a host whose sole gap is the
# one a repair can close would keep it forever.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_has_repairable_advisory() { # <doctor output>
  case "$1" in *'repairable-advisory: '*) return 0 ;; esac
  return 1
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  if [ "$rc" -eq 0 ]; then
    fm_remote_readiness_has_repairable_advisory "$out" || return 0
  fi

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
