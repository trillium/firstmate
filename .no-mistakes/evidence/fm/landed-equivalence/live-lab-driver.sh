#!/usr/bin/env bash
# Live drive of fm-teardown.sh / fm-merge-local.sh against a disposable lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
FB="$LAB/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/treehouse"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
cat > "$FB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac
exit 0
SH
printf '#!/usr/bin/env bash\necho "not found" >&2\nexit 1\n' > "$FB/gh"
chmod +x "$FB"/*
G() { git -c user.email=t@t -c user.name=t "$@"; }
env_run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" PATH="$FB:$PATH" "$@"; }
setup() { # <id> <mode>
  local id=$1 mode=$2 c="$LAB/projects/$1"
  git init -q --bare "$c.origin.git"; git -C "$c.origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c.origin.git" "$c" 2>/dev/null
  printf 'base\n' > "$c/README"; git -C "$c" add README; G -C "$c" commit -q -m base; git -C "$c" push -q origin main
  git -C "$c" remote set-head origin main
  [ "$mode" = local-only ] && git -C "$c" remote remove origin
  git -C "$c" worktree add -q -b "fm/$id" "$LAB/wt-$id" main
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/wt-$id" "project=$c" "kind=ship" "mode=$mode" "branch=fm/$id" "spawn_gen=lab-$id" > "$LAB/state/$id.meta"
  touch "$LAB/state/.last-watcher-beat"
}
commit_wt() { printf '%s\n' "$3" > "$LAB/wt-$1/$2"; git -C "$LAB/wt-$1" add "$2"; G -C "$LAB/wt-$1" commit -q -m "task: $2"; }
teardown() { echo "\$ fm-teardown.sh $1"; env_run "$ROOT/bin/fm-teardown.sh" "$1" > "$LAB/out" 2>&1; local rc=$?; grep -E 'landed proof|REFUSED|commits not yet|unpushed commits|^[0-9a-f]{7} ' "$LAB/out"; echo "exit=$rc"; echo "task meta removed: $([ -e "$LAB/state/$1.meta" ] && echo no || echo yes)"; }
land_clone() { LANDTMP="$LAB/_land_$1"; git clone -q "$LAB/projects/$1.origin.git" "$LANDTMP"; }
hdr() { echo; echo "=== $* ==="; }

hdr "S1 local-only: work re-applied onto main by another task as new commits, recorded with --record-landed"
setup t-replay local-only; commit_wt t-replay a.txt alpha; commit_wt t-replay b.txt beta
P="$LAB/projects/t-replay"; for c in $(git -C "$P" rev-list --reverse main..fm/t-replay); do G -C "$P" cherry-pick -x "$c" >/dev/null; done
G -C "$P" commit -q --allow-empty -m "unrelated later main commit"
echo "branch head $(git -C "$P" rev-parse --short fm/t-replay); main $(git -C "$P" rev-parse --short main); branch ancestor of main? $(git -C "$P" merge-base --is-ancestor fm/t-replay main && echo yes || echo no)"
echo "\$ fm-merge-local.sh --record-landed t-replay"; env_run "$ROOT/bin/fm-merge-local.sh" --record-landed t-replay 2>&1; echo "exit=$?"
echo "meta: $(grep landed_equivalent "$LAB/state/t-replay.meta")"
echo "branch head after record: $(git -C "$P" rev-parse --short fm/t-replay); main after record: $(git -C "$P" rev-parse --short main)"
teardown t-replay

hdr "S2 local-only: patch-equivalent replay, no record (teardown proves it itself)"
setup t-eq local-only; commit_wt t-eq a.txt alpha
P="$LAB/projects/t-eq"; G -C "$P" cherry-pick -x fm/t-eq >/dev/null
teardown t-eq

hdr "S2b local-only: plain fast-forward landing still uses ancestry"
setup t-ff local-only; commit_wt t-ff a.txt alpha
P="$LAB/projects/t-ff"; git -C "$P" merge -q --ff-only fm/t-ff
teardown t-ff

hdr "S3 ADVERSARIAL conflict-resolved replay (patch changed): record refused, teardown refuses"
setup t-conf local-only; commit_wt t-conf a.txt alpha
P="$LAB/projects/t-conf"; printf 'alpha-resolved\n' > "$P/a.txt"; git -C "$P" add a.txt; G -C "$P" commit -q -m "replay with resolution"
echo "\$ fm-merge-local.sh --record-landed t-conf"; env_run "$ROOT/bin/fm-merge-local.sh" --record-landed t-conf 2>&1; echo "exit=$?"
echo "meta landed_equivalent line: '$(grep landed_equivalent "$LAB/state/t-conf.meta")'"
teardown t-conf

hdr "S4 ADVERSARIAL replay that changed only indentation refuses (plain git cherry would accept)"
setup t-ws local-only; printf 'def f():\n    return 1\n' > "$LAB/wt-t-ws/f.py"; git -C "$LAB/wt-t-ws" add f.py; G -C "$LAB/wt-t-ws" commit -q -m py
P="$LAB/projects/t-ws"; printf 'def f():\n  return 1\n' > "$P/f.py"; git -C "$P" add f.py; G -C "$P" commit -q -m py-reindented
echo "plain git cherry main fm/t-ws: $(git -C "$P" cherry main fm/t-ws)"
echo "\$ fm-merge-local.sh --record-landed t-ws"; env_run "$ROOT/bin/fm-merge-local.sh" --record-landed t-ws 2>&1; echo "exit=$?"
teardown t-ws

hdr "S5 ADVERSARIAL equivalent replay but uncommitted change in the task copy refuses"
setup t-dirty local-only; commit_wt t-dirty a.txt alpha
P="$LAB/projects/t-dirty"; G -C "$P" cherry-pick -x fm/t-dirty >/dev/null; printf 'wip\n' >> "$LAB/wt-t-dirty/a.txt"
teardown t-dirty

hdr "S6 ADVERSARIAL record, then worker adds a commit: stale record no longer counts"
setup t-stale local-only; commit_wt t-stale a.txt alpha
P="$LAB/projects/t-stale"; G -C "$P" cherry-pick -x fm/t-stale >/dev/null
env_run "$ROOT/bin/fm-merge-local.sh" --record-landed t-stale >/dev/null 2>&1; echo "recorded: $(grep landed_equivalent "$LAB/state/t-stale.meta")"
commit_wt t-stale c.txt new-unlanded
teardown t-stale

hdr "S7 ADVERSARIAL --record-landed on a non-local-only task refuses"
setup t-nm no-mistakes; commit_wt t-nm a.txt alpha
echo "\$ fm-merge-local.sh --record-landed t-nm"; env_run "$ROOT/bin/fm-merge-local.sh" --record-landed t-nm 2>&1; echo "exit=$?"

hdr "S8 PR task: squash-merged PR (one-parent merge) whose recorded head equals the branch head"
setup t-sq no-mistakes; commit_wt t-sq a.txt alpha; commit_wt t-sq a.txt alpha2
H=$(git -C "$LAB/wt-t-sq" rev-parse HEAD)
land_clone t-sq; printf 'alpha2\n' > "$LANDTMP/a.txt"; printf x > "$LANDTMP/other"; git -C "$LANDTMP" add -A; G -C "$LANDTMP" commit -q -m "squash (#7)"; printf 'alpha3\n' > "$LANDTMP/a.txt"; G -C "$LANDTMP" commit -qam later; git -C "$LANDTMP" push -q origin main
echo "pr=https://github.com/example/repo/pull/7" >> "$LAB/state/t-sq.meta"
cat > "$FB/gh" <<SH
#!/usr/bin/env bash
case " \$* " in *"pr view"*"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED $H https://github.com/example/repo/pull/7; exit 0;; *"pr view"*headRefOid*) echo $H; exit 0;; esac
echo "not found" >&2; exit 1
SH
teardown t-sq

hdr "S9 ADVERSARIAL PR task: PR 7 reported merged with a different head, content differs -> refuses"
setup t-sq2 no-mistakes; commit_wt t-sq2 a.txt alpha
land_clone t-sq2; printf 'other\n' > "$LANDTMP/a.txt"; git -C "$LANDTMP" add -A; G -C "$LANDTMP" commit -q -m "squash"; git -C "$LANDTMP" push -q origin main
echo "pr=https://github.com/example/repo/pull/7" >> "$LAB/state/t-sq2.meta"
teardown t-sq2

hdr "S10 PR task fully pushed, PR unmerged: tears down with no false 'landed proof' line"
printf '#!/usr/bin/env bash\necho "not found" >&2\nexit 1\n' > "$FB/gh"
setup t-push no-mistakes; commit_wt t-push a.txt alpha; git -C "$LAB/wt-t-push" push -q origin fm/t-push
teardown t-push

hdr "S11 PR task: its single commit reached origin/main through another task under a new SHA"
setup t-other no-mistakes; commit_wt t-other a.txt alpha
land_clone t-other; git -C "$LANDTMP" fetch -q "$LAB/wt-t-other" fm/t-other; G -C "$LANDTMP" cherry-pick -x "$(git -C "$LAB/wt-t-other" rev-parse HEAD)" >/dev/null; printf 'alpha\nmore\n' > "$LANDTMP/a.txt"; G -C "$LANDTMP" commit -qam later; git -C "$LANDTMP" push -q origin main
echo "git cherry origin/main HEAD: $(git -C "$LAB/wt-t-other" fetch -q origin; git -C "$LAB/wt-t-other" cherry origin/main HEAD)"
teardown t-other

rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
