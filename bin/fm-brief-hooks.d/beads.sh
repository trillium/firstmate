#!/usr/bin/env bash
# fm-brief.sh hook: when FM_HOOK_BEADS_ID is set, emit the Bead Receipt,
# Bead Report Landing, and Bead Closure brief sections. Sourced by fm-brief.sh
# inside a subshell, which captures this script's stdout and prepends it to the
# generated brief. fm-spawn.sh re-runs this same hook loop for auto-linked
# beads and splices the output into the brief before "# Setup".
# A bare `exit 0` below only ends that subshell, never fm-brief.sh itself.
set -u

[ -n "${FM_HOOK_BEADS_ID:-}" ] || exit 0

cat <<SECTION
# Bead Receipt
This task is linked to bead \`$FM_HOOK_BEADS_ID\`.
Before anything else - your first action, before the setup below - prove you received and read this brief:
\`\`\`
task set-state $FM_HOOK_BEADS_ID dispatch=claimed --reason 'brief read and accepted'
task set-state $FM_HOOK_BEADS_ID lifecycle=claimed --reason 'brief read and accepted'
\`\`\`

# Bead Report Landing
Land the deliverable content in the linked bead as well, not only in \`data/\` paths or brain docs.
For a scout, post the report content.
For a ship, post the deliverable summary plus PR and test evidence.
Use \`task comment $FM_HOOK_BEADS_ID --file <file>\` (or \`task comment $FM_HOOK_BEADS_ID <text>\` for short content), chunked into multiple comments as needed so no single call is oversized.
Do this before the Bead Closure step below, so the content lands while the bead is still open.

# Bead Closure
Before appending \`done:\` to the status file, close this bead: \`task close $FM_HOOK_BEADS_ID\`.
That closure is what a registered watcher check uses to trigger your cleanup - do this as the last step before reporting done.
If you cannot reach this step, do not worry about it further: firstmate closes this bead automatically once your work is confirmed landed and this task is torn down.
SECTION
