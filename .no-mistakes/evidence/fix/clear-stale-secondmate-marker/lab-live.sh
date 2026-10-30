#!/usr/bin/env bash
# Live check of the retired-secondmate identity handling, in a disposable lab.
# Usage: lab-live.sh <firstmate-checkout-with-the-change> <empty-lab-dir>
# Real fm-home-seed.sh / fm-teardown.sh / fm-spawn.sh and the real `treehouse`
# pool run against a private pool, home and tmux server inside <lab-dir>.
# Only the lab's own pool, home and tmux server are touched.
set -u
SRC=$(cd "$1" && pwd -P)
LAB=$2; mkdir -p "$LAB"; LAB=$(cd "$LAB" && pwd -P)
REALTH=$(command -v treehouse)
fails=0
check() { if "$@"; then echo "  PASS: $CHK"; else echo "  FAIL: $CHK"; fails=$((fails+1)); fi; }
ident() { [ -e "$1/.fm-secondmate-home" ] || [ -e "$1/.fm-secondmate-parent" ]; }

# Nothing from the invoking Herdr/tmux session may leak into the lab.
unset TMUX HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH
export TMUX_TMPDIR="$LAB/tmuxtmp" TREEHOUSE_ROOT="$LAB/pool"
mkdir -p "$TMUX_TMPDIR" "$LAB/pool" "$LAB/shim"

git clone -q --bare "$SRC" "$LAB/origin.git"
# the source checkout may be a detached HEAD; give the lab origin a main branch at it
git -C "$LAB/origin.git" branch -f main "$(git -C "$SRC" rev-parse HEAD)"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/fmroot"
git -C "$LAB/fmroot" checkout -q --detach "$(git -C "$SRC" rev-parse HEAD)"
git -C "$LAB/fmroot" remote add upstream https://github.com/lab-only/firstmate.git
export FM_ROOT_OVERRIDE="$LAB/fmroot" FM_HOME="$LAB/home"
mkdir -p "$FM_HOME"/{data,state,config,projects}
echo 'maintainer github.com/lab-only/firstmate' > "$FM_HOME/config/firstmate-role"
echo tmux > "$FM_HOME/config/backend"
ln -sfn "$LAB/fmroot" "$FM_HOME/projects/fmroot"
cat > "$LAB/shim/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ] && [ -n "\${LAB_HANG_RETURN:-}" ]; then echo \$\$ > "\$LAB_HANG_RETURN"; exec sleep 300; fi
if [ "\${1:-}" = return ] && [ -n "\${LAB_FAIL_RETURN:-}" ]; then echo "treehouse: return refused (lab-injected failure)" >&2; exit 1; fi
exec $REALTH "\$@"
EOF
chmod +x "$LAB/shim/treehouse"
cd "$LAB/fmroot" || exit 2
. bin/fm-primary-scope-lib.sh
primary() { fm_primary_root_matches "$1" && echo YES || echo no; }
seed() {  # <id> -> echoes home
  FM_SECONDMATE_CHARTER="Lab secondmate $1" FM_SECONDMATE_SCOPE='lab only' \
    bin/fm-home-seed.sh "$1" - --no-projects >"$LAB/seed-$1.out" 2>&1 || { cat "$LAB/seed-$1.out"; exit 2; }
  sed -n 's/^home=//p' "$LAB/seed-$1.out"
}
write_meta() {  # <id> <home>
  cat > "$FM_HOME/state/$1.meta" <<EOF
window=labtm:fm-$1
endpoint_task_id=$1
worktree=$2
home=$2
project=$LAB/fmroot
harness=claude
kind=secondmate
mode=secondmate
spawn_gen=lab-$1
EOF
}
teardown() { bin/fm-teardown.sh "$@" 2>&1 | grep -v -e '^●' -e '^WARNING: watcher'; return "${PIPESTATUS[0]}"; }

echo "=== lab: firstmate change $(git -C "$SRC" rev-parse --short HEAD), treehouse $($REALTH --version 2>&1 | head -1) ==="

