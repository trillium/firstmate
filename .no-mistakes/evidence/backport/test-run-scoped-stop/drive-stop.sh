#!/usr/bin/env bash
# Live drive of bin/fm-test-run.sh --stop in a disposable repo copy + TMPDIR.
set -u
SRC=${1:?worktree}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-stop-live.XXXXXX")
trap 'pkill -f "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; mkdir -p $R/bin $R/tests
cp $SRC/bin/fm-test-run.sh $SRC/bin/fm-timeout-lib.sh $R/bin/; cp $SRC/tests/git-config-helpers.sh $R/tests/
cat >$R/tests/fm-sleep-fixture.test.sh <<'EOF'
#!/usr/bin/env bash
printf "%s\n" "$$" >"$TMPDIR/fixture-$MARK.pid"
echo "ok - sleeping"; sleep 60
EOF
chmod +x $R/tests/*.sh $R/bin/*.sh
RUN=$R/bin/fm-test-run.sh; S=tests/fm-sleep-fixture.test.sh
PD="$T/fm-test-run-pids-$(id -u)"
waitfix(){ for _ in $(seq 100); do [ -s "$T/fixture-$1.pid" ] && return; sleep 0.1; done; }
alive(){ kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
echo "=== S1: two concurrent runs, --stop lists both, --stop <id> kills only one"
(cd $R; MARK=a TZ=UTC TMPDIR=$T $RUN $S >$T/a.out 2>&1) & A=$!
(cd $R; MARK=b TMPDIR=$T $RUN $S >$T/b.out 2>&1) & B=$!
waitfix a; waitfix b
echo "registry mode: $(ls -ld "$PD" | awk "{print \$1, \$3}")"
echo "\$ fm-test-run.sh --stop   (TZ=Pacific/Kiritimati)"; TZ=Pacific/Kiritimati TMPDIR=$T $RUN --stop | tee $T/list
AID=$(sed -n 1p $T/list | awk '{print $1}')
AOUT=$(grep -l "fixture" /dev/null; true)
# figure which list entry is run a: the one whose fixture is a's child
for id in $(awk '{print $1}' $T/list); do p=$(grep "^$id " $T/list | sed 's/.*pid=//'); if pgrep -P $p >/dev/null && pgrep -P $p | xargs -I{} pgrep -P {} 2>/dev/null | grep -qx "$(cat $T/fixture-a.pid)"; then AID=$id; fi; done
echo "\$ fm-test-run.sh --stop $AID"; TMPDIR=$T $RUN --stop "$AID"; echo "exit=$?"
wait $A; echo "run A exit=$?"; cat $T/a.out | tail -2
sleep 0.5
echo "run A fixture child: $(alive $(cat $T/fixture-a.pid)); pid record present: $([ -e $PD/$AID.pid ] && echo yes || echo no)"
echo "run B fixture child: $(alive $(cat $T/fixture-b.pid)); run B aborted?: $(grep -c FM_TEST_ABORTED $T/b.out)"
echo "\$ fm-test-run.sh --stop"; TMPDIR=$T $RUN --stop
BID=$(TMPDIR=$T $RUN --stop | awk '{print $1}'); TMPDIR=$T $RUN --stop "$BID"; wait $B; echo "run B exit=$?"

echo; echo "=== S2: decoy whose command line contains fm-test-run is never signalled"
mkdir -p $T/decoy/tests; printf '#!/usr/bin/env bash\nsleep 60\n' >$T/decoy/tests/fm-test-run.test.sh
(cd $T/decoy; exec bash tests/fm-test-run.test.sh) & D=$!
sleep 0.3; echo "decoy cmd: $(ps -o command= -p $D)"
printf '%s %s\n' $D "$(LC_ALL=C TZ=UTC ps -o lstart= -p $D | sed 's/^ *//')" >$PD/fake-decoy.pid
echo "\$ fm-test-run.sh --stop fake-decoy"; TMPDIR=$T $RUN --stop fake-decoy; echo "exit=$?"
echo "decoy: $(alive $D); planted record kept: $([ -e $PD/fake-decoy.pid ] && echo yes || echo no)"; kill $D

echo; echo "=== S3: live runner pid with wrong start time (pid reuse) is never signalled"
(cd $R; MARK=c TMPDIR=$T $RUN $S >$T/c.out 2>&1) & C=$!; waitfix c
CPID=$(TMPDIR=$T $RUN --stop | sed 's/.*pid=//')
printf '%s %s\n' $CPID "Thu Jan  1 00:00:00 2015" >$PD/fake-reuse.pid
echo "\$ fm-test-run.sh --stop fake-reuse   (record has real runner pid $CPID, stale start)"; TMPDIR=$T $RUN --stop fake-reuse; echo "exit=$?"
echo "runner C: $(alive $CPID)"

echo; echo "=== S5: TERM sent straight to the runner aborts a hung script promptly"
t0=$(date +%s); kill -TERM $CPID; wait $C; rc=$?; t1=$(date +%s)
echo "runner C exit=$rc after $((t1-t0))s; output tail: $(tail -1 $T/c.out)"; sleep 0.3
echo "C fixture child: $(alive $(cat $T/fixture-c.pid))"

echo; echo "=== S4: a pre-created non-private registry is refused"
rm -rf "$PD"; mkdir -m 755 "$PD"; echo "registry mode: $(ls -ld "$PD" | awk "{print \$1}")"
echo "\$ fm-test-run.sh $S"; (cd $R; MARK=d TMPDIR=$T $RUN $S); echo "exit=$?  fixture ran: $([ -e $T/fixture-d.pid ] && echo yes || echo no)"
echo "\$ fm-test-run.sh --stop"; TMPDIR=$T $RUN --stop; echo "exit=$?"
rm -rf "$PD"; mkdir -m 700 $T/elsewhere; ln -s $T/elsewhere "$PD"; echo "registry is symlink -> elsewhere (mode 700)"
echo "\$ fm-test-run.sh --stop"; TMPDIR=$T $RUN --stop; echo "exit=$?"
echo "\$ fm-test-run.sh $S"; (cd $R; MARK=e TMPDIR=$T $RUN $S); echo "exit=$?"
rm -f "$PD"

echo; echo "=== S6: native Windows Bash (stubbed uname -> MINGW64_NT): no registration, --stop refuses"
mkdir $T/stub; printf '#!/bin/sh\necho MINGW64_NT-10.0\n' >$T/stub/uname; chmod +x $T/stub/uname
cat >$R/tests/fm-quick.test.sh <<'EOF'
#!/usr/bin/env bash
echo "ok - quick"
EOF
chmod +x $R/tests/fm-quick.test.sh
echo "\$ fm-test-run.sh tests/fm-quick.test.sh"; (cd $R; PATH=$T/stub:$PATH TMPDIR=$T $RUN tests/fm-quick.test.sh 2>&1 | tail -3); echo "exit=${PIPESTATUS[0]}  registry created: $([ -e "$PD" ] && echo yes || echo no)"
echo "\$ fm-test-run.sh --stop"; PATH=$T/stub:$PATH TMPDIR=$T $RUN --stop; echo "exit=$?"
echo "\$ fm-test-run.sh --stop=some-id"; PATH=$T/stub:$PATH TMPDIR=$T $RUN --stop=some-id; echo "exit=$?"
