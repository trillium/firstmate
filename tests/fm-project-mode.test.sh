#!/usr/bin/env bash
# Behavioral tests for Boundary 14 Project Registry adapter (bin/fm-project-mode.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)

test_project_mode_beads_entity() {
  local home="$TMP_ROOT/home_beads"
  mkdir -p "$home/config" "$home/data"
  echo "beads" > "$home/config/projects-backend"
  fm_test_beads_setup "$home"

  # Register project entity in Beads
  task create "Project: demo-proj" --type=entity --labels="type:project,project:demo-proj" \
    --metadata='{"slug":"demo-proj","delivery_mode":"direct-PR","yolo":true}' >/dev/null

  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-project-mode.sh" demo-proj)
  [ "$out" = "direct-PR on" ] || fail "expected 'direct-PR on', got '$out'"

  pass "fm-project-mode.sh resolves delivery mode and yolo from Beads project entity"
}

test_project_mode_readthrough_fallback() {
  local home="$TMP_ROOT/home_readthrough"
  mkdir -p "$home/config" "$home/data"
  fm_test_beads_setup "$home"

  # Not in Beads, but in data/projects.md
  cat > "$home/data/projects.md" <<'EOF'
- legacy-proj [local-only] - A local-only project (added 2026-08-01)
EOF

  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-project-mode.sh" legacy-proj)
  [ "$out" = "local-only off" ] || fail "expected 'local-only off', got '$out'"

  pass "fm-project-mode.sh falls back to data/projects.md when entity not in beads"
}

test_project_mode_rollback_files() {
  local home="$TMP_ROOT/home_files"
  mkdir -p "$home/config" "$home/data"
  echo "files" > "$home/config/projects-backend"

  cat > "$home/data/projects.md" <<'EOF'
- test-proj [no-mistakes +yolo] - A test project (added 2026-09-01)
EOF

  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-project-mode.sh" test-proj)
  [ "$out" = "no-mistakes on" ] || fail "expected 'no-mistakes on', got '$out'"

  pass "config/projects-backend=files restores legacy file reading"
}

test_project_mode_raw_handling() {
  local home="$TMP_ROOT/home_raw"
  mkdir -p "$home/config" "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prod-proj [no-mistakes-prod-only] - Prod only project (added 2026-09-01)
EOF

  local out_normal out_raw
  out_normal=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-project-mode.sh" prod-proj)
  [ "$out_normal" = "no-mistakes off" ] || fail "expected mapped 'no-mistakes off', got '$out_normal'"

  out_raw=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-project-mode.sh" --raw prod-proj)
  [ "$out_raw" = "no-mistakes-prod-only off" ] || fail "expected raw 'no-mistakes-prod-only off', got '$out_raw'"

  pass "fm-project-mode.sh respects --raw flag for conditional policies"
}

test_project_mode_beads_entity
test_project_mode_readthrough_fallback
test_project_mode_rollback_files
test_project_mode_raw_handling
