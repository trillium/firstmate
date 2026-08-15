#!/usr/bin/env bash
# fm-test-affected.sh - static test-impact selector for pull-request CI.
#
# Prints the tests/*.test.sh scripts a set of changed paths could affect, one
# per line, LC_ALL=C sorted. bin/fm-test-run.sh consumes that list through
# --only-from, which intersects it with a lane's own composition, so this
# script never learns lane or shard membership and cannot drift from it.
#
# Usage:
#   fm-test-affected.sh [--event <name>] [--base <ref>]
#                       [--path <p>]... [--paths-from <file>]
#                       [--out <file>] [--explain]
#
# HARD SAFETY RULE: narrowing happens ONLY for a pull request. The resolved
# event is --event, else $GITHUB_EVENT_NAME, else empty; anything other than
# the exact string "pull_request" prints the COMPLETE inventory. A push to the
# default branch therefore keeps running the whole regression suite. Every test
# selector is occasionally wrong, and that unconditional full run on merge is
# what makes being occasionally wrong survivable; a design where a
# pull-request subset becomes the only thing that ever runs is a failed design.
# Run it locally with --event pull_request to see what a pull request selects.
#
# Options:
#   --event <name>  event to select for (default: $GITHUB_EVENT_NAME, else none)
#   --base <ref>    git ref the changed set is computed against (default:
#                   origin/main). Ignored when paths are supplied explicitly.
#   --path <p>      treat <p> as changed (repeatable); suppresses git derivation
#   --paths-from <file>
#                   read changed paths from <file>, one per line ("-" = stdin);
#                   also suppresses git derivation
#   --out <file>    write the list to <file> instead of stdout
#   --explain       print one "path -> reason" line per changed path to stderr
#   -h, --help      print this header
#
# Selection rules, applied to each changed path in order. Any rule that reaches
# the complete inventory ends the whole run: it is a decision about the run,
# not about one path.
#   1. bin/fm-test-run.sh, bin/fm-test-affected.sh,
#      bin/fm-test-isolation-proof.sh, or .github/workflows/* -> COMPLETE
#      inventory. These own or gate suite composition, so changing any of them
#      invalidates the selection itself.
#   2. tests/<name>.test.sh -> that script alone (nothing, if it was deleted).
#   3. Any other tests/ path - lib.sh, *-helpers.sh, *-test-safety.sh,
#      fixtures/, the .py helper - is shared test infrastructure -> COMPLETE
#      inventory.
#   4. Anything else -> every test whose text names the path or its basename.
#      For a bin/ script the seed set first grows over the transitive reverse
#      source-chain closure, so changing a library also selects the tests that
#      only name the scripts sourcing it. Indirect dependencies are the main
#      correctness risk here: over-selection costs minutes, under-selection
#      ships a regression.
#   5. A path rule 4 matched nothing for -> COMPLETE inventory, unless it is one
#      of the declared inert paths (docs, README, LICENSE, assets, skills,
#      persona, remaining .github metadata) that no test can depend on.
#
# The static map is deliberately grep-based. Runtime coverage instrumentation
# is the documented upgrade path if this proves too coarse; it is not used here.
#
# Exit status is 0 on success and 2 on a usage or environment error. An error
# never narrows silently: the caller gets a diagnostic and no list at all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

RUNNER="$ROOT/bin/fm-test-run.sh"

EVENT=${GITHUB_EVENT_NAME:-}
BASE_REF=origin/main
OUT=
EXPLAIN=0
PATHS_EXPLICIT=0
CHANGED=()
EDGES=
SELECTED=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-affected: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-affected: %s\n' "$*" >&2
}

explain() {
  [ "$EXPLAIN" -eq 1 ] || return 0
  printf 'fm-test-affected: %s -> %s\n' "$1" "$2" >&2
}

cleanup() {
  [ -z "$EDGES" ] || rm -f "$EDGES"
  [ -z "$SELECTED" ] || rm -f "$SELECTED"
}
trap cleanup EXIT