echo; echo "=== Scenario A: a retirement whose lease return fails keeps the home's identity ==="
H=$(seed alpha); write_meta alpha "$H"
echo "\$ ls -a <alpha home> | grep fm-secondmate"; ls -a "$H" | grep fm-secondmate
echo "\$ LAB_FAIL_RETURN=1 bin/fm-teardown.sh alpha --force"
LAB_FAIL_RETURN=1 PATH="$LAB/shim:$PATH" teardown alpha --force; rc=$?; echo "teardown exit status: $rc"
echo "\$ ls -a <alpha home> | grep fm-secondmate"; ls -a "$H" | grep fm-secondmate
CHK="teardown reported the failed return"; check test "$rc" -ne 0
CHK="the preserved home kept .fm-secondmate-home with its id"; check test "$(cat "$H/.fm-secondmate-home" 2>/dev/null)" = alpha
CHK="the preserved home kept .fm-secondmate-parent"; check test -f "$H/.fm-secondmate-parent"
CHK="no identity stash was left behind"; check test -z "$(ls -a "$(dirname "$H")" | grep identity-restore)"
CHK="the lease is still held by alpha"; treehouse status | grep -q 'held by alpha'; check test $? -eq 0

echo; echo "=== Scenario B: retiring a home (killed mid-return, then retried) frees a slot a task can lease with no marker ==="
echo "\$ primary-home guards fire in <alpha home>?  $(primary "$H")"
rm -f "$LAB/hang.pid"
LAB_HANG_RETURN="$LAB/hang.pid" PATH="$LAB/shim:$PATH" bin/fm-teardown.sh alpha --force >"$LAB/b-run1.out" 2>&1 &
TD=$!
for _ in $(seq 1 150); do [ -s "$LAB/hang.pid" ] && break; sleep 0.2; done
echo "\$ (teardown is inside treehouse return) ls -a <alpha home> | grep fm-secondmate"; ls -a "$H" | grep fm-secondmate || echo "(identity files staged aside)"
echo "\$ ls -a <slot parent> | grep identity-restore"; ls -a "$(dirname "$H")" | grep identity-restore
STASHED=0; ident "$H" || STASHED=1
kill -KILL "$TD" "$(cat "$LAB/hang.pid" 2>/dev/null)" 2>/dev/null; wait "$TD" 2>/dev/null
echo "(teardown killed)"
CHK="the identity files were staged aside while the return was in flight"; check test "$STASHED" -eq 1
echo "\$ bin/fm-teardown.sh alpha --force   # the retry, with the real treehouse"
teardown alpha --force; rc=$?; echo "teardown exit status: $rc"
CHK="the retry completed"; check test "$rc" -eq 0
CHK="the retired home left no .fm-secondmate-* file in its slot"; check test -z "$(ls -a "$H" | grep fm-secondmate)"
CHK="no identity stash was left behind"; check test -z "$(ls -a "$(dirname "$H")" | grep identity-restore)"
echo "\$ treehouse status"; treehouse status
echo "\$ treehouse get --lease   # the next task takes the pool slot"
T=$(treehouse get --lease 2>/dev/null); echo "$T"
CHK="the task got the retired home's own slot"; check test "$T" = "$H"
echo "\$ ls -a <leased slot> | grep fm-secondmate"; ls -a "$T" | grep fm-secondmate || echo "(none)"
echo "\$ primary-home guards fire in the leased slot?  $(primary "$T")"
CHK="no primary-home guard would fire in the task's slot"; check test "$(primary "$T")" = no
treehouse return "$T" >/dev/null 2>&1

echo; echo "=== Scenario C: a spawn into a slot of a still-registered secondmate is refused ==="
H=$(seed beta)
echo "\$ cat data/secondmates.md"; cut -c1-70 "$FM_HOME/data/secondmates.md"
echo "\$ treehouse return <beta home>   # lease released out of band; the registry still names beta"
treehouse return "$H" 2>&1 | tail -1
echo "\$ ls -a <beta home> | grep fm-secondmate"; ls -a "$H" | grep fm-secondmate
bin/fm-brief.sh labtask fmroot --mode no-mistakes >/dev/null 2>&1
python3 - "$FM_HOME/data/labtask/brief.md" <<'EOF'
import sys
p=sys.argv[1]; s=open(p).read().replace('{TASK}','Lab task.').replace('{FIRSTMATE_SPEC}','Lab only.')
open(p,'w').write(s)
EOF
echo "\$ bin/fm-spawn.sh labtask <project> --mode no-mistakes --yolo off --backend tmux"
bin/fm-spawn.sh labtask "$LAB/fmroot" --mode no-mistakes --yolo off --harness 'sleep 600' --backend tmux 2>&1 | fold -s -w 140 | tee "$LAB/c-spawn.out"
rc=${PIPESTATUS[0]}; echo "spawn exit status: $rc"
CHK="the spawn was refused"; check test "$rc" -ne 0
CHK="the refusal names the live secondmate home"; check sh -c "tr -d '\\n' < '$LAB/c-spawn.out' | grep -q \"home of secondmate 'beta', still registered in\""
CHK="the refused spawn left beta's identity files in place"; check ident "$H"
CHK="no task record was written"; check test ! -e "$FM_HOME/state/labtask.meta"

