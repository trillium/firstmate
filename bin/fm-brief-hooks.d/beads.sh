#!/usr/bin/env bash
# fm-brief.sh hook: when FM_HOOK_BEADS_ID is set, emit the Bead Receipt and
# Bead Closure brief sections. Sourced by fm-brief.sh inside a subshell, which
# captures this script's stdout and prepends it to the generated brief.
# A bare `exit 0` below only ends that subshell, never fm-brief.sh itself.
set -u

[ -n "${FM_HOOK_BEADS_ID:-}" ] || exit 0

cat <<SECTION
# Bead Receipt
This task is linked to bead \`$FM_HOOK_BEADS_ID\`.
Before anything else - your first action, before the setup below - prove you received and read this brief:
\`\`\`
task set-state $FM_HOOK_BEADS_ID dispatch=claimed --reason 'brief read and accepted'
\`\`\`

# Bead Closure
Before appending \`done:\` to the status file, close this bead: \`task close $FM_HOOK_BEADS_ID\`.
That closure is what a registered watcher check uses to trigger your cleanup - do this as the last step before reporting done.
SECTION
