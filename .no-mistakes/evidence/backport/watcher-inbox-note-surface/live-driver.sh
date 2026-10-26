#!/usr/bin/env bash
# drive.sh <bin-root> : live drive of fm-watch.sh + fm-inbox.sh in a disposable lab home
set -u
ROOT=$1; WT=/Users/trilliumsmith/.no-mistakes/worktrees/ad28826778ca/01M5X75KBQSV98W9YKG8YNMNF0
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
E="env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB"
watch() { $E FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$1" 2>"$1.err" & }
waitexit() { local i=0; while [ $i -lt $2 ]; do kill -0 $1 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done; return 1; }
echo "== lab: $LAB  bin: $ROOT"
echo "== S0: warm-up watcher consumes first-start downtime recovery (steady-state live watcher)"
watch $LAB/w0.out; P=$!; if waitexit $P 30; then echo "warm-up exited: $(cat $LAB/w0.out)"; else echo "warm-up stayed live"; kill $P; wait $P 2>/dev/null; fi
watch $LAB/w0b.out; P=$!; if waitexit $P 30; then echo "warm-up2 exited: $(cat $LAB/w0b.out)"; else echo "warm-up2 stayed live (steady state reached)"; kill $P; wait $P 2>/dev/null; fi
echo "== S1: start idle handling-successor watcher, then capture a note with fm-inbox.sh"
watch $LAB/w1.out; P=$!; sleep 2
kill -0 $P && echo "watcher live (pid $P) before note"
OUT=$($E "$WT/bin/fm-inbox.sh" note -- "please continue the reminder work"); echo "fm-inbox.sh: $OUT"
ID=$(printf '%s\n' "$OUT" | sed -n 's/^queued //p' | head -1)
if waitexit $P 100; then echo "watcher EXITED (woke). stdout:"; cat $LAB/w1.out; else echo "watcher still running after 10s - NOTE NOT SURFACED"; kill $P; wait $P 2>/dev/null; fi
echo "queue rows:"; cat $LAB/state/.wake-queue
echo "== S2: second watcher while row still queued and note still pending (must stay quiet)"
watch $LAB/w2.out; P=$!
if waitexit $P 30; then echo "watcher EXITED: $(cat $LAB/w2.out)"; else echo "watcher stayed live 3s - no re-fire"; kill $P; wait $P 2>/dev/null; fi
echo "== S3: acknowledge note through fm-inbox.sh drain, then new watcher (must stay quiet)"
$E "$WT/bin/fm-inbox.sh" drain --ack "$ID" 2>&1 | tail -3
ls $LAB/state/inbox $LAB/state/inbox/handled 2>&1
echo "queue rows now:"; cat $LAB/state/.wake-queue 2>/dev/null
rm -f $LAB/state/.seen-inbox-*   # drop seen marker so only the handled check can keep it quiet
watch $LAB/w3.out; P=$!
if waitexit $P 30; then echo "watcher EXITED: $(cat $LAB/w3.out)"; else echo "watcher stayed live 3s - handled note not surfaced"; kill $P; wait $P 2>/dev/null; fi
echo "== S4: adversarial orphan / hostile / unrelated / symlinked check keys (must stay quiet)"
mkdir -p $LAB/state/inbox; echo x > $LAB/real.txt; ln -s $LAB/real.txt $LAB/state/inbox/symlinked.note
for k in "other:thing" "inbox:no-such-note" "inbox:../escape" "inbox:symlinked"; do
  $E FM_STATE_OVERRIDE=$LAB/state bash -c "STATE=$LAB/state; . '$WT/bin/fm-wake-lib.sh'; fm_wake_append check '$k' 'check: $k'" 2>&1 || echo "append via lib failed for $k"
done
echo "queue rows:"; cat $LAB/state/.wake-queue
watch $LAB/w4.out; P=$!
if waitexit $P 30; then echo "watcher EXITED: $(cat $LAB/w4.out)"; else echo "watcher stayed live 3s - none surfaced"; kill $P; wait $P 2>/dev/null; fi
rm -rf "$LAB"; echo "== lab removed"
