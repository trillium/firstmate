# shellcheck shell=bash
# bin/fm-memory-lib.sh - centralized adapter for Domain Knowledge, Preferences,
# and Learnings persistence (Boundary 15, Beads-first persistence migration Phase 1).
# Usage: . bin/fm-memory-lib.sh
#
# Governed by config/memory-backend:
#   "beads" (default) - canonical persistence in Beads persistent memories
#                       (`task remember` / `task recall`) with dual-write
#                       projections to local files in data/.
#   "files"           - legacy file-based persistence reading/writing
#                       data/captain.md, data/captain-shared.md, data/learnings.md.
#
# Reversible rollback: setting config/memory-backend to "files" instantly
# restores file-only persistence without code changes.

_FM_MEMORY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_MEMORY_LIB_DIR="."
FM_MEMORY_DEFAULT_ROOT="$(cd "$_FM_MEMORY_LIB_DIR/.." && pwd 2>/dev/null)" || FM_MEMORY_DEFAULT_ROOT="."
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_MEMORY_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Resolve configured memory backend
fm_memory_backend() {
  local cfg_dir=${1:-$CONFIG} flag_file
  flag_file="$cfg_dir/memory-backend"
  if [ -f "$flag_file" ]; then
    local val
    val=$(<"$flag_file")
    case "$val" in
      beads) printf 'beads\n'; return 0 ;;
      files|*) printf 'files\n'; return 0 ;;
    esac
  fi
  printf 'files\n'
}

# Resolve canonical file path for standard memory keys
fm_memory_key_to_file() {
  local key=$1 data_dir=${2:-$DATA}
  case "$key" in
    captain|captain.md|captain-preference:*)
      printf '%s/captain.md\n' "$data_dir"
      ;;
    captain-shared|captain-shared.md|shared-preference:*)
      printf '%s/captain-shared.md\n' "$data_dir"
      ;;
    learnings|learnings.md|learning:*)
      printf '%s/learnings.md\n' "$data_dir"
      ;;
    *)
      printf '%s/%s.md\n' "$data_dir" "$key"
      ;;
  esac
}

# fm_memory_get <key> [data_dir]
# Returns memory contents to stdout; returns 0 if found, 1 if absent.
fm_memory_get() {
  local key=$1 data_dir=${2:-$DATA} backend
  backend=$(fm_memory_backend "$CONFIG")

  if [ "$backend" = "beads" ] && command -v task >/dev/null 2>&1; then
    local val
    if val=$(task recall "$key" 2>/dev/null) && [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi

  # Read-through / fallback to projection file
  local file
  file=$(fm_memory_key_to_file "$key" "$data_dir")
  if [ -f "$file" ]; then
    cat "$file"
    return 0
  fi
  return 1
}

# fm_memory_set <key> <content> [data_dir]
# Persists memory in Beads (when beads backend active) and flushes dual-write
# projection file to disk.
fm_memory_set() {
  local key=$1 content=$2 data_dir=${3:-$DATA} backend file tmp
  backend=$(fm_memory_backend "$CONFIG")
  file=$(fm_memory_key_to_file "$key" "$data_dir")

  if [ "$backend" = "beads" ]; then
    if command -v task >/dev/null 2>&1; then
      if ! task remember "$content" --key="$key" >/dev/null 2>&1; then
        # Resilience: enqueue failed write if resilience library loaded
        if command -v fm_beads_write_enqueue >/dev/null 2>&1; then
          fm_beads_write_enqueue "memory" "remember $key" "remember" "$content" "--key=$key" 2>/dev/null || true
        fi
      fi
    fi
  fi

  # Dual-write / projection to disk file
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  tmp="${file}.tmp.$$"
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# fm_memory_render <key> <label> [data_dir]
# Renders a memory section with subsection header for session-start digest.
fm_memory_render() {
  local key=$1 label=$2 data_dir=${3:-$DATA} file backend content
  backend=$(fm_memory_backend "$CONFIG")
  file=$(fm_memory_key_to_file "$key" "$data_dir")

  if command -v subsection >/dev/null 2>&1; then
    subsection "$label"
  else
    printf '\n=== %s ===\n' "$label"
  fi

  if [ "$backend" = "beads" ] && command -v task >/dev/null 2>&1; then
    if content=$(task recall "$key" 2>/dev/null); then
      if [ -n "$content" ]; then
        printf '%s\n' "$content"
        return 0
      else
        printf '(present, empty)\n'
        return 0
      fi
    fi
  fi

  # File read / projection check
  if [ -f "$file" ]; then
    if [ -s "$file" ]; then
      cat "$file"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}
