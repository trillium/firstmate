#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so the rule set,
# version, bounded execution, and diagnostics ordering cannot drift.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh. This is
#     what CI always runs, so CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). A branch with zero matching changed files exits 0 and prints a
#     "no changed lint targets" note instead of running ShellCheck.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays every root's
# diagnostics in deterministic root order after every worker finishes.
# FM_LINT_JOBS=1 runs the same shards serially with byte-identical diagnostics
# and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# A machine-wide admission limit bounds how many ShellCheck processes exist at
# once across every concurrent lint run, because ShellCheck's peak resident set
# is set by the heaviest single root's source closure rather than by batch size.
# Its default equals one bounded run's own worker count, so a lone run and CI are
# unaffected and only genuine overlap waits.
#
# A root's diagnostics are cached on content identity, so a change confined to a
# few roots re-analyses only those roots and every unaffected root replays from
# the cache. The cache lives outside any worktree, so concurrent branches of the
# same repository share it. A cached verdict is keyed on the ShellCheck version,
# the cache format, the root's path as passed, the root's own content, and the
# content of every file ShellCheck could read on its behalf, so no edit anywhere
# in the source graph can be served a stale verdict. Caching is off for any run
# whose dependency graph cannot be resolved, and FM_LINT_CACHE=0 turns it off
# outright; both fall back to full analysis rather than to a weaker key.
#
# Because a cached root's diagnostics are produced one root at a time, the run's
# closing `For more information:` block is rebuilt from the diagnostics actually
# reported instead of inherited from one ShellCheck invocation. It therefore
# lists every code raised with its full message, where ShellCheck's own block
# lists at most three with truncated messages. Diagnostics themselves are
# byte-identical to a single batched invocation.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
#
# Environment:
#   FM_LINT_JOBS           bounded worker count, 1 or 2 (default 2)
#   FM_LINT_TELEMETRY      path for the quiet metrics snapshot
#   FM_LINT_GLOBAL_LIMIT   machine-wide ShellCheck processes, 0 disables (default 2)
#   FM_LINT_GLOBAL_WAIT    seconds to wait for a slot before proceeding (default 900)
#   FM_LINT_STATE_DIR      directory holding the machine-wide slots and cache
#   FM_LINT_CACHE          0 disables the content cache (default 1)
set -u

REQUIRED_SHELLCHECK=0.11.0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_SLOT_LIMIT_DEFAULT=2
FM_LINT_SLOT_WAIT_DEFAULT=900

# Every knob resolves the same way in the parent and in a private worker, so a
# worker never has to be told what the parent decided.
fm_lint_positive_number() {  # <value> <fallback>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_lint_slot_limit() {
  fm_lint_positive_number "${FM_LINT_GLOBAL_LIMIT:-}" "$FM_LINT_SLOT_LIMIT_DEFAULT"
}

fm_lint_slot_wait() {
  fm_lint_positive_number "${FM_LINT_GLOBAL_WAIT:-}" "$FM_LINT_SLOT_WAIT_DEFAULT"
}

fm_lint_slot_dir() {
  printf '%s\n' "${FM_LINT_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fm-lint}/slots"
}

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

FM_LINT_WORKER_SLOT=
FM_LINT_WORKER_SLOT_WAIT=0

# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_slot_release() {
  [ -n "$FM_LINT_WORKER_SLOT" ] || return 0
  rm -f "$FM_LINT_WORKER_SLOT" 2>/dev/null || true
  FM_LINT_WORKER_SLOT=
}

