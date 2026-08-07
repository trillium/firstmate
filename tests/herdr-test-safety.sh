#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

# Drop an inherited FM_HOME for the same reason tests/lib.sh does, which these
# suites cannot get from there because they never source it. Every bin/ script
# resolves "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}", so an ambient FM_HOME
# silently outranks the home a case means to exercise. For the Herdr backend
# that is not a config-path detail but a workspace-IDENTITY one:
# fm_backend_herdr_workspace_label reads "$FM_HOME/.fm-secondmate-home" and
# returns 2M-<scope> when it exists, so a captain box whose exported FM_HOME
# happens to be a SECONDMATE home labels this suite's primary workspace
# 2M-<that scope> instead of 1M-FIRSTMATE. Every assertion that pins the
# primary label, or that expects container_ensure to adopt a workspace a case
# pre-created as 1M-FIRSTMATE, then fails permanently on that box while CI -
# where FM_HOME is unset - stays green. Unsetting here makes the local
# environment match CI. Cases that genuinely need an FM_HOME set it per
# invocation (FM_HOME=... fm_backend_herdr_...), which this cannot affect.
unset FM_HOME

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
