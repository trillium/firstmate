#!/usr/bin/env bash
# Advisory scan for registered project clones whose remotes look like an
# unswapped or partially swapped fork-contribution setup: `origin` still
# points at the upstream repo the captain does not own, rather than the
# captain's own trillium/<repo> fork. See the project-management skill's
# "Fork-contribution projects" section for the required origin/upstream
# convention, and bin/fm-brief.sh for how a generated brief reacts to each
# clone shape at dispatch time.
#
# This is a read-only report, never a gate: it never blocks a spawn, edits a
# remote, or fails the build. Run it by hand when triaging suspected
# misconfigured clones (e.g. after an incident like the rango PR opened
# against upstream instead of the captain's fork).
#
# For each project in data/projects.md with a local clone under projects/:
#   - origin owned by trillium, no upstream remote  -> ordinary project, silent.
#   - origin owned by trillium, upstream remote set  -> correctly swapped
#     fork-contribution clone, silent (this is the target state).
#   - origin NOT owned by trillium, upstream remote set -> MISCONFIGURED:
#     the swap was started (upstream added) but never finished (origin still
#     points upstream). Always reported; no network call needed.
#   - origin NOT owned by trillium, no upstream remote -> possibly an
#     unswapped fork-contribution clone, or a genuinely non-Trillium project
#     with no fork relationship at all. Best-effort: report it only when
#     `trillium/<repo>` exists on GitHub and is itself a fork (via `gh`), so
#     an ordinary non-Trillium project with no fork counterpart stays silent.
#     A missing `gh` or a failed lookup is not an error - that project is
#     skipped rather than misreported.
#
# Usage: fm-fork-origin-check.sh
# Exit status is always 0; findings go to stdout, one per line.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

case "${1:-}" in
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

if [ ! -f "$REG" ]; then
  echo "no registry at $REG; nothing to check"
  exit 0
fi

owner_of() {
  local url=$1 rest owner
  url=${url%.git}
  url=${url%/}
  rest=${url%/*}
  owner=${rest##*/}
  owner=${owner##*:}
  printf '%s\n' "$owner" | tr '[:upper:]' '[:lower:]'
}

have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

found=0
while read -r name; do
  [ -n "$name" ] || continue
  dir="$PROJECTS/$name"
  [ -d "$dir" ] || continue
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
  [ -n "$origin" ] || continue
  upstream=$(git -C "$dir" remote get-url upstream 2>/dev/null) || upstream=""
  owner=$(owner_of "$origin")
  [ "$owner" = trillium ] && continue
  if [ -n "$upstream" ]; then
    echo "MISCONFIGURED: $name - origin ($origin) is not trillium but an upstream remote is set; finish the swap (project-management skill)"
    found=1
    continue
  fi
  [ "$have_gh" -eq 1 ] || continue
  is_fork=$(gh repo view "trillium/$name" --json isFork -q .isFork 2>/dev/null) || continue
  if [ "$is_fork" = "true" ]; then
    echo "CANDIDATE: $name - origin ($origin) is not trillium, and trillium/$name exists as a fork; likely needs the origin/upstream swap (project-management skill)"
    found=1
  fi
done <<EOF
$(awk '$1=="-"{print $2}' "$REG")
EOF

[ "$found" -eq 1 ] || echo "no misconfigured fork-contribution clones found"
exit 0