echo; echo "=== Scenario D: a pre-fix leaked slot (marker + binding to this home, id retired) is cleared by spawn, even with FM_HOME reached through a symlink ==="
H=$(seed gamma)
treehouse return "$H" 2>&1 | tail -1
cp "$H/.fm-secondmate-home" "$H/.fm-secondmate-parent" "$LAB/" 2>/dev/null
python3 - "$FM_HOME/data/secondmates.md" <<'PY'
import sys
p=sys.argv[1]; lines=open(p).read().splitlines(True)
open(p,'w').write(''.join(l for l in lines if 'gamma' not in l))
PY
# simulate the pre-fix leak: put the identity back as an old retirement would have left it
cp "$LAB/.fm-secondmate-home" "$LAB/.fm-secondmate-parent" "$H/"
echo "\$ cat <slot>/.fm-secondmate-parent"; cat "$H/.fm-secondmate-parent"
ln -sfn "$FM_HOME" "$LAB/home-link"
bin/fm-brief.sh labtask2 fmroot --mode no-mistakes >/dev/null 2>&1
python3 - "$FM_HOME/data/labtask2/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('{TASK}','Lab task.').replace('{FIRSTMATE_SPEC}','Lab only.')
open(p,'w').write(s)
PY
echo "\$ FM_HOME=<symlink to home> bin/fm-spawn.sh labtask2 <project> --mode no-mistakes --yolo off --backend tmux"
FM_HOME="$LAB/home-link" bin/fm-spawn.sh labtask2 "$LAB/fmroot" --mode no-mistakes --yolo off --harness 'sleep 600' --backend tmux 2>&1 | fold -s -w 140 | tee "$LAB/d-spawn.out"
rc=${PIPESTATUS[0]}; echo "spawn exit status: $rc"
W=$(sed -n 's/^worktree=//p' "$FM_HOME/state/labtask2.meta" 2>/dev/null)
echo "task worktree: $W"
CHK="spawn reported clearing the stale marker"; check grep -q "cleared a stale secondmate-home marker ('gamma')" "$LAB/d-spawn.out"
CHK="the task worktree carries no identity files"; check test -n "$W" -a ! -e "$W/.fm-secondmate-home" -a ! -e "$W/.fm-secondmate-parent"
CHK="no primary-home guard would fire in the task worktree"; check test -n "$W" -a "$(primary "$W")" = no

echo; echo "=== Scenario E: a slot whose binding names a different parent home is refused with that home named ==="
H=$(seed delta)
treehouse return "$H" 2>&1 | tail -1
python3 - "$FM_HOME/data/secondmates.md" <<'PY'
import sys
p=sys.argv[1]; lines=open(p).read().splitlines(True)
open(p,'w').write(''.join(l for l in lines if 'delta' not in l))
PY
mkdir -p "$LAB/otherhome"; OTHER=$(cd "$LAB/otherhome" && pwd -P)
sed -i '' "s#^parent_home=.*#parent_home=$OTHER#" "$H/.fm-secondmate-parent"
echo "\$ cat <slot>/.fm-secondmate-parent"; cat "$H/.fm-secondmate-parent"
bin/fm-brief.sh labtask3 fmroot --mode no-mistakes >/dev/null 2>&1
python3 - "$FM_HOME/data/labtask3/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('{TASK}','Lab task.').replace('{FIRSTMATE_SPEC}','Lab only.')
open(p,'w').write(s)
PY
bin/fm-spawn.sh labtask3 "$LAB/fmroot" --mode no-mistakes --yolo off --harness 'sleep 600' --backend tmux 2>&1 | fold -s -w 140 | tee "$LAB/e-spawn.out"
rc=${PIPESTATUS[0]}; echo "spawn exit status: $rc"
CHK="the spawn was refused"; check test "$rc" -ne 0
CHK="the refusal names the other parent home"; check sh -c "tr -d '\\n' < '$LAB/e-spawn.out' | grep -qF \"bound to parent home '$OTHER', not this home\""
CHK="the slot kept its identity files"; check ident "$H"
CHK="no task record was written"; check test ! -e "$FM_HOME/state/labtask3.meta"

tmux kill-server >/dev/null 2>&1 || true
echo; if [ "$fails" -eq 0 ]; then echo "LIVE RESULT: 5/5 scenarios passed"; else echo "LIVE RESULT: $fails check(s) FAILED"; fi
exit "$fails"
