#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-origin-check.sh: the advisory scan that
# surfaces registered project clones whose remotes look like an unswapped or
# partially swapped fork-contribution setup (project-management skill's
# "Fork-contribution projects" convention: origin = the captain's
# trillium/<repo> fork, upstream = the original project, never the reverse).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-origin-check)

make_clone() {
  local dir=$1 origin=$2 upstream=${3:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
  [ -n "$upstream" ] && git -C "$dir" remote add upstream "$upstream"
  return 0
}

# Fake `gh` that answers `repo view trillium/<name> --json isFork -q .isFork`
# from a small in-fixture map, so the best-effort GitHub lookup never touches
# the network. An unmapped name behaves like a nonexistent repo (nonzero exit),
# matching how the real script treats a lookup failure: skip, never misreport.
make_fake_gh() {
  local fakebin=$1 map=$2
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
set -eu
if [ "\$1" = repo ] && [ "\$2" = view ]; then
  name=\$3
  case "\$name" in
$(awk -F= '{printf "    %s) echo %s; exit 0 ;;\n", $1, $2}' "$map")
    *) exit 1 ;;
  esac
fi
exit 1
EOF
  chmod +x "$fakebin/gh"
}

test_fork_origin_check_classifies_every_clone_shape() {
  local home fakebin map out
  home="$TMP_ROOT/registry-home"
  mkdir -p "$home/data" "$home/projects"
  fakebin=$(fm_fakebin "$TMP_ROOT/gh-shim")

  cat > "$home/data/projects.md" <<'EOF'
- ok-proj [no-mistakes] - ordinary Trillium-owned project (added 2026-08-01)
- swapped-proj [no-mistakes] - correctly swapped fork-contribution project (added 2026-08-01)
- partial-proj [no-mistakes] - swap started but origin never flipped (added 2026-08-01)
- candidate-proj [no-mistakes] - unswapped, trillium fork exists on GitHub (added 2026-08-01)
- plain-proj [no-mistakes] - non-Trillium origin with no fork relationship (added 2026-08-01)
- unregistered-note - a registry line with no matching clone (added 2026-08-01)
EOF

  # trillium origin, no upstream remote: an ordinary project, must stay silent.
  make_clone "$home/projects/ok-proj" "git@github.com:trillium/firstmate.git"
  # trillium origin, upstream remote set: correctly swapped, must stay silent.
  make_clone "$home/projects/swapped-proj" "git@github.com:trillium/rango.git" \
    "git@github.com:david-tejada/rango.git"
  # non-trillium origin, upstream remote set: swap started but not finished.
  make_clone "$home/projects/partial-proj" "https://github.com/someowner/somerepo.git" \
    "https://github.com/someowner/somerepo.git"
  # non-trillium origin, no upstream remote, and trillium/candidate-proj is a
  # real fork on GitHub per the fake gh map below.
  make_clone "$home/projects/candidate-proj" "git@github.com:david-tejada/rango.git"
  # non-trillium origin, no upstream remote, and trillium/plain-proj either
  # does not exist or is not a fork per the fake gh map: must stay silent.
  make_clone "$home/projects/plain-proj" "git@github.com:someoneelse/theirrepo.git"

  map="$TMP_ROOT/gh-map"
  cat > "$map" <<'EOF'
trillium/candidate-proj=true
trillium/plain-proj=false
EOF
  make_fake_gh "$fakebin" "$map"

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-fork-origin-check.sh")

  assert_not_contains "$out" "ok-proj" \
    "an ordinary Trillium-owned clone must not be reported"
  assert_not_contains "$out" "swapped-proj" \
    "a correctly swapped fork-contribution clone must not be reported"
  assert_contains "$out" "MISCONFIGURED: partial-proj" \
    "a partially swapped clone (origin still non-Trillium, upstream already set) must be reported MISCONFIGURED"
  assert_contains "$out" "CANDIDATE: candidate-proj" \
    "an unswapped clone whose trillium fork exists on GitHub must be reported CANDIDATE"
  assert_not_contains "$out" "plain-proj" \
    "a non-Trillium clone with no GitHub fork relationship must not be reported"
  pass "fm-fork-origin-check.sh: classifies ordinary, swapped, misconfigured, candidate, and unrelated clones correctly"
}

