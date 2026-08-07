#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Every ship and scout brief opens with a Parlay-enrollment section: the crewmate's
# first action is `parlay listen --agent <id>` (atomic, idempotent register + announce
# + monitor), run as a persistent background listener. Enrollment is best-effort and
# never load-bearing - if parlay is absent or the server is unreachable the crewmate
# notes it and works normally. Secondmate charters are exempt (they return work
# through the marked-status/corr channel).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab] [--beads <id>]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab] [--beads <id>]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   <repo-name> is a bare project name or "projects/<name>" resolving under
#   $FM_HOME/projects (or FM_PROJECTS_OVERRIDE), or an explicit absolute or
#   relative path. bin/fm-project-dir-lib.sh owns that mapping, shared with
#   fm-spawn.sh so a name that scaffolds here also spawns there.
#   An unrecognized --flag is rejected rather than taken as the repo name; pass
#   "--" first for the rare positional that must itself start with "--".
#   --beads <id> links the task to a beads issue and is passed to every hook in
#   fm-brief-hooks.d/ as FM_HOOK_BEADS_ID; the beads.sh hook there owns the
#   resulting brief content. Applies to ship and scout briefs only.
#   Before the Brief section is written, every executable in fm-brief-hooks.d/
#   runs (via `.`, in a subshell) with FM_HOOK_BEADS_ID and FM_HOOK_TASK_ID set;
#   each hook's captured stdout is prepended to the brief as its own section.
#   Absent or empty fm-brief-hooks.d/ is a no-op. This is the extension point
#   for out-of-tree brief content so this file stays a pure addition target.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# Hook system: when environment variables like FM_HOOK_BEADS_ID are set, executable
# scripts in fm-brief-hooks.d/ are sourced in a subshell during scaffolding, and their
# stdout is prepended to the generated brief. The beads hook (fm-brief-hooks.d/beads.sh)
# is automatically invoked when FM_HOOK_BEADS_ID is set, adding Bead Receipt and
# Bead Closure sections that ask the worker to confirm dispatch/lifecycle state changes
# and close the bead on completion. FM_HOOK_BEADS_ID is never auto-populated here: bead
# minting/resolution is deliberately deferred to fm-spawn.sh (beads-authority migration
# Stage 3), which is the point where a task is actually dispatched, so a brief that is
# scaffolded but never spawned never leaves an orphaned bead in the shared store. This
# section only renders when a caller sets FM_HOOK_BEADS_ID explicitly before scaffolding
# (the pre-existing --beads opt-in path); secondmate charters are exempt.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# Push-mode ship briefs (direct-PR, no-mistakes) on a fork-contribution
# project - one whose PRs must land in the captain's own trillium/<repo> fork
# and never reach the project's upstream - add an explicit anti-upstream
# PR-target rule. Detection reads the clone's real git remotes, never
# data/projects.md prose, and fires in two shapes: a legacy clone whose
# `origin` is still the upstream repo (the not-yet-swapped state the
# project-management skill's convention corrects), or the correct swapped
# setup where `origin` is already the trillium fork and a separate
# `upstream` remote proves the relationship. A Trillium origin with no
# `upstream` remote (an ordinary captain-owned project), an unreadable or
# absent origin, and every local-only brief add no such rule.
# Pushing to the fork does not by itself keep a PR off upstream: `gh pr
# create` and no-mistakes both default an opened PR's base to the upstream
# parent unless told otherwise, and no-mistakes always opens against whatever
# `origin` is configured to. On a legacy (unswapped) clone, no-mistakes mode
# cannot be driven safely at all - the brief tells the worker to stop and
# escalate rather than run it - because there is no flag that redirects the
# pipeline's PR target: `no-mistakes init --fork-url` pushes to the named
# fork while still opening the PR against `origin` (upstream), which is the
# CONTRIBUTING.md-documented "contribute upstream" flow, exactly backwards
# for a fork-contribution project. direct-PR mode instead gives the worker
# the explicit `gh pr create --repo trillium/<repo>` form, which works on
# either clone shape.
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns approval decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-project-dir-lib.sh
. "$SCRIPT_DIR/fm-project-dir-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
BEADS_ID=""
BEADS_SET=0
MODE=
MODE_SET=0
POS=()
want_value=
end_of_flags=0
for a in "$@"; do
  if [ "$end_of_flags" -eq 1 ]; then
    POS+=("$a")
    continue
  fi
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      beads) BEADS_ID=$a; BEADS_SET=1 ;;
      mode) MODE=$a; MODE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --beads) want_value=beads ;;
    --beads=*) BEADS_ID=${a#--beads=}; BEADS_SET=1 ;;
    -h|--help) usage; exit 0 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's approval authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's approval posture" >&2; exit 1 ;;
    # An unknown --flag is a caller mistake, never a positional: taking it as
    # the repo name scaffolds a brief for a project that does not exist, and the
    # only symptom is a "not in registry" warning that reads like a stale entry.
    # `--` ends flag parsing for the rare positional that must start with `--`.
    --) end_of_flags=1 ;;
    --*) echo "error: unknown option: $a" >&2; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$BEADS_SET" -eq 0 ] || [ -n "$BEADS_ID" ] || { echo "error: --beads requires a non-empty value" >&2; exit 1; }
