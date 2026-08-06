#!/usr/bin/env bash
# fm-project-dir-lib.sh - the single definition of how a project argument names
# a clone directory.
#
# Both halves of a dispatch take the same project string: fm-brief.sh scaffolds
# the brief, fm-spawn.sh launches against the clone. Before this library they
# disagreed - fm-brief.sh accepted a bare name (resolving it under projects/),
# fm-spawn.sh only rewrote an argument that already began with "projects/" and
# handed a bare name straight to `cd`, which then resolved it against the
# process cwd. The mismatch was silent until spawn died with a raw
# "cd: <name>: No such file or directory" from an internal line number.
#
# The mapping is deliberately one function so the two callers cannot drift
# again. Existence checking is a separate layer, because fm-brief.sh needs the
# candidate path for a best-effort git-remote read on a clone that may not be
# there, while fm-spawn.sh must refuse loudly.
#
# Source it:
#   # shellcheck source=bin/fm-project-dir-lib.sh
#   . "$SCRIPT_DIR/fm-project-dir-lib.sh"

# Map a project argument to its candidate clone directory. No filesystem access.
#   /abs/path      -> itself (an explicit absolute path always wins)
#   projects/<name>-> <projects-dir>/<name>
#   ./x, ../x, a/b -> itself (an explicit relative path always wins)
#   <name>         -> <projects-dir>/<name>
fm_project_dir_candidate() {
  local arg=$1 projects=$2
  case "$arg" in
    /*) printf '%s\n' "$arg" ;;
    projects/*) printf '%s/%s\n' "$projects" "${arg#projects/}" ;;
    .|..|./*|../*|*/*) printf '%s\n' "$arg" ;;
    *) printf '%s/%s\n' "$projects" "$arg" ;;
  esac
}

# Fold a project name to its comparison key: lowercase, separators removed, so
# "Herdr-Web", "herdr_web", and "herdrweb" all collapse to "herdrweb" and a
# typo in the separators still finds the clone the caller meant.
fm_project_dir_fold() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_.-'
}

# Print up to three registry-style suggestions for an unresolvable name: clones
# under <projects-dir> whose folded name contains, or is contained by, the
# folded argument. Prints nothing when nothing is close enough, so the caller's
# error message stays quiet rather than guessing.
fm_project_dir_suggestions() {
  local arg=$1 projects=$2 key entry name entry_key shown=0
  [ -d "$projects" ] || return 0
  key=$(fm_project_dir_fold "$arg")
  [ -n "$key" ] || return 0
  for entry in "$projects"/*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}
    entry_key=$(fm_project_dir_fold "$name")
    [ -n "$entry_key" ] || continue
    case "$entry_key" in
      *"$key"*) ;;
      *) case "$key" in *"$entry_key"*) ;; *) continue ;; esac ;;
    esac
    printf 'projects/%s\n' "$name"
    shown=$((shown + 1))
    [ "$shown" -lt 3 ] || break
  done
}

# Resolve a project argument to an existing clone directory, or fail with a
# named error naming what was tried. A bare name resolves under <projects-dir>
# first and falls back to a cwd-relative directory of the same name, so the
# pre-existing "run it from the directory above the clone" habit keeps working.
# Prints the resolved (non-canonicalized) directory on stdout.
fm_resolve_project_dir() {
  local arg=$1 projects=$2 label=${3:-project} candidate suggestion
  if [ -z "$arg" ]; then
    echo "error: no $label given" >&2
    return 1
  fi
  candidate=$(fm_project_dir_candidate "$arg" "$projects")
  if [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Bare name that is not under projects/: accept a cwd-relative directory of
  # that name, which is what the old pass-through behavior effectively allowed.
  if [ "$candidate" != "$arg" ] && [ -d "$arg" ]; then
    printf '%s\n' "$arg"
    return 0
  fi
  {
    echo "error: $label not found: $arg"
    echo "  tried: $candidate"
    [ "$candidate" = "$arg" ] || echo "  tried: $arg (relative to $PWD)"
    while IFS= read -r suggestion; do
      [ -n "$suggestion" ] || continue
      echo "  did you mean $suggestion ?"
    done <<EOF
$(fm_project_dir_suggestions "$arg" "$projects")
EOF
  } >&2
  return 1
}