test_fork_origin_check_is_read_only_and_never_fails() {
  local home out rc
  home="$TMP_ROOT/clean-home"
  mkdir -p "$home/data" "$home/projects"
  cat > "$home/data/projects.md" <<'EOF'
- ok-proj [no-mistakes] - ordinary Trillium-owned project (added 2026-08-01)
EOF
  make_clone "$home/projects/ok-proj" "git@github.com:trillium/firstmate.git"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-fork-origin-check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-fork-origin-check.sh must exit 0 even when nothing is flagged"
  assert_contains "$out" "no misconfigured fork-contribution clones found" \
    "a clean fleet must say so explicitly rather than printing nothing"
  # Never a write path: no file besides the registry/clones we created exists.
  [ -e "$home/data/projects.md" ] || fail "registry must be untouched by a read-only scan"
  pass "fm-fork-origin-check.sh: exits 0 and reports cleanly with no findings"
}

test_fork_origin_check_missing_registry_is_not_an_error() {
  local home out rc
  home="$TMP_ROOT/no-registry-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-fork-origin-check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-fork-origin-check.sh must exit 0 when there is no registry yet"
  assert_contains "$out" "no registry at" \
    "an absent registry must be reported plainly, not silently swallowed"
  pass "fm-fork-origin-check.sh: an absent registry is reported, not an error"
}

# --- base checks ------------------------------------------------------------
#
# Correct remotes are not enough: a clone whose default branch sits on the
# upstream project's line passes every remote check above and still hands every
# worktree cut from it the wrong base. These fixtures use on-disk repos under
# <root>/<owner>/<name>.git so `owner_of` still reads "trillium" for origin and
# the targeted origin/<default> refresh works with no network.

