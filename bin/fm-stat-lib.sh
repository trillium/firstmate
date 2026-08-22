#!/usr/bin/env bash
# fm-stat-lib.sh - ONE owner for "which dialect does THIS host's `stat` speak?".
#
# `stat` has two incompatible flavors and firstmate runs on both:
#   BSD/macOS  stat -f <fmt> <path>   %m mtime, %z size, %Lp mode, %l links, %i inode, %d device
#   GNU        stat -c <fmt> <path>   %Y mtime, %s size, %a  mode, %h links, %i inode, %d device
#
# Two ways of choosing between them are BOTH wrong, and firstmate has been bitten
# by each:
#
#   1. `uname` is the wrong discriminator. A Darwin kernel routinely resolves
#      `stat` to GNU coreutils - nix-darwin, or Homebrew coreutils ahead of
#      /usr/bin on PATH. The kernel says Darwin, the binary speaks GNU, and every
#      `if [ "$(uname)" = Darwin ]` branch picks the flavor the binary does not
#      speak. That is robots-xw8p (remote-job readiness probe) and robots-e8x5
#      (thirteen more call sites).
#
#   2. `stat -f <fmt> ... || stat -c <fmt> ...` is worse, because GNU's `-f` is
#      not "format" - it is --file-system. GNU `stat -f %m <path>` treats %m as an
#      extra operand, stats the FILESYSTEM of <path>, EXITS 0, and prints a
#      multi-line filesystem dump. The `||` never fires, so the correct call never
#      runs and the caller gets an apfs/ext4 dump where it expected an integer.
#      Under `set -u` arithmetic on that garbage can kill a loop mid-cycle
#      (see the comment this replaces in fm-watch.sh).
#
# So: FEATURE-DETECT the binary, once per process, and dispatch. The probe is
# ordering-safe in the one direction that matters - `stat -c` on BSD is an
# unknown option (usage error on stderr, nothing on stdout, non-zero), while
# `stat -f` on GNU succeeds with junk. Probing `-c` FIRST therefore cannot be
# fooled by either flavor.
#
# The dialect is cached in _FM_STAT_DIALECT after the first probe, and the cache
# only travels DOWNWARD. The accessors below print their result, so a call site
# writing `x=$(fm_stat_mtime "$p")` runs the probe inside a command-substitution
# subshell that is discarded on exit - but a subshell INHERITS the variable, so a
# caller that has already resolved in its own shell hands the answer down for
# free. Unresolved, every call costs a probe plus the real `stat`: two forks on
# GNU, three on BSD (where the `-c` probe is rejected first), against one for the
# hand-rolled form this replaces.
#
# That per-call surcharge is invisible in one-shot scripts and NOT invisible in a
# poll loop. Callers that stat on every tick therefore call fm_stat_warm once
# before the loop, which collapses the whole loop back to one `stat` per tick.
# Measured on a poll of 5 reads: 15 stat invocations cold, 7 warmed.
#
# Warming is deliberately the CALLER's job rather than something this file does
# at source time, because several callers build a constrained PATH after sourcing
# (see the operator-PATH tests) and a probe taken too early would cache the
# dialect of a `stat` that the loop will never actually run. Warm where PATH is
# settled.
#
# No side effects on source. set -u / set -e safe. Leaf lib: depends on nothing.
#
# Tunables (env):
#   FM_STAT_DIALECT_OVERRIDE   force 'gnu' or 'bsd' (tests); skips the probe

# _fm_stat_resolve_dialect: sets _FM_STAT_RESOLVED to 'gnu' or 'bsd' IN THE
# CALLER'S SHELL; non-zero when neither probe answers.
#
# This exists separately from fm_stat_dialect because the cache only works if
# the probe runs in the shell that owns _FM_STAT_DIALECT. Resolving through
# `dialect=$(fm_stat_dialect)` puts the assignment inside a command-substitution
# subshell, which discards it on exit - so every call re-probed and the hot
# callers below paid three forks instead of one. That is exactly the cost the
# cache is here to avoid.
_fm_stat_resolve_dialect() {
  if [ -n "${FM_STAT_DIALECT_OVERRIDE:-}" ]; then
    # The override deliberately does NOT populate the cache: a test may set it,
    # clear it, and expect the real binary to be probed afterwards.
    case "$FM_STAT_DIALECT_OVERRIDE" in
      gnu|bsd) _FM_STAT_RESOLVED=$FM_STAT_DIALECT_OVERRIDE; return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [ -z "${_FM_STAT_DIALECT:-}" ]; then
    local probe
    # `/` is guaranteed to exist and to have an integer size under both flavors,
    # so a bare-integer result is a positive identification of the dialect and
    # anything else (empty, usage text, a filesystem dump) is a rejection.
    probe=$(stat -c %s / 2>/dev/null)
    case "$probe" in
      ''|*[!0-9]*)
        probe=$(stat -f %z / 2>/dev/null)
        case "$probe" in
          # Answer nothing rather than caching a negative. A probe can fail for
          # reasons that are not permanent - a fixture PATH with no `stat` yet, a
          # constrained PATH still being assembled - and a cached 'unknown' would
          # make that momentary gap permanent for the rest of the process.
          ''|*[!0-9]*) return 1 ;;
          *) _FM_STAT_DIALECT=bsd ;;
        esac
        ;;
      *) _FM_STAT_DIALECT=gnu ;;
    esac
  fi
  _FM_STAT_RESOLVED=$_FM_STAT_DIALECT
}

