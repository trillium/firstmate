#!/usr/bin/env bash
# Live scenario driver: real bin/fm-check-register.sh + real fm-watch-checkpoint.sh
# against disposable lab homes. Usage: drive-check-register.sh <worktree> <base-bin-dir>
set -u
WT=$1; BASEBIN=$2
. "$WT/bin/fm-pr-lib.sh"; mode() { fm_pr_file_mode "$1"; }
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; }
newlab() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$d" >/dev/null; echo "$d"; }
writecheck() { printf '#!/usr/bin/env bash\nprintf "custom check %s fired\\n"\n' "$2" > "$1/state/$2.check.sh"; chmod "$3" "$1/state/$2.check.sh"; }
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

echo "=== S0 baseline (base commit 69023626): 0600 check ==="
L=$(newlab); writecheck "$L" poll 0600
echo "before: mode $(mode $L/state/poll.check.sh)"
FM_HOME=$L run "$BASEBIN/fm-check-register.sh" poll
echo "after: mode $(mode $L/state/poll.check.sh); trust: $(ls $L/state/poll.check-trust 2>&1)"
FM_HOME=$L FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 run "$WT/bin/fm-watch-checkpoint.sh" --seconds 5
rm -rf "$L"

echo; echo "=== S1 fixed: 0600 check normalized, registered, and fired by the watcher ==="
L=$(newlab); writecheck "$L" poll 0600
echo "before: mode $(mode $L/state/poll.check.sh)"
FM_HOME=$L run "$WT/bin/fm-check-register.sh" poll
echo "after: mode $(mode $L/state/poll.check.sh); trust: $(ls $L/state/poll.check-trust 2>&1)"
FM_HOME=$L FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 run "$WT/bin/fm-watch-checkpoint.sh" --seconds 5
rm -rf "$L"

echo; echo "=== S2 fixed: 0755 and 0644 checks normalized to 0700; 0700 untouched ==="
L=$(newlab)
for m in 0755 0644 0700; do id=m$m; writecheck "$L" $id $m; FM_HOME=$L run "$WT/bin/fm-check-register.sh" $id; echo "$id -> mode $(mode $L/state/$id.check.sh)"; done
rm -rf "$L"

echo; echo "=== S3 adversarial: hard-linked 0600 check refused, named, not chmodded, no trust ==="
L=$(newlab); writecheck "$L" poll 0600; ln "$L/state/poll.check.sh" "$L/data/elsewhere.sh"
FM_HOME=$L run "$WT/bin/fm-check-register.sh" poll
echo "after: mode $(mode $L/state/poll.check.sh) (other link $(mode $L/data/elsewhere.sh)); trust: $(ls $L/state/poll.check-trust 2>&1)"
FM_HOME=$L FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 run "$WT/bin/fm-watch-checkpoint.sh" --seconds 4
rm -rf "$L"

echo; echo "=== S4 adversarial: symlinked check refused, target not chmodded ==="
L=$(newlab); printf '#!/bin/sh\n' > "$L/data/target.sh"; chmod 0600 "$L/data/target.sh"; ln -s "$L/data/target.sh" "$L/state/poll.check.sh"
FM_HOME=$L run "$WT/bin/fm-check-register.sh" poll
echo "target mode $(mode $L/data/target.sh); trust: $(ls $L/state/poll.check-trust 2>&1)"
rm -rf "$L"

echo; echo "=== S5 adversarial: check edited after registration is not fired ==="
L=$(newlab); writecheck "$L" poll 0600
FM_HOME=$L run "$WT/bin/fm-check-register.sh" poll
printf 'printf "tampered\\n"\n' >> "$L/state/poll.check.sh"
FM_HOME=$L FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 run "$WT/bin/fm-watch-checkpoint.sh" --seconds 4
rm -rf "$L"