git_q() { git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"; }

# Make an origin repo at <root>/<owner>/<name>.git with one commit on main, and
# echo its path.
make_remote() {
  local root=$1 owner=$2 name=$3 repo seed
  repo="$root/$owner/$name.git"
  seed="$root/$owner/$name.seed"
  mkdir -p "$root/$owner"
  git init -q --bare -b main "$repo"
  git init -q -b main "$seed"
  echo base > "$seed/README"
  git_q "$seed" add README
  git_q "$seed" commit -qm "base"
  git_q "$seed" push -q "$repo" main
  printf '%s\n' "$repo"
}

# Clone <origin> into <dir> and point an upstream remote at <upstream>: the
# correctly swapped fork-contribution shape the remote check passes in silence.
make_swapped_clone() {
  local dir=$1 origin=$2 upstream=$3
  git clone -q "$origin" "$dir"
  git -C "$dir" remote add upstream "$upstream"
}

test_fork_origin_check_flags_a_clone_pinned_to_upstreams_line() {
  local home root out origin upstream dir
  home="$TMP_ROOT/base-diverged-home"
  root="$TMP_ROOT/base-diverged-remotes"
  mkdir -p "$home/data" "$home/projects"
  cat > "$home/data/projects.md" <<'EOF'
- diverged-proj [no-mistakes] - swapped remotes, default pinned to upstream (added 2026-08-05)
EOF
  origin=$(make_remote "$root" trillium diverged-proj)
  upstream=$(make_remote "$root" someowner diverged-proj)
  dir="$home/projects/diverged-proj"
  make_swapped_clone "$dir" "$origin" "$upstream"
  # Local main carries commits origin/main does not: exactly what "reset to
  # upstream/main" leaves behind.
  echo upstream-work > "$dir/UPSTREAM"
  git_q "$dir" add UPSTREAM
  git_q "$dir" commit -qm "commit only upstream has"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-fork-origin-check.sh" --no-fetch)

  assert_contains "$out" "DIVERGED-BASE: diverged-proj" \
    "a swapped clone whose default branch is ahead of origin/ must be reported DIVERGED-BASE even though its remotes are correct"
  assert_contains "$out" "1 commits ahead of origin/main" \
    "the finding must quantify the divergence so the wrong base is visible, not just asserted"
  assert_not_contains "$out" "no misconfigured fork-contribution clones found" \
    "a diverged base is a finding, so the clean bill of health must not also print"
  pass "fm-fork-origin-check.sh: a correctly-remoted clone pinned to upstream's line is reported DIVERGED-BASE"
}

test_fork_origin_check_separates_ordinary_behind_from_diverged() {
  local home root out origin upstream dir seed
  home="$TMP_ROOT/base-behind-home"
  root="$TMP_ROOT/base-behind-remotes"
  mkdir -p "$home/data" "$home/projects"
  cat > "$home/data/projects.md" <<'EOF'
- behind-proj [no-mistakes] - swapped remotes, default merely behind origin (added 2026-08-05)
EOF
  origin=$(make_remote "$root" trillium behind-proj)
  upstream=$(make_remote "$root" someowner behind-proj)
  dir="$home/projects/behind-proj"
  make_swapped_clone "$dir" "$origin" "$upstream"
  # origin/main moves ahead; the clone's main stays put and gains nothing.
  seed="$root/trillium/behind-proj.seed"
  echo more > "$seed/NEXT"
  git_q "$seed" add NEXT
  git_q "$seed" commit -qm "origin moves ahead"
  git_q "$seed" push -q "$origin" main
  git -C "$dir" fetch -q origin

  out=$(FM_HOME="$home" "$ROOT/bin/fm-fork-origin-check.sh" --no-fetch)

  assert_contains "$out" "BEHIND: behind-proj" \
    "a clone merely behind origin must still be reported, distinctly from a diverged one"
  assert_not_contains "$out" "DIVERGED-BASE" \
    "being behind origin is not divergence and must not be reported as the wrong-base defect"
  assert_contains "$out" "no misconfigured fork-contribution clones found" \
    "ordinary drift that fleet sync fast-forwards must not count as a misconfiguration"
  pass "fm-fork-origin-check.sh: behind-origin drift is reported separately and is not a misconfiguration"
}

test_fork_origin_check_is_silent_on_a_correctly_based_clone() {
  local home root out origin upstream dir
  home="$TMP_ROOT/base-ok-home"
  root="$TMP_ROOT/base-ok-remotes"
  mkdir -p "$home/data" "$home/projects"
  cat > "$home/data/projects.md" <<'EOF'
- in-sync-proj [no-mistakes] - swapped remotes, default in sync with origin (added 2026-08-05)
- plain-trillium-proj [no-mistakes] - ordinary Trillium project, no fork relationship (added 2026-08-05)
EOF
  origin=$(make_remote "$root" trillium in-sync-proj)
  upstream=$(make_remote "$root" someowner in-sync-proj)
  make_swapped_clone "$home/projects/in-sync-proj" "$origin" "$upstream"

  # An ordinary Trillium clone with no upstream remote has no fork base to get
  # wrong; divergence there is fleet sync's business, not this scan's.
  origin=$(make_remote "$root" trillium plain-trillium-proj)
  git clone -q "$origin" "$home/projects/plain-trillium-proj"
  echo local > "$home/projects/plain-trillium-proj/LOCAL"
  git_q "$home/projects/plain-trillium-proj" add LOCAL
  git_q "$home/projects/plain-trillium-proj" commit -qm "local-only commit"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-fork-origin-check.sh" --no-fetch)

  assert_not_contains "$out" "in-sync-proj" \
    "a swapped clone whose default matches origin/ is the target state and must stay silent"
  assert_not_contains "$out" "plain-trillium-proj" \
    "an ordinary Trillium clone with no upstream remote must not get a fork base check"
  assert_contains "$out" "no misconfigured fork-contribution clones found" \
    "a fleet with correct remotes and correct bases must report a clean bill of health"
  pass "fm-fork-origin-check.sh: a correctly based swapped clone and an ordinary clone stay silent"
}

test_fork_origin_check_classifies_every_clone_shape
test_fork_origin_check_is_read_only_and_never_fails
test_fork_origin_check_missing_registry_is_not_an_error
test_fork_origin_check_flags_a_clone_pinned_to_upstreams_line
test_fork_origin_check_separates_ordinary_behind_from_diverged
test_fork_origin_check_is_silent_on_a_correctly_based_clone
