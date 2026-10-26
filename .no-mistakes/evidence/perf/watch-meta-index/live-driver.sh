#!/usr/bin/env bash
# live.sh <code-root> <label> <beat-interval> <observe-secs> <N>
set -u
ROOTDIR=$1 LABEL=$2 INTERVAL=$3 SPAN=$4 N=$5
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOTDIR/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin"
export TMUX_TMPDIR="$LAB/tmux"; ln -s /sbin/md5 "$LAB/md5bin-md5" 2>/dev/null; mkdir -p "$LAB/md5bin"; mv "$LAB/md5bin-md5" "$LAB/md5bin/md5"; export PATH="$LAB/md5bin:$PATH"
T() { tmux -L fm-lab "$@"; }
cat > "$LAB/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
echo 'state: working · source: pane · busy'
SH
chmod +x "$LAB/fakebin/fm-crew-state.sh"
T new-session -d -s lab -n fm-w0 'sleep 100000'
for i in $(seq 1 "$N"); do
  T new-window -d -t lab -n "fm-w$i" "while :; do date; sleep 2; done"
  printf 'window=lab:fm-w%s\nkind=ship\nharness=codex\nproject=p\n' "$i" > "$LAB/state/w$i.meta"
done
echo "windows: $(T list-windows -t lab | wc -l | tr -d ' ')  metas: $(ls "$LAB/state"/*.meta | wc -l | tr -d ' ')"
T new-window -d -t lab -n watcher "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' FM_CREW_STATE_BIN='$LAB/fakebin/fm-crew-state.sh' FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 $( [ "$INTERVAL" = default ] || echo FM_WATCHER_BEAT_INTERVAL=$INTERVAL ) bash '$ROOTDIR/bin/fm-watch.sh' > '$LAB/watch.out' 2> '$LAB/watch.err'; echo exit=\$? >> '$LAB/watch.out'; sleep 100000"
i=0; while [ ! -e "$LAB/state/.last-watcher-beat" ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
python3 - "$LAB/state/.last-watcher-beat" "$SPAN" <<'PY'
import os, sys, time
p, span = sys.argv[1], float(sys.argv[2])
end=time.time()+span; lm=os.stat(p).st_mtime; lt=time.time(); gaps=[]
while time.time()<end:
    time.sleep(0.1)
    try: m=os.stat(p).st_mtime
    except OSError: continue
    if m!=lm: gaps.append(time.time()-lt); lm=m; lt=time.time()
tail=time.time()-lt
print("steady_max_gap_excl_first=%.1fs " % max(gaps[1:]+[tail]) + "beats=%d max_gap=%.1fs open_gap_at_end=%.1fs gaps=%s" % (len(gaps), max(gaps+[tail]), tail, ",".join("%.1f"%g for g in gaps[:12])))
PY
echo "watcher out: $(tail -3 "$LAB/watch.out" 2>/dev/null | tr '\n' ' ') err: $(tail -3 "$LAB/watch.err" 2>/dev/null | tr '\n' ' ')"
T kill-server; sleep 2
rm -rf "$LAB" || { sleep 3; rm -rf "$LAB"; }
echo "[$LABEL] lab torn down"
