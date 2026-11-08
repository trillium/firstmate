# shellcheck shell=bash
# Abort-reason fallback for scripts that run under `set -e`.
# Usage: set -eu; . bin/fm-abort-reason-lib.sh; fm_abort_reason_install <label>
#
# A command that fails outside an `if`/`||`/`&&` context ends a `set -e` script
# without a word, so a caller that only sees the exit status cannot tell what
# failed. Installing this records the failing command and line from the ERR
# trap and, when the script then exits non-zero by that very abort, prints one
# `error:` line naming them on stderr. A path that already printed its own
# reason and called `exit` never reaches the ERR trap, so it is not doubled.
#
# The EXIT trap is installed here; a script with its own EXIT cleanup calls
# fm_abort_reason_report from that cleanup instead of installing a second trap.
set -E
FM_ABORT_REASON_LABEL=
FM_ABORT_REASON_RC=
FM_ABORT_REASON_AT=

fm_abort_reason_install() { # <label>
  FM_ABORT_REASON_LABEL=$1
  # shellcheck disable=SC2154
  trap 'FM_ABORT_REASON_RC=$?; FM_ABORT_REASON_AT="line ${LINENO:-?}: ${BASH_COMMAND:-?}"' ERR
  trap 'fm_abort_reason_report $?' EXIT
}

# fm_abort_reason_report <exit-status>: print the recorded abort, if this exit
# is that abort. Safe to call from any EXIT cleanup.
fm_abort_reason_report() {
  local rc=$1
  [ "$rc" -ne 0 ] || return 0
  [ -n "$FM_ABORT_REASON_AT" ] || return 0
  [ "$rc" = "$FM_ABORT_REASON_RC" ] || return 0
  printf 'error: %s aborted with exit %s and no other reason was reported; failing command at %s\n' \
    "${FM_ABORT_REASON_LABEL:-script}" "$rc" "$FM_ABORT_REASON_AT" >&2
  FM_ABORT_REASON_AT=
}