# fm_stat_warm: resolve the dialect into THIS shell so the accessors below stop
# re-probing. Returns 0 even when the probe fails - warming is an optimization,
# and a caller that cannot stat should find that out from the accessor that
# actually needs a value, not from a hint it made on the way past.
fm_stat_warm() {
  _fm_stat_resolve_dialect >/dev/null 2>&1 || true
  return 0
}

# fm_stat_dialect: prints 'gnu' or 'bsd'; non-zero when neither probe answers.
fm_stat_dialect() {
  _fm_stat_resolve_dialect || return 1
  printf '%s\n' "$_FM_STAT_RESOLVED"
}

# fm_stat_fmt <gnu-fmt> <bsd-fmt> <path>: print the formatted field, else fail.
# The two format strings are the SAME field expressed in each dialect; callers
# below name the field so no call site has to remember the letter pairs.
fm_stat_fmt() {
  local gnu_fmt=$1 bsd_fmt=$2 path=$3 out
  # Resolve WITHOUT a command substitution so the cache survives - see
  # _fm_stat_resolve_dialect.
  _fm_stat_resolve_dialect || return 1
  case "$_FM_STAT_RESOLVED" in
    gnu) out=$(LC_ALL=C stat -c "$gnu_fmt" "$path" 2>/dev/null) || return 1 ;;
    bsd) out=$(LC_ALL=C stat -f "$bsd_fmt" "$path" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _fm_stat_uint <gnu-fmt> <bsd-fmt> <path>: as fm_stat_fmt, but the result must
# be a bare unsigned integer. This is the belt to fm_stat_dialect's braces: if a
# host ever ships a third flavor that the probe misreads, a caller doing
# arithmetic gets a clean failure instead of a stray token.
_fm_stat_uint() {
  local out
  out=$(fm_stat_fmt "$1" "$2" "$3") || return 1
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

fm_stat_mtime()  { _fm_stat_uint %Y  %m  "$1"; }  # mtime, epoch seconds
fm_stat_ctime()  { _fm_stat_uint %Z  %c  "$1"; }  # inode change time, epoch seconds
fm_stat_size()   { _fm_stat_uint %s  %z  "$1"; }  # size in bytes
fm_stat_mode()   { _fm_stat_uint %a  %Lp "$1"; }  # permission bits, octal
fm_stat_device() { _fm_stat_uint %d  %d  "$1"; }  # device number
fm_stat_inode()  { _fm_stat_uint %i  %i  "$1"; }  # inode number
fm_stat_links()  { _fm_stat_uint %h  %l  "$1"; }  # hard link count
fm_stat_uid()    { _fm_stat_uint %u  %u  "$1"; }  # owning user id

# fm_stat_identity <path>: "device:inode" - the rotation/recreation check.
fm_stat_identity() { fm_stat_fmt '%d:%i' '%d:%i' "$1"; }

# fm_stat_signature <path>: "size:mtime" change signature. BSD %Fm is the
# fractional-second mtime; the GNU side stays whole-second %Y, matching the
# pairing every caller already used - a signature only has to differ when the
# file changes, it does not have to mean the same thing across hosts.
fm_stat_signature() { fm_stat_fmt '%s:%Y' '%z:%Fm' "$1"; }

# fm_stat_fingerprint <path>: "device:inode:size:mtime:ctime".
fm_stat_fingerprint() { fm_stat_fmt '%d:%i:%s:%Y:%Z' '%d:%i:%z:%m:%c' "$1"; }
