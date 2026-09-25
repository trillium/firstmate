#!/usr/bin/env bash
# fm-size-limit.sh - coding-standards file size check.
# Usage: fm-size-limit.sh [--limit N] [--json] <file> [...]
# A file at or above LIMIT lines (default 250) that is not a test file gets
# an OVER-LIMIT verdict plus the decomposition playbook: split by concept
# into single-concept files, never relax or bypass the limit.
# Test files are exempt and reported as such, never as violations.
# Exit 0 when every file is within limit or exempt, 1 when any file is
# over-limit, 2 on usage errors or unreadable files.
# The Jungle wrapper (bin/fm-size-limit.jungle.yaml) serves this script as
# the coding-standards__check-size-limit tool; its allowlist pins the limit
# at the default by rejecting flag-like input, so the tool surface can never
# relax the standard. Direct shell callers may still pass --limit explicitly.
set -u

LIMIT=250
JSON=0

usage() {
  printf 'usage: fm-size-limit.sh [--limit N] [--json] <file> [...]\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      shift
      case "${1:-}" in
        ''|*[!0-9]*)
          printf 'error: --limit needs a positive integer\n' >&2
          usage >&2
          exit 2
          ;;
      esac
      LIMIT="$1"
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'error: unknown flag %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

# A path is a test path when its file name carries a test marker or it
# lives directly under a test directory. Only the basename and exact
# directory names are matched, so innocent words like `latest` or
# `contest` never exempt a file; matching is case-insensitive on purpose.
is_test_path() {
  base=${1##*/}
  case "$base" in
    *[Tt][Ee][Ss][Tt]*|*[Ss][Pp][Ee][Cc]*)
      return 0
      ;;
  esac
  dir=${1%"$base"}
  case "$dir" in
    */[Tt][Ee][Ss][Tt]/|*/[Tt][Ee][Ss][Tt][Ss]/|*/__[Tt][Ee][Ss][Tt]__/)
      return 0
      ;;
  esac
  return 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

OVERALL=0
FIRST_JSON=1

playbook() {
  printf 'DECOMPOSITION PLAYBOOK (the limit is never relaxed or bypassed)\n'
  printf '1. Read the whole file and name each distinct concept or job it performs.\n'
  printf '2. Split by concept into single-concept files, each named for its one concept.\n'
  printf '3. Move only genuinely shared helpers into one narrowly scoped support module.\n'
  printf '4. Re-run this check on every resulting file until each is under the limit.\n'
  printf '5. Never relax or bypass the limit: do not raise it, do not split code to game the count, do not reclassify production code as test, do not move code where it does not belong.\n'
}

for f in "$@"; do
  if [ ! -e "$f" ]; then
    printf 'FILE: %s\nERROR: not found or unreadable\n\n' "$f"
    OVERALL=2
    continue
  fi
  if [ -d "$f" ]; then
    printf 'FILE: %s\nERROR: is a directory, pass files\n\n' "$f"
    OVERALL=2
    continue
  fi
  if is_test_path "$f"; then
    if [ "$JSON" -eq 1 ]; then
      [ "$FIRST_JSON" -eq 1 ] || printf ','
      FIRST_JSON=0
      printf '{"file":"%s","test_exempt":true,"verdict":"EXEMPT"}' "$(json_escape "$f")"
    else
      printf 'FILE: %s\nTEST_EXEMPT: yes\nVERDICT: EXEMPT (test files carry no size limit)\n\n' "$f"
    fi
    continue
  fi
  LINES=$(wc -l < "$f" | tr -d ' ')
  if [ "$LINES" -ge "$LIMIT" ]; then
    OVERALL=1
    if [ "$JSON" -eq 1 ]; then
      [ "$FIRST_JSON" -eq 1 ] || printf ','
      FIRST_JSON=0
      printf '{"file":"%s","lines":%s,"limit":%s,"verdict":"OVER-LIMIT"}' "$(json_escape "$f")" "$LINES" "$LIMIT"
    else
      printf 'FILE: %s\nLINES: %s\nLIMIT: %s\nTEST_EXEMPT: no\nVERDICT: OVER-LIMIT\n\n' "$f" "$LINES" "$LIMIT"
      playbook
      printf '\n'
    fi
  else
    if [ "$JSON" -eq 1 ]; then
      [ "$FIRST_JSON" -eq 1 ] || printf ','
      FIRST_JSON=0
      printf '{"file":"%s","lines":%s,"limit":%s,"verdict":"OK"}' "$(json_escape "$f")" "$LINES" "$LIMIT"
    else
      printf 'FILE: %s\nLINES: %s\nLIMIT: %s\nTEST_EXEMPT: no\nVERDICT: OK\n\n' "$f" "$LINES" "$LIMIT"
    fi
  fi
done

if [ "$JSON" -eq 1 ]; then
  printf '\n'
fi

exit "$OVERALL"