count_lines() {
  if [ -z "$1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

# The suite inventory has exactly one owner: bin/fm-test-run.sh.
inventory() {
  "$RUNNER" --list --all
}

emit_list() {
  local list=$1
  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    if [ -z "$list" ]; then
      : >"$OUT"
    else
      printf '%s\n' "$list" >"$OUT"
    fi
  elif [ -n "$list" ]; then
    printf '%s\n' "$list"
  fi
}

# Terminal: print the whole suite and stop. Reached whenever anything about the
# change set makes a narrowed answer untrustworthy.
full_suite() {
  local reason=$1 list
  list=$(inventory)
  log "full suite: $reason"
  emit_list "$list"
  log "selected $(count_lines "$list") of $(count_lines "$list") tests (event=${EVENT:-none})"
  exit 0
}

# "<sourced basename>\t<sourcing basename>" for every source/. line in bin/.
# Built once per run; the closure below walks it in the reverse direction.
build_source_edges() {
  local f
  local -a srcs=()
  [ -z "$EDGES" ] || return 0
  EDGES=$(mktemp "${TMPDIR:-/tmp}/fm-test-affected-edges.XXXXXX")
  for f in bin/*.sh bin/backends/*.sh; do
    [ -f "$f" ] || continue
    srcs+=("$f")
  done
  [ "${#srcs[@]}" -gt 0 ] || return 0
  awk '
    { consumer = FILENAME; sub(/.*\//, "", consumer) }
    /^[[:space:]]*(\.|source)[[:space:]]/ {
      n = split($0, tok, /[^A-Za-z0-9_.\/-]+/)
      for (i = 1; i <= n; i++) {
        dep = tok[i]
        if (dep !~ /\.sh$/) continue
        sub(/.*\//, "", dep)
        if (dep == consumer) continue
        print dep "\t" consumer
      }
    }
  ' "${srcs[@]}" | LC_ALL=C sort -u >"$EDGES"
}

# Every bin/ basename that reaches <basename> through one or more source edges,
# including <basename> itself. Transitive, so a library two hops below a tested
# entry point still selects that entry point's tests.
reverse_source_closure() {
  local start=$1 current consumer seen_it s
  local -a pending=("$start")
  local -a seen=()
  build_source_edges
  while [ "${#pending[@]}" -gt 0 ]; do
    current=${pending[0]}
    pending=("${pending[@]:1}")
    seen_it=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      if [ "$s" = "$current" ]; then
        seen_it=1
        break
      fi
    done
    if [ "$seen_it" -eq 1 ]; then
      continue
    fi
    seen+=("$current")
    if [ -s "$EDGES" ]; then
      while IFS=$'\t' read -r _dep consumer; do
        [ -n "$consumer" ] || continue
        pending+=("$consumer")
      done < <(awk -F'\t' -v d="$current" '$1 == d' "$EDGES")
    fi
  done
  printf '%s\n' "${seen[@]}"
}

# Inventory tests whose text contains any seed as a fixed string.
tests_referencing() {
  local seed
  local -a args=()
  for seed in "$@"; do
    args+=(-e "$seed")
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  [ "${#INVENTORY[@]}" -gt 0 ] || return 0
  grep -Fl "${args[@]}" -- "${INVENTORY[@]}" 2>/dev/null || true
}

select_for_path() {
  local path=$1 base dep matched
  local -a seeds=()

  case "$path" in
    # Rule 1: these own or gate what the suite is, so a narrowed answer
    # computed from them cannot be trusted.
    bin/fm-test-run.sh|bin/fm-test-affected.sh|bin/fm-test-isolation-proof.sh)
      full_suite "$path owns or gates suite selection"
      ;;
    .github/workflows/*)
      full_suite "$path changes how CI runs the suite"
      ;;
    # Rule 2.
    tests/*.test.sh)
      if [ -f "$path" ]; then
        printf '%s\n' "$path" >>"$SELECTED"
        explain "$path" "the changed test itself"
      else
        explain "$path" "deleted test, nothing left to run"
      fi
      return 0
      ;;
    # Rule 3.
    tests/*)
      full_suite "$path is shared test infrastructure"
      ;;
  esac

  # Rule 4.
  base=${path##*/}
  seeds=("$path")
  if [ "$base" != "$path" ]; then
    seeds+=("$base")
  fi
  case "$path" in
    bin/*)
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        [ "$dep" != "$base" ] || continue
        seeds+=("$dep")
      done < <(reverse_source_closure "$base")
      ;;
  esac

  matched=$(tests_referencing "${seeds[@]}")
  if [ -n "$matched" ]; then
    printf '%s\n' "$matched" >>"$SELECTED"
    explain "$path" "$(count_lines "$matched") test(s) naming it or a script sourcing it"
    return 0
  fi

  # Rule 5.
  case "$path" in
    README.md|LICENSE|LICENSE.*|persona.md|.gitignore|.gitattributes|\
    assets/*|docs/*|.agents/skills/*|skills/*|.github/*)
      explain "$path" "no test depends on it (declared inert)"
      return 0
      ;;
  esac
  full_suite "no test maps to changed path $path"
}

git_changed_paths() {
  local base=$1
  git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1 || return 1
  {
    git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null || true
    git -C "$ROOT" diff --name-only HEAD 2>/dev/null || true
    git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null || true
  } | LC_ALL=C sort -u
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -gt 1 ] || die "--event requires a name"
      EVENT=$2
      shift 2
      ;;
    --event=*)
      EVENT=${1#--event=}
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --path)
      [ "$#" -gt 1 ] || die "--path requires a path"
      CHANGED+=("$2")
      PATHS_EXPLICIT=1
      shift 2
      ;;
    --path=*)
      CHANGED+=("${1#--path=}")
      PATHS_EXPLICIT=1
      shift
      ;;
    --paths-from)
      [ "$#" -gt 1 ] || die "--paths-from requires a file or -"
      PATHS_FROM=$2
      PATHS_EXPLICIT=1
      shift 2
      ;;
    --paths-from=*)
      PATHS_FROM=${1#--paths-from=}
      PATHS_EXPLICIT=1
      shift
      ;;
    --out)
      [ "$#" -gt 1 ] || die "--out requires a path"
      OUT=$2
      shift 2
      ;;
    --out=*)
      OUT=${1#--out=}
      shift
      ;;
    --explain)
      EXPLAIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

[ -x "$RUNNER" ] || die "bin/fm-test-run.sh is required for the suite inventory"

INVENTORY=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  INVENTORY+=("$line")
done < <(inventory)
[ "${#INVENTORY[@]}" -gt 0 ] || die "suite inventory is empty"

# The hard safety rule, enforced here rather than only in the CI workflow, so
# it is testable through this script's own interface.
if [ "$EVENT" != "pull_request" ]; then
  full_suite "event '${EVENT:-none}' is not a pull request; selection is for pull requests only"
fi

if [ -n "${PATHS_FROM:-}" ]; then
  if [ "$PATHS_FROM" = "-" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      CHANGED+=("$line")
    done
  else
    [ -f "$PATHS_FROM" ] || die "--paths-from file not found: $PATHS_FROM"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      CHANGED+=("$line")
    done <"$PATHS_FROM"
  fi
fi

if [ "$PATHS_EXPLICIT" -eq 0 ]; then
  if ! changed_out=$(git_changed_paths "$BASE_REF"); then
    full_suite "base ref '$BASE_REF' is not resolvable, so the changed set is unknown"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    CHANGED+=("$line")
  done <<<"$changed_out"
fi

SELECTED=$(mktemp "${TMPDIR:-/tmp}/fm-test-affected-selected.XXXXXX")

if [ "${#CHANGED[@]}" -eq 0 ]; then
  if [ "$PATHS_EXPLICIT" -eq 1 ]; then
    log "no changed paths were supplied"
  else
    log "no changed paths against $BASE_REF"
  fi
fi

for changed_path in "${CHANGED[@]+"${CHANGED[@]}"}"; do
  select_for_path "$changed_path"
done

result=$(LC_ALL=C sort -u "$SELECTED")
emit_list "$result"
log "selected $(count_lines "$result") of ${#INVENTORY[@]} tests (event=$EVENT, changed=${#CHANGED[@]})"
