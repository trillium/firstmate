#!/usr/bin/env bash
set -u
WT=$1; LAB=$2; STALE=$LAB/stale-home; SUB=$LAB/sub-home
cd "$WT"
echo "=== D: launcher-shaped call (FM_HOME=code root, state=sub/state/parent-route, data=sub/data/.parent-route)"
env FM_HOME="$WT" FM_ROOT_OVERRIDE="$WT" FM_STATE_OVERRIDE="$SUB/state/parent-route" FM_DATA_OVERRIDE="$SUB/data/.parent-route" \
  FM_CONFIG_OVERRIDE="$SUB/config" FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1 \
  bin/fm-spawn.sh domain "$SUB" claude --secondmate 2>&1 | tail -n 6; echo "exit=${PIPESTATUS[0]}"
echo "--- D meta at sub-home/state/parent-route/domain.meta:"; cat "$SUB/state/parent-route/domain.meta" 2>&1 | head -12
echo "--- windows:"; tmux list-windows -F '#{window_name}'
tmux kill-window -t fm-domain 2>/dev/null; rm -f "$SUB/state/parent-route/domain.meta"
echo "=== D': same call but FM_STATE_OVERRIDE unset (stale code-root FM_HOME, Greptile P1 shape)"
env FM_HOME="$WT" FM_ROOT_OVERRIDE="$WT" FM_DATA_OVERRIDE="$SUB/data/.parent-route" \
  FM_CONFIG_OVERRIDE="$SUB/config" FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1 \
  bin/fm-spawn.sh domain "$SUB" claude --secondmate 2>&1 | tail -n 3; echo "exit=${PIPESTATUS[0]}"
echo "worktree state/domain.meta: $(ls "$WT/state/domain.meta" 2>/dev/null || echo absent)"
echo "=== E: registered home spawns (positive control)"
printf -- '- domain - domain (home: %s; scope: domain work; projects: ; added 2026-08-05)\n' "$(cd "$SUB" && pwd -P)" > "$STALE/data/secondmates.md"
env FM_HOME="$STALE" FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1 bin/fm-spawn.sh domain "$SUB" claude --secondmate 2>&1 | tail -n 6; echo "exit=${PIPESTATUS[0]}"
echo "--- E meta at stale-home/state/domain.meta:"; cat "$STALE/state/domain.meta" 2>&1 | head -12
echo "--- windows:"; tmux list-windows -F '#{window_name}'
tmux kill-window -t fm-domain 2>/dev/null
echo DRIVE-DONE
