#!/usr/bin/env bash
# Live driver: runs inside a pane of the lab's private tmux server.
# Args: <repo-bin-dir> <parent-lab> <other-lab> <sm-home> <label>
set -u
BIN=$1 P=$2 O=$3 SM=$4 LABEL=$5
hr() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
lsmeta() { printf -- '-- %s/state/*.meta:\n' "$1"; ls -1 "$1"/state/*.meta 2>/dev/null || echo '(none)'; }
echo "fm-spawn.sh under test: $BIN/fm-spawn.sh ($LABEL)"
echo "TMUX=$TMUX"

hr "S1 seed secondmate sm1 from parent lab home (real fm-home-seed.sh)"
if [ ! -f "$P/data/secondmates.md" ]; then
  FM_HOME=$P FM_SECONDMATE_CHARTER='lab domain charter for meta-placement test' FM_SECONDMATE_SCOPE='lab scope' \
    run "$BIN/fm-home-seed.sh" sm1 "$SM" --no-projects
fi
echo "-- parent registry:"; cat "$P/data/secondmates.md"

hr "S2 adversarial: stale FM_HOME (other lab home, NO registry) spawns sm1"
FM_HOME=$O run "$BIN/fm-spawn.sh" sm1 "$SM" --harness 'sleep 3600' --backend tmux --secondmate
lsmeta "$O"; tmux list-windows -a -F '#{session_name}:#{window_name}'

[ "$LABEL" = baseline ] && { echo DRIVE-DONE; exit 0; }
hr "S3 adversarial: other home registers a DIFFERENT id only"
printf -- '- other - other domain (home: %s; scope: other; projects: ; added 2026-10-29)\n' "$O/projects" > "$O/data/secondmates.md"
FM_HOME=$O run "$BIN/fm-spawn.sh" sm1 "$SM" --harness 'sleep 3600' --backend tmux --secondmate
lsmeta "$O"
rm -f "$O/data/secondmates.md"

hr "S5 happy path: registering parent home spawns sm1"
FM_HOME=$P run "$BIN/fm-spawn.sh" sm1 "$SM" --harness 'sleep 3600' --backend tmux --secondmate
lsmeta "$P"; lsmeta "$O"
[ -f "$P/state/sm1.meta" ] && { echo "-- $P/state/sm1.meta:"; cat "$P/state/sm1.meta"; }
tmux list-windows -a -F '#{session_name}:#{window_name}'

echo DRIVE-DONE