# Named errors for missing positionals: under set -u a bare ${POS[n]} would
# instead die with "POS[0]: unbound variable" from an internal line number.
[ "${#POS[@]}" -ge 1 ] || {
  echo "error: missing <task-id>" >&2
  echo "usage: fm-brief.sh <task-id> <repo-name> [flags]   (--help for the full contract)" >&2
  exit 2
}
[ "$KIND" = secondmate ] || [ "${#POS[@]}" -ge 2 ] || {
  echo "error: missing <repo-name> for ${POS[0]}" >&2
  echo "usage: fm-brief.sh <task-id> <repo-name> [flags]   (--help for the full contract)" >&2
  exit 2
}

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
ID=${POS[0]}

case "$BEADS_ID" in
  ''|*[!A-Za-z0-9._-]*)
    [ -z "$BEADS_ID" ] || { echo "error: invalid --beads id" >&2; exit 1; }
    ;;
esac
if [ -n "$BEADS_ID" ] && [ "$KIND" = secondmate ]; then
  echo "error: --beads applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Resolve a project's clone directory exactly as the origin/upstream lookups
# below need it. The mapping itself lives in bin/fm-project-dir-lib.sh so this
# script and fm-spawn.sh cannot disagree about what a project string names -
# the drift that made a bare name scaffold here and then fail at spawn. No
# existence check: an absent clone must leave the lookups below silent, not
# refuse the scaffold.
project_clone_dir() {
  fm_project_dir_candidate "$1" "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
}