# Claim one machine-wide ShellCheck slot. A hard link is the arbiter because it
# fails when the target exists and publishes the holder's pid in the same step,
# so a slot is never observable in a half-created state. A slot whose holder is
# gone is reclaimed by renaming it away, which only one racing reclaimer wins.
# The wait is bounded and then proceeds anyway: admission control must slow a
# lint run down, never deadlock one behind a slot that is never released.
fm_lint_slot_acquire() {
  local limit dir budget waited slot claim holder index
  limit=$(fm_lint_slot_limit)
  [ "$limit" -gt 0 ] || return 0
  dir=$(fm_lint_slot_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  budget=$(fm_lint_slot_wait)
  waited=0
  while :; do
    index=0
    while [ "$index" -lt "$limit" ]; do
      slot="$dir/slot.$index"
      claim="$dir/.claim.$$.$index"
      if printf '%s\n' "$$" > "$claim" 2>/dev/null && ln "$claim" "$slot" 2>/dev/null; then
        rm -f "$claim" 2>/dev/null || true
        FM_LINT_WORKER_SLOT=$slot
        [ "$waited" -le "$FM_LINT_WORKER_SLOT_WAIT" ] || FM_LINT_WORKER_SLOT_WAIT=$waited
        return 0
      fi
      rm -f "$claim" 2>/dev/null || true
      holder=$(cat "$slot" 2>/dev/null || true)
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        if mv "$slot" "$slot.dead.$$" 2>/dev/null; then
          rm -f "$slot.dead.$$" 2>/dev/null || true
          continue
        fi
      fi
      index=$((index + 1))
    done
    if [ "$waited" -ge "$budget" ]; then
      printf 'fm-lint.sh: no ShellCheck slot after %ss; proceeding without one.\n' \
        "$waited" >&2
      [ "$waited" -le "$FM_LINT_WORKER_SLOT_WAIT" ] || FM_LINT_WORKER_SLOT_WAIT=$waited
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# ShellCheck closes an invocation with a block that summarises that invocation
# alone, so a single root's reusable body has to end before it. The block is cut
# only when every line after its marker is a wiki link, which leaves a linted
# script that happens to contain the marker text as its own content untouched.
# The blank line before the marker is kept: it is the same separator ShellCheck
# writes between two roots of one invocation, so the cut bodies concatenate back
# into byte-identical batch diagnostics.
fm_lint_strip_footer() {  # <raw> <body>
  awk '
    {line[NR] = $0}
    END {
      cut = 0
      for (i = NR; i >= 1; i--) {
        if (line[i] == "For more information:") {cut = i; break}
      }
      if (cut > 0) {
        for (i = cut + 1; i <= NR; i++) {
          if (line[i] !~ /^  https:\/\/www\.shellcheck\.net\/wiki\/SC[0-9]+ /) {cut = 0; break}
        }
      }
      if (cut == 0) {cut = NR + 1}
      for (i = 1; i < cut; i++) {print line[i]}
    }
  ' "$1" > "$2"
}

# A cache entry is its root status followed by that root's body. It is published
# by rename from the same directory, so a reader either sees a whole entry or no
# entry at all, and a worker killed mid-write leaves no partial verdict behind.
# The destination is refused unless it sits under the cache root the parent
# resolved, so no manifest defect can ever turn a cache write into a write over
# a file being linted.
fm_lint_cache_store() {  # <entry> <status> <body>
  local entry=$1 status=$2 body=$3 staged
  case "${FM_LINT_CACHE_ROOT:-}" in
    ''|*/) return 0 ;;
  esac
  case "$entry" in
    "$FM_LINT_CACHE_ROOT"/*) ;;
    *) return 0 ;;
  esac
  staged="$entry.staged.$$"
  mkdir -p "$(dirname "$entry")" 2>/dev/null || return 0
  {
    printf '%s\n' "$status"
    cat "$body"
  } > "$staged" 2>/dev/null || { rm -f "$staged" 2>/dev/null; return 0; }
  mv "$staged" "$entry" 2>/dev/null || rm -f "$staged" 2>/dev/null || true
  return 0
}

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  if [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ]; then
    kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
    FM_LINT_WORKER_SHELLCHECK_PID=
  fi
  # Released only after ShellCheck is gone, so the slot never admits a successor
  # while this one still holds its resident set.
  fm_lint_slot_release
}

# Each root is analysed on its own so its verdict can be reused independently of
# whichever roots it happened to be batched with. Admission is per root rather
# than per worker, so a run waiting on the machine-wide limit is let in between
# two roots instead of behind a whole shard.
#
# A manifest field is never empty, because bash collapses runs of tab delimiters
# and would silently shift an empty middle field's successors left. "-" is the
# absent-entry marker for that reason, and a line that still parses short is
# refused rather than acted on.
fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index entry path rc=0 root_rc
  tab=$(printf '\t')
  trap 'fm_lint_worker_stop; exit 129' HUP
  trap 'fm_lint_worker_stop; exit 130' INT
  trap 'fm_lint_worker_stop; exit 143' TERM
  while IFS="$tab" read -r index entry path || [ -n "${index:-}" ]; do
    [ -n "${index:-}" ] || continue
    if [ -z "${entry:-}" ] || [ -z "${path:-}" ]; then
      printf 'fm-lint.sh: malformed worker manifest entry %s.\n' "$index" >&2
      printf '2\n' > "$output_dir/rc.$index"
      : > "$output_dir/body.$index"
      rc=2
      continue
    fi
    root_rc=0
    fm_lint_slot_acquire
    "$FM_LINT_SHELLCHECK" --norc --external-sources -- "$path" > "$output_dir/raw.$index" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || root_rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    fm_lint_slot_release
    fm_lint_strip_footer "$output_dir/raw.$index" "$output_dir/body.$index"
    rm -f "$output_dir/raw.$index"
    printf '%s\n' "$root_rc" > "$output_dir/rc.$index"
    [ "$entry" = "-" ] || fm_lint_cache_store "$entry" "$root_rc" "$output_dir/body.$index"
    [ "$rc" -ne 0 ] || rc=$root_rc
  done < "$manifest"
  trap - HUP INT TERM
  printf '%s\n' "$FM_LINT_WORKER_SLOT_WAIT" > "$output_dir/shard.$shard_index.slotwait"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# The header block itself is the usage text, read to its end rather than to a
# hardcoded line number so documenting a new knob cannot silently truncate it.
fm_lint_usage() {
  awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
LIST_FILES=0
CHANGED_MODE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

# Reject a malformed admission knob here rather than letting a worker fall back
# to a default the caller never asked for.
fm_lint_require_count() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*)
      printf 'fm-lint.sh: %s must be a non-negative integer, got %s.\n' "$1" "$2" >&2
      exit 2
      ;;
  esac
}
[ -z "${FM_LINT_GLOBAL_LIMIT:-}" ] || fm_lint_require_count FM_LINT_GLOBAL_LIMIT "$FM_LINT_GLOBAL_LIMIT"
[ -z "${FM_LINT_GLOBAL_WAIT:-}" ] || fm_lint_require_count FM_LINT_GLOBAL_WAIT "$FM_LINT_GLOBAL_WAIT"
case "${FM_LINT_CACHE:-1}" in
  0|1) ;;
  *) printf 'fm-lint.sh: FM_LINT_CACHE must be 0 or 1, got %s.\n' "${FM_LINT_CACHE:-}" >&2; exit 2 ;;
esac

if [ "$#" -gt 0 ]; then
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  exit 0
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

# Started before cache planning so the measured wall time covers everything a
# caller waits for, not only the ShellCheck work a warm run skips.
TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
done

CACHE_FORMAT=fm-lint-cache-v1
# The ShellCheck flag set is a constant of this script rather than a key
# component, so changing the invocation in the worker means bumping CACHE_FORMAT.
CACHE_DIR="${FM_LINT_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fm-lint}/results"
CACHE_STATE=disabled
CACHE_HITS=0
CACHE_MISSES=$ROOT_COUNT
CACHE_DEPS=0
CACHE_PREFIX=
DIGEST_TOOL=
CACHE_ENTRIES=()

fm_lint_digest_files() {  # <path>...
  case "$DIGEST_TOOL" in
    shasum) shasum -a 256 -- "$@" ;;
    sha256sum) sha256sum -- "$@" ;;
  esac
}

fm_lint_digest_stdin() {
  case "$DIGEST_TOOL" in
    shasum) shasum -a 256 ;;
    sha256sum) sha256sum ;;
  esac | awk '{print $1; exit}'
}

# Names ShellCheck could follow out of the given files. A `source=` directive is
# the only way it can follow a variable-interpolated path, and a literal path it
# can follow is already a path, so between them these two forms cover every file
# a root can pull in. A directive is a literal string ShellCheck never expands,
# so a name containing an expansion is dropped from both forms: ShellCheck
# reports it unfollowed rather than reading anything. /dev/null is an explicit
# non-follow boundary. Each name is emitted with both roots it could resolve
# against, deduplicated by the caller.
fm_lint_source_names() {  # <path>...
  awk '
    function emit(target,   dir) {
      if (target == "" || target == "/dev/null" || target ~ /\$/) {return}
      dir = FILENAME
      if (sub(/\/[^\/]*$/, "", dir) == 0) {dir = "."}
      printf "%s\t%s\t%s/%s\n", target, target, dir, target
    }
    /^[[:space:]]*# shellcheck source=/ {
      target = $0
      sub(/^[[:space:]]*# shellcheck source=/, "", target)
      sub(/[[:space:]].*$/, "", target)
      emit(target)
      next
    }
    /^[[:space:]]*(\.|source)[[:space:]]/ {
      target = $2
      gsub(/^[\042\047]+|[\042\047]+$/, "", target)
      emit(target)
    }
  ' "$@" | LC_ALL=C sort -u
}

if [ "${FM_LINT_CACHE:-1}" != 0 ]; then
  if command -v shasum >/dev/null 2>&1; then
    DIGEST_TOOL=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    DIGEST_TOOL=sha256sum
  fi
  CACHE_STATE=active
  [ -n "$DIGEST_TOOL" ] || CACHE_STATE=no-digest-tool
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *\\*) CACHE_STATE=unsupported-path; break ;;
    esac
    [ -f "$path" ] || { CACHE_STATE=unreadable-root; break; }
  done
fi

if [ "$CACHE_STATE" = active ]; then
  # Walk the source graph to a fixed point, so a library that only another
  # library sources still expires the roots that reach it. Roots are seeded as
  # already scanned but are NOT dependencies of each other: a leaf root changing
  # must cost only its own re-analysis, which is the entire point of the cache.
  : > "$TMP_ROOT/dep-paths"
  printf '%s\n' "${ROOTS[@]}" | LC_ALL=C sort -u > "$TMP_ROOT/dep-scanned"
  scan=("${ROOTS[@]}")
  unresolved=0
  rounds=0
  while [ "${#scan[@]}" -gt 0 ] && [ "$rounds" -lt 16 ]; do
    rounds=$((rounds + 1))
    : > "$TMP_ROOT/dep-round"
    while IFS="$TAB" read -r name direct relative; do
      [ -n "${name:-}" ] || continue
      if [ -f "$direct" ]; then
        printf '%s\n' "$direct" >> "$TMP_ROOT/dep-round"
      elif [ -f "$relative" ]; then
        printf '%s\n' "$relative" >> "$TMP_ROOT/dep-round"
      else
        # A name that resolves to nothing is only alarming when it looked like a
        # source target to begin with. The `.`/`source` line form also matches
        # unrelated languages embedded in heredocs, whose operands are words
        # rather than paths and name nothing ShellCheck reads.
        case "$name" in
          */*|*.sh) unresolved=$((unresolved + 1)) ;;
        esac
      fi
    done < <(fm_lint_source_names "${scan[@]}")
    LC_ALL=C sort -u "$TMP_ROOT/dep-round" > "$TMP_ROOT/dep-round.sorted"
    cat "$TMP_ROOT/dep-paths" "$TMP_ROOT/dep-round.sorted" \
      | LC_ALL=C sort -u > "$TMP_ROOT/dep-paths.next"
    mv "$TMP_ROOT/dep-paths.next" "$TMP_ROOT/dep-paths"
    LC_ALL=C comm -23 "$TMP_ROOT/dep-round.sorted" "$TMP_ROOT/dep-scanned" > "$TMP_ROOT/dep-new"
    cat "$TMP_ROOT/dep-scanned" "$TMP_ROOT/dep-new" \
      | LC_ALL=C sort -u > "$TMP_ROOT/dep-scanned.next"
    mv "$TMP_ROOT/dep-scanned.next" "$TMP_ROOT/dep-scanned"
    scan=()
    while IFS= read -r path; do
      [ -n "$path" ] && scan+=("$path")
    done < "$TMP_ROOT/dep-new"
  done
  if [ "${#scan[@]}" -gt 0 ] || [ "$unresolved" -gt 0 ]; then
    # A name that could not be resolved, or a graph still growing after sixteen
    # rounds, means some file ShellCheck reads is unaccounted for. Widen the key
    # to the whole corpus rather than key on a graph known to be incomplete: the
    # cache then only helps when nothing changed at all, which is still correct.
    CACHE_STATE=widened
    cat "$TMP_ROOT/dep-paths" > "$TMP_ROOT/dep-paths.wide"
    printf '%s\n' "${ROOTS[@]}" >> "$TMP_ROOT/dep-paths.wide"
    LC_ALL=C sort -u "$TMP_ROOT/dep-paths.wide" > "$TMP_ROOT/dep-paths"
  fi
  CACHE_DEPS=$(wc -l < "$TMP_ROOT/dep-paths" | tr -d '[:space:]')
  deps=()
  while IFS= read -r path; do
    [ -n "$path" ] && deps+=("$path")
  done < "$TMP_ROOT/dep-paths"
  if [ "${#deps[@]}" -gt 0 ]; then
    deps_digest=$(fm_lint_digest_files "${deps[@]}" | fm_lint_digest_stdin)
  else
    deps_digest=$(printf '' | fm_lint_digest_stdin)
  fi
  CACHE_PREFIX="$CACHE_DIR/$CACHE_FORMAT/$resolved/$deps_digest"
fi

if [ -n "$CACHE_PREFIX" ]; then
  # One digest pass over every root, then one pass to turn each into its entry
  # path. The path is escaped rather than hashed so an entry stays traceable to
  # the root it describes, and %-escaping keeps the mapping collision-free.
  fm_lint_digest_files "${ROOTS[@]}" > "$TMP_ROOT/root-digests"
  awk -v prefix="$CACHE_PREFIX" '
    {
      sha = $1
      path = $0
      sub(/^[^ ]+[ ][ ]/, "", path)
      gsub(/%/, "%25", path)
      gsub(/\//, "%2F", path)
      printf "%s/%s.%s\n", prefix, sha, path
    }
  ' "$TMP_ROOT/root-digests" > "$TMP_ROOT/entries"
  while IFS= read -r entry; do
    CACHE_ENTRIES+=("$entry")
  done < "$TMP_ROOT/entries"
  if [ "${#CACHE_ENTRIES[@]}" -ne "$ROOT_COUNT" ]; then
    CACHE_STATE=digest-mismatch
    CACHE_ENTRIES=()
    CACHE_PREFIX=
  elif ! mkdir -p "$CACHE_PREFIX" 2>/dev/null; then
    CACHE_STATE=unwritable
    CACHE_ENTRIES=()
    CACHE_PREFIX=
  fi
fi
export FM_LINT_CACHE_ROOT="$CACHE_DIR"

index=1
CACHE_HITS=0
CACHE_MISSES=0
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  entry=-
  [ "${#CACHE_ENTRIES[@]}" -eq 0 ] || entry=${CACHE_ENTRIES[index - 1]}
  if [ "$entry" != - ] && [ -f "$entry" ]; then
    printf '%s\n' "$entry" > "$OUTPUT_DIR/hit.$index"
    CACHE_HITS=$((CACHE_HITS + 1))
  else
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    else
      weight=1
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$weight" "$index" "$entry" "$path" >> "$WEIGHTS"
    CACHE_MISSES=$((CACHE_MISSES + 1))
  fi
  index=$((index + 1))
done

if [ -n "$CACHE_PREFIX" ]; then
  # Touched on every run so a directory serving nothing but hits still reads as
  # live to the reaper below, which drops graphs no run has produced for a week.
  touch "$CACHE_PREFIX" 2>/dev/null || true
  if [ -z "$(find "$CACHE_DIR/.reaped" -mtime -1 2>/dev/null || true)" ]; then
    : > "$CACHE_DIR/.reaped" 2>/dev/null || true
    find "$CACHE_DIR" -mindepth 3 -maxdepth 3 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
  fi
fi

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index entry path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\t%s\n' "$index" "$entry" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

max_slot_wait=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  slot_wait=$(cat "$OUTPUT_DIR/shard.$worker.slotwait" 2>/dev/null || printf '0')
  case "$slot_wait" in ''|*[!0-9]*) slot_wait=0 ;; esac
  [ "$slot_wait" -le "$max_slot_wait" ] || max_slot_wait=$slot_wait
  worker=$((worker + 1))
done

# Replay every root in the order it was given, whichever shard analysed it and
# whether it was analysed at all, and select the first nonzero root status. Root
# order rather than shard order is what makes a cached and an uncached run of the
# same corpus produce the same bytes.
overall_rc=0
DIAGNOSTICS="$TMP_ROOT/diagnostics"
: > "$DIAGNOSTICS"
index=1
while [ "$index" -le "$ROOT_COUNT" ]; do
  if [ -f "$OUTPUT_DIR/hit.$index" ]; then
    entry=$(cat "$OUTPUT_DIR/hit.$index")
    rc=$(awk 'NR == 1 {print; exit}' "$entry" 2>/dev/null || printf '2')
    awk 'NR > 1' "$entry" >> "$DIAGNOSTICS" 2>/dev/null || true
  elif [ -f "$OUTPUT_DIR/rc.$index" ]; then
    rc=$(cat "$OUTPUT_DIR/rc.$index" 2>/dev/null || printf '2')
    cat "$OUTPUT_DIR/body.$index" >> "$DIAGNOSTICS" 2>/dev/null || true
  else
    printf 'fm-lint.sh: worker produced no result for %s.\n' "${ROOTS[index - 1]}" >&2
    rc=2
  fi
  case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  index=$((index + 1))
done

cat "$DIAGNOSTICS"
# Rebuilt from the diagnostics actually reported, because no single invocation
# saw them all once roots are analysed separately. Severity order then code order
# is ShellCheck's own ordering; the divergence is that every code is listed with
# its full message instead of three with truncated ones.
awk '
  match($0, /SC[0-9]+ \([a-z]+\): /) {
    field = substr($0, RSTART, RLENGTH)
    code = field
    sub(/ .*$/, "", code)
    severity = field
    sub(/^[^(]*\(/, "", severity)
    sub(/\).*$/, "", severity)
    if (code in seen) {next}
    seen[code] = 1
    rank = 4
    if (severity == "error") {rank = 0}
    else if (severity == "warning") {rank = 1}
    else if (severity == "info") {rank = 2}
    else if (severity == "style") {rank = 3}
    printf "%d %s %s\n", rank, substr(code, 3), substr($0, RSTART + RLENGTH)
  }
' "$DIAGNOSTICS" | LC_ALL=C sort -k1,1n -k2,2n | awk '
  NR == 1 {print "For more information:"}
  {
    message = $0
    sub(/^[0-9]+ [0-9]+ /, "", message)
    printf "  https://www.shellcheck.net/wiki/SC%s -- %s\n", $2, message
  }
'

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_followed=$((source_directives - source_boundaries))
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'slot_limit\t%s\n' "$(fm_lint_slot_limit)"
    printf 'max_slot_wait_seconds\t%s\n' "$max_slot_wait"
    printf 'cache_state\t%s\n' "$CACHE_STATE"
    printf 'cache_hits\t%s\n' "$CACHE_HITS"
    printf 'cache_misses\t%s\n' "$CACHE_MISSES"
    printf 'cache_dependencies\t%s\n' "$CACHE_DEPS"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

exit "$overall_rc"
