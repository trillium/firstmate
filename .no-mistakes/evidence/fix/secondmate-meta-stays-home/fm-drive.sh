#!/usr/bin/env bash
# Drives real bin/fm-spawn.sh inside a lab tmux server for the parent-route guard.
set -u
WT=$1; LAB=$2
STALE=$LAB/stale-home; SUB=$LAB/sub-home; ELSE=$LAB/elsewhere
cd "$WT"
run() { local label=$1; shift
  echo "=== $label"; echo "+ $*"
  env "$@" bin/fm-spawn.sh domain "$SUB" claude --secondmate 2>&1 | tail -n 4
  echo "exit=${PIPESTATUS[0]}"
  echo "stale meta: $(ls "$STALE/state/domain.meta" 2>/dev/null || echo absent)"
  echo "elsewhere meta: $(ls "$ELSE/state/domain.meta" 2>/dev/null || echo absent)"
  echo "parent-route meta: $(ls "$SUB/state/parent-route/domain.meta" 2>/dev/null || echo absent)"
}
run "A: stale FM_HOME + FM_DATA_OVERRIDE=parent-route, FM_STATE_OVERRIDE unset (Greptile P1)" \
  FM_HOME="$STALE" FM_DATA_OVERRIDE="$SUB/data/.parent-route"
run "B: parent-route data + unrelated FM_STATE_OVERRIDE" \
  FM_HOME="$STALE" FM_DATA_OVERRIDE="$SUB/data/.parent-route" FM_STATE_OVERRIDE="$ELSE/state"
run "C: parent-route state + unrelated data dir (mismatch the other way)" \
  FM_HOME="$STALE" FM_DATA_OVERRIDE="$STALE/data" FM_STATE_OVERRIDE="$SUB/state/parent-route"
run "D: launcher-shaped route: data=.parent-route AND state=state/parent-route" \
  FM_HOME="$SUB" FM_DATA_OVERRIDE="$SUB/data/.parent-route" FM_STATE_OVERRIDE="$SUB/state/parent-route"
echo "--- D meta:"; cat "$SUB/state/parent-route/domain.meta" 2>&1 | head -20
echo "--- tmux windows after D:"; tmux list-windows -F '#{window_name}' 2>&1
for w in $(tmux list-windows -F '#{window_id} #{window_name}' | awk '$2!="bash"&&$2!="primary"{print $1}'); do :; done
tmux kill-window -t domain 2>/dev/null
rm -f "$SUB/state/parent-route/domain.meta"
printf -- '- domain - domain (home: %s; scope: domain work; projects: ; added 2026-08-05)\n' "$(cd "$SUB" && pwd -P)" > "$STALE/data/secondmates.md"
run "E: positive control: FM_HOME registry binds domain to this home (stock dirs)" FM_HOME="$STALE"
echo "--- tmux windows after E:"; tmux list-windows -F '#{window_name}' 2>&1
echo "--- E meta:"; cat "$STALE/state/domain.meta" 2>&1 | head -20
echo DRIVE-DONE