# Print "<trillium-repo-name> <state>" for a ship task's fork-contribution
# project, where <state> is "legacy" when `origin` is still the upstream repo
# the worker cannot push to, or "swapped" when `origin` is already the
# trillium fork and a separate `upstream` remote proves the fork-contribution
# relationship (the project-management skill's required setup). Prints
# nothing (and succeeds) for an ordinary captain-owned project - a Trillium
# origin with no `upstream` remote - or an unreadable or absent clone, so the
# generated brief stays unchanged in every case that is not a known fork
# relationship. Detection reads the clone's real git remotes, never
# data/projects.md prose.
fork_repo_for_origin() {
  local repo=$1 dir origin name rest owner upstream
  dir=$(project_clone_dir "$repo")
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  [ -n "$origin" ] || return 0
  origin=${origin%.git}
  origin=${origin%/}
  name=${origin##*/}
  rest=${origin%/*}
  owner=${rest##*/}     # https://host/owner/repo -> owner
  owner=${owner##*:}    # git@host:owner/repo    -> owner
  [ -n "$name" ] || return 0
  if [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = trillium ]; then
    # origin already is the trillium fork; still a fork-contribution project
    # (and the anti-upstream PR-target rule still applies) only when a
    # separate `upstream` remote proves the relationship.
    upstream=$(git -C "$dir" remote get-url upstream 2>/dev/null) || return 0
    [ -n "$upstream" ] || return 0
    printf '%s swapped\n' "$name"
    return 0
  fi
  printf '%s legacy\n' "$name"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

# beads-authority migration Stage 3 (data/beads-authority-migration-scout/report.md
# "Stage 3"): bead minting/resolution under config/backlog-backend=beads happens only
# in fm-spawn.sh, at actual dispatch time, not here. Minting here at scaffold time
# would create a bead the moment a brief is written, before the task is ever spawned;
# if the captain declines after review or spawn fails, that bead would be permanently
# orphaned in the shared store since no state/<id>.meta ever records its beads_id= for
# fm-teardown.sh to close. FM_HOOK_BEADS_ID is therefore left exactly as the caller set
# it (unset unless an explicit --beads workflow pre-populated it).

# Hook system (see header comment above): scripts in fm-brief-hooks.d/ are sourced
# in a subshell, and any stdout they produce is collected into HOOK_SECTION and
# inserted into the generated brief. Each hook is self-gating (e.g. the beads hook
# below exits with no output when FM_HOOK_BEADS_ID is unset), so HOOK_SECTION stays
# empty and briefs are unchanged when no hook has anything to add.
# An explicit --beads workflow pre-populates FM_HOOK_BEADS_ID here; otherwise it is
# left exactly as the caller already set it (see the Stage 3 comment above).
[ -z "$BEADS_ID" ] || export FM_HOOK_BEADS_ID="$BEADS_ID"
export FM_HOOK_TASK_ID="$ID"
HOOK_SECTION=""
for hook in "$SCRIPT_DIR"/fm-brief-hooks.d/*.sh; do
  [ -e "$hook" ] || continue
  # shellcheck disable=SC1090
  hook_out=$(. "$hook") || continue
  [ -n "$hook_out" ] || continue
  if [ -n "$HOOK_SECTION" ]; then
    HOOK_SECTION="$HOOK_SECTION"$'\n\n'"$hook_out"
  else
    HOOK_SECTION="$hook_out"
  fi
done

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi
[ -z "$HOOK_SECTION" ] || HERDR_SECTION="$HERDR_SECTION"$'\n\n'"$HOOK_SECTION"

# Best-effort Parlay enrollment: the crewmate's first action is to self-enroll in
# Parlay so firstmate can reach it and it can report back. `parlay listen --agent
# <id>` is the atomic, idempotent one-call enrollment (register + announce + monitor);
# `parlay listen --help` documents the canonical persistent Monitor-tool form. Like
# the spawn-side chat-panel registration (fm-spawn.sh), it is best-effort and never
# load-bearing: if parlay is absent or the server is unreachable, the crewmate notes
# the warning and works normally, never blocking on a missing coordination channel.
# Injected as the first section of every ship and scout brief; secondmate charters are
# exempt because a secondmate runs its own firstmate home and returns work through the
# marked-status/corr channel, not the shared panel. The $(printf ...) builder is
# Bash 3.2 parse-safe: no heredoc is nested in the command substitution
# (tests/fm-brief.test.sh guards that shape).
# shellcheck disable=SC2016  # single quotes are deliberate: backtick-wrapped commands and the Monitor snippet must reach the reading agent verbatim; only the '"$ID"' break-outs interpolate the task id.
PARLAY_SECTION=$(printf '%s\n' \
'# FIRST ACTION: enroll in Parlay' \
'Start by enrolling in Parlay so firstmate can reach you and you can report back; this only starts a background listener and touches nothing in the repo, so the Setup isolation check below still governs every repo action.' \
'Enrollment is one atomic, idempotent call that registers you, announces you are listening, and streams firstmate'"'"'s messages to you: `parlay listen --agent '"$ID"'`.' \
'Run it as a persistent background listener that stays alive for the whole task: under a harness with a Monitor tool that is `Monitor({ command: "parlay listen --agent '"$ID"'", persistent: true })`, otherwise start it in the background and keep it running.' \
'Enrollment is best-effort, never a blocker: if parlay is not installed or the Parlay server is unreachable, note the warning briefly and continue with your task normally - do not stop and do not append a blocked status. A missing coordination channel is not a failure.')

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

$PARLAY_SECTION

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. You have no terminal a human can type into, so never let git open an editor. Pass \`-m\` or
   \`--no-edit\`, or prefix the command with \`GIT_EDITOR=true\` (\`GIT_SEQUENCE_EDITOR=true\` for
   \`rebase -i\`). If a git command produces no output for more than a minute, suspect a blocked
   editor waiting on a human, not a slow operation: check with \`pgrep -fl 'COMMIT_EDITMSG|--wait'\`
   and kill the waiter rather than retrying, since each retry stacks another orphaned waiter.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

# Fork-contribution PR-target rule: a project whose PRs must land in the
# captain's own trillium/<repo> fork, never the upstream project it was
# forked from. Only direct-PR and no-mistakes push or open a PR; local-only
# never does, so it is exempt. Rule text lives here exactly once and is empty
# (no rule) for local-only and for every ordinary captain-owned project,
# keeping those briefs byte-identical to the pre-rule output.
#
# Pushing to the fork does not by itself keep the PR off upstream: `gh pr
# create` and no-mistakes both default an opened PR's base to the upstream
# parent unless told otherwise. direct-PR mode gets an explicit `--repo`
# override that works on either clone shape. no-mistakes mode has no such
# override - it always opens against whatever `origin` is configured to - so
# a legacy (unswapped) clone cannot be driven safely at all; the worker is
# told to stop and escalate instead.
FORK_FIRST=""
if [ "$MODE" != local-only ]; then
  FORK_REPO=""
  FORK_STATE=""
  read -r FORK_REPO FORK_STATE <<EOF
$(fork_repo_for_origin "$REPO")
EOF
  if [ -n "$FORK_REPO" ]; then
    FORK_HEADLINE="# Fork-based project: PRs stay in the fork, never upstream"
    FORK_TARGET_RULE="This project's PRs must land in the captain's own \`trillium/$FORK_REPO\` fork, NEVER upstream; the PR only goes upstream on the captain's explicit word."
    if [ "$MODE" = direct-PR ]; then
      IFS= read -r -d '' FORK_FIRST <<EOF || true

$FORK_HEADLINE
$FORK_TARGET_RULE
If the fork does not exist yet, create it with \`gh-axi\` before pushing.
Push your branch to the fork - \`git push git@github.com:trillium/$FORK_REPO.git fm/$ID:fm/$ID\` if \`origin\` here is still upstream, or plain \`git push origin fm/$ID\` once \`origin\` is the fork.
Open the PR with an explicit repo override so it can never default to upstream: \`gh pr create --repo trillium/$FORK_REPO --base <fork-default-branch> --head fm/$ID\`.
Never omit that \`--repo trillium/$FORK_REPO\` override, and never stop to ask fork-vs-local: always target the fork.
**CRITICAL:** a PR opened against the upstream repo must NEVER happen automatically. If targeting the fork is not possible, stop and get direct captain confirmation before any upstream PR attempt.
EOF
    elif [ "$FORK_STATE" = swapped ]; then
      IFS= read -r -d '' FORK_FIRST <<EOF || true

$FORK_HEADLINE
$FORK_TARGET_RULE
\`origin\` here is already the \`trillium/$FORK_REPO\` fork, with \`upstream\` as a separate remote, so no-mistakes's normal PR-open behavior already targets the fork - do not change that.
Never run \`no-mistakes init --fork-url\` or any similar remote reconfiguration on this project: that flag pushes to the named fork while still opening the PR against \`origin\`, which is the exact wrong direction here.
Never stop to ask fork-vs-local: always target the fork.
**CRITICAL:** if no-mistakes ever proposes or opens a PR against anything other than \`trillium/$FORK_REPO\`, stop and escalate immediately rather than letting it proceed.
EOF
    else
      IFS= read -r -d '' FORK_FIRST <<EOF || true

# Fork-based project: origin is not yet the fork - STOP before running no-mistakes
$FORK_TARGET_RULE
\`origin\` here is still the upstream repository, not the \`trillium/$FORK_REPO\` fork. no-mistakes opens its PR against whatever \`origin\` is configured to, so running it now would open the PR against upstream.
This clone's remotes need the captain-approved origin swap (origin -> the \`trillium/$FORK_REPO\` fork, upstream -> the current origin) before no-mistakes can run safely here; that change is outside this task's worktree.
Do NOT run \`no-mistakes init --fork-url\` as a workaround: it pushes to the named fork while still opening the PR against \`origin\` (upstream), reproducing the same failure.
Append \`blocked: project clone's origin is not the trillium fork yet, no-mistakes would target upstream\` and stop; do not attempt any workaround that could open a PR against upstream.
EOF
    fi
  fi
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

$PARLAY_SECTION

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. You have no terminal a human can type into, so never let git open an editor. Pass \`-m\` or
   \`--no-edit\`, or prefix the command with \`GIT_EDITOR=true\` (\`GIT_SEQUENCE_EDITOR=true\` for
   \`rebase -i\`). This covers \`commit\` without \`-m\`, \`rebase --continue\`/\`-i\`, non-fast-forward
   \`merge\`, \`revert\`, \`tag -a\`, and \`cherry-pick --continue\`. If a git command produces no output
   for more than a minute, suspect a blocked editor waiting on a human, not a slow operation:
   check with \`pgrep -fl 'COMMIT_EDITMSG|--wait'\` and kill the waiter rather than retrying, since
   each retry stacks another orphaned waiter.
9. If git refuses because your branch is already checked out in another worktree, do NOT remove
   or modify that worktree - it may hold another agent's uncommitted work. Use a detached HEAD
   instead: \`git checkout --detach\`, work there, and - where rule 1 permits pushing at all -
   push explicitly with \`git push --force-with-lease origin HEAD:fm/$ID\`. If that is not
   possible, append \`blocked: {why}\` and stop.
$FORK_FIRST
# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
