#!/usr/bin/env bash
# Behavioral tests for Boundary 15 Domain Memory & Learnings adapter (bin/fm-memory-lib.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-budget)

test_memory_beads_and_projection() {
  local home="$TMP_ROOT/home_beads"
  mkdir -p "$home/config" "$home/data"
  echo "beads" > "$home/config/memory-backend"
  fm_test_beads_setup "$home"

  # Default backend is beads
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    bash -c '
    . bin/fm-memory-lib.sh
    [ "$(fm_memory_backend)" = "beads" ] || exit 1
    fm_memory_set "captain" "Captain prefers concise summaries."
    val=$(fm_memory_get "captain")
    [ "$val" = "Captain prefers concise summaries." ] || exit 2
    # Verify projection to disk file
    [ -f "$DATA/captain.md" ] || exit 3
    [ "$(cat "$DATA/captain.md")" = "Captain prefers concise summaries." ] || exit 4
  ' || fail "beads memory get/set/projection failed"

  pass "beads memory gets/sets memory and maintains file projection"
}

test_memory_rollback_files() {
  local home="$TMP_ROOT/home_files"
  mkdir -p "$home/config" "$home/data"
  echo "files" > "$home/config/memory-backend"
  echo "Legacy captain preference" > "$home/data/captain.md"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    bash -c '
    . bin/fm-memory-lib.sh
    [ "$(fm_memory_backend)" = "files" ] || exit 1
    val=$(fm_memory_get "captain")
    [ "$val" = "Legacy captain preference" ] || exit 2
    fm_memory_set "learnings" "Test learning"
    [ -f "$DATA/learnings.md" ] || exit 3
    [ "$(cat "$DATA/learnings.md")" = "Test learning" ] || exit 4
  ' || fail "files memory rollback failed"

  pass "config/memory-backend=files restores file persistence without beads"
}

test_memory_render_formatting() {
  local home="$TMP_ROOT/home_render"
  mkdir -p "$home/config" "$home/data"
  fm_test_beads_setup "$home"

  # Absent memory
  local out_absent
  out_absent=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    bash -c '. bin/fm-memory-lib.sh; fm_memory_render "captain" "data/captain.md"')
  assert_contains "$out_absent" "ABSENT" "absent memory did not render ABSENT"

  # Present memory
  echo "beads" > "$home/config/memory-backend"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    bash -c '. bin/fm-memory-lib.sh; fm_memory_set "captain" "Active preference"'
  local out_present
  out_present=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    bash -c '. bin/fm-memory-lib.sh; fm_memory_render "captain" "data/captain.md"')
  assert_contains "$out_present" "Active preference" "present memory did not render content"

  pass "memory render matches session start formatting contract"
}

test_memory_beads_and_projection
test_memory_rollback_files
test_memory_render_formatting
