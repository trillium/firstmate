#!/usr/bin/env bash
# Structural guard: no test may enroll with the live parlay relay.
#
# bin/fm-spawn.sh registers the agent it spawns with `parlay listen` unless
# FM_SPAWN_SKIP_PARLAY is set. tests/lib.sh exports that guard, but ten test
# files rolled their own boilerplate instead of sourcing the library, so every
# run of those suites announced a real agent to the production relay and left
# the listener reparented to init on exit - the leaked ids fdev, e2esm1, lwsm2
# and design all traced back to exactly those files (robots-4nkn). Fixing the
# ten was not enough: the next test file written the same way would reintroduce
# it silently. This test makes the omission a failure instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Files that hand the guard to whoever sources them, as "<name> exports it".
provides_guard() {  # <file>
  grep -Eq '^[[:space:]]*export[[:space:]]+FM_SPAWN_SKIP_PARLAY=' "$1"
}

# Names of tests/*.sh this file pulls in, one per line. Only the basename is
# resolved: every shared helper in this suite lives directly under tests/.
sourced_siblings() {  # <file>
  grep -Eo '^[[:space:]]*(\.|source)[[:space:]]+[^#]*/[a-zA-Z0-9._-]+\.sh' "$1" \
    | grep -Eo '[a-zA-Z0-9._-]+\.sh$'
}

# True when <file> sets the guard itself or inherits it through a helper it
# sources (transitively - several suites reach lib.sh only via a helper such as
# secondmate-helpers.sh). SEEN guards against a helper cycle.
guarded() {  # <file>
  local file=$1 sibling
  provides_guard "$file" && return 0
  case " ${SEEN:-} " in *" $file "*) return 1 ;; esac
  SEEN="${SEEN:-} $file"
  for sibling in $(sourced_siblings "$file"); do
    [ -f "$ROOT/tests/$sibling" ] || continue
    guarded "$ROOT/tests/$sibling" && return 0
  done
  return 1
}

test_library_exports_the_guard() {
  provides_guard "$ROOT/tests/lib.sh" \
    || fail "tests/lib.sh must export FM_SPAWN_SKIP_PARLAY - it is the guard every sourcing test inherits"
  pass "tests/lib.sh exports FM_SPAWN_SKIP_PARLAY"
}

# Files that name bin/fm-spawn.sh without ever running it. The scan below is
# deliberately a plain mention-match rather than an attempt to tell an
# invocation from an argument: a parser that guesses wrong lets a real leak
# through silently, which is the exact failure this test exists to stop. So the
# default is "guard it", and an exemption has to be written down here with a
# reason.
#   fork-features.sh - greps the script's source text for feature markers
#                      (`grep -q '--account' bin/fm-spawn.sh`); never executes it.
INSPECTION_ONLY="fork-features.sh"

test_every_spawning_test_is_guarded() {
  local file unguarded="" checked=0
  for file in "$ROOT"/tests/*.sh; do
    grep -q 'fm-spawn\.sh' "$file" || continue
    case " $INSPECTION_ONLY " in *" $(basename "$file") "*) continue ;; esac
    checked=$((checked + 1))
    SEEN=""
    guarded "$file" || unguarded="$unguarded"$'\n'"  tests/$(basename "$file")"
  done

  # A rename or a reorganisation that leaves this scanning nothing would pass
  # vacuously, so require the inventory to be non-empty.
  [ "$checked" -gt 0 ] \
    || fail "found no tests/*.sh invoking fm-spawn.sh - this guard is no longer scanning anything"

  [ -z "$unguarded" ] || fail \
    "these tests drive bin/fm-spawn.sh without FM_SPAWN_SKIP_PARLAY, so each run enrolls a real agent with the live parlay relay and leaks the listener:$unguarded"$'\n'"Fix: source tests/lib.sh, or add 'export FM_SPAWN_SKIP_PARLAY=1' near the top."
  pass "all $checked tests/*.sh invoking fm-spawn.sh set FM_SPAWN_SKIP_PARLAY"
}

test_guard_detects_an_unguarded_file() {
  local tmp
  tmp=$(fm_test_tmproot fm-parlay-guard)
  # Quoted heredoc delimiters: these are fixture scripts, so $ROOT must survive
  # as literal text rather than expanding here.
  cat > "$tmp/unguarded.sh" <<'SH'
#!/usr/bin/env bash
set -u
"$ROOT/bin/fm-spawn.sh" demo
SH
  SEEN=""
  ! guarded "$tmp/unguarded.sh" \
    || fail "the detector called an unguarded fm-spawn.sh caller guarded"

  cat > "$tmp/guarded.sh" <<'SH'
#!/usr/bin/env bash
set -u
export FM_SPAWN_SKIP_PARLAY=1
"$ROOT/bin/fm-spawn.sh" demo
SH
  SEEN=""
  guarded "$tmp/guarded.sh" \
    || fail "the detector missed an explicit export FM_SPAWN_SKIP_PARLAY=1"
  pass "the detector distinguishes a guarded caller from an unguarded one"
}

test_library_exports_the_guard
test_every_spawning_test_is_guarded
test_guard_detects_an_unguarded_file
