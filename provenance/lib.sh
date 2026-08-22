#!/usr/bin/env bash
# provenance/lib.sh - shared helpers for the fork-feature provenance guard.
#
# This file is fork-owned material living under the provenance/ namespace that
# upstream firstmate never writes, so upstream merges cannot collide with it.
# check.sh sources it; portable tests source it directly.
#
# Three helpers live here, each with one job:
#   scrub_volatile          - normalize nondeterministic tokens out of captured
#                             output so golden-master snapshots are stable in CI.
#   provenance_fingerprint  - the anchor drift signature. PLACEHOLDER today (see
#                             below); the SINGLE swap point for tree-sitter-bash.
#   provenance_locate_symbol- extract a named bash function's region from a file,
#                             so an anchor addresses code structurally, not by
#                             line number.
# A small TOML reader (provenance_parse_register) rounds it out.
#
# See provenance/README.md for the format, the guarantee, and the deferred plan.

# ---------------------------------------------------------------------------
# scrub_volatile: stdin -> stdout, replacing volatile tokens with placeholders.
#
# firstmate output is full of nondeterministic tokens - absolute paths under a
# throwaway FM_HOME, tmpdirs, timestamps, PIDs, long hex/window ids. A raw
# snapshot of any of that is guaranteed-flaky in CI. This pass replaces each
# volatile class with a stable placeholder BEFORE the diff, exactly the
# "scrubber" idea the approval-testing research called the single most important
# feature to copy.
#
# Uses `sed -E` (extended regex), portable across macOS (BSD) and Linux (GNU).
# FM_PROV_ROOT lets a caller pin the repo root that should collapse to <ROOT>;
# it defaults to the current directory.
scrub_volatile() {
  local root="${FM_PROV_ROOT:-$PWD}"
  sed -E \
    -e "s#${root}#<ROOT>#g" \
    -e "s#${HOME}#<HOME>#g" \
    -e 's#/private/var/folders/[A-Za-z0-9._/+-]+#<TMPDIR>#g' \
    -e 's#/var/folders/[A-Za-z0-9._/+-]+#<TMPDIR>#g' \
    -e 's#/tmp/[A-Za-z0-9._/+-]+#<TMPDIR>#g' \
    -e 's#[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+Z-]+#<TS>#g' \
    -e 's#\b[0-9]{10,}\b#<NUM>#g' \
    -e 's#\b[0-9a-f]{12,}\b#<HEX>#g'
}

# ---------------------------------------------------------------------------
# provenance_fingerprint: stdin -> a short stable hex fingerprint.
#
# ***PLACEHOLDER ALGORITHM - the deliberate one-function swap point.***
#
# The research (data/prov-research) recommends the anchor signature be a
# normalized tree-sitter-bash AST fingerprint (node kinds + token text, with
# whitespace/position/comments stripped), so reformatting and edits ELSEWHERE in
# the file do not trip the alarm. tree-sitter-bash is not wired into this POC
# (no `tree-sitter` binary present), so this is a clearly-labeled placeholder:
# strip comments + blank lines, collapse whitespace, then hash.
#
# Known limitation of the placeholder: it strips '#' naively, so a '#' inside a
# string literal is also removed, and pure reformatting that changes tokenization
# can shift the hash. That is acceptable for a POC because drift is a WARN, not a
# FAIL. Swapping to a real tree-sitter-bash normalized-AST fingerprint is a change
# to THIS FUNCTION ALONE - nothing else in check.sh or the register format moves.
provenance_fingerprint() {
  sed -e 's/#.*$//' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +//; s/ +$//' \
    | shasum -a 256 \
    | awk '{print substr($1, 1, 16)}'
}

# ---------------------------------------------------------------------------
# provenance_locate_symbol <file> <symbol>: print the named bash function's
# region (definition line through its closing brace) to stdout. Exit nonzero if
# the function is not found - that vanish is the deletion tripwire.
#
# Addresses the region STRUCTURALLY by function name, so the anchor survives the
# function moving within the file (the brittleness that kills line-range anchors).
# Relies on this repo's consistent style: top-level functions are defined at
# column 0 as `name() {` and close with `}` at column 0.
provenance_locate_symbol() {
  local file=$1 symbol=$2
  awk -v fn="$symbol" '
    BEGIN { infn = 0; found = 0 }
    !infn && $0 ~ "^" fn "[[:space:]]*\\([[:space:]]*\\)[[:space:]]*\\{" {
      infn = 1; found = 1; print; next
    }
    infn {
      print
      if ($0 ~ /^\}/) { infn = 0 }
    }
    END { if (!found) exit 3 }
  ' "$file"
}

# ---------------------------------------------------------------------------
# provenance_parse_register <register.toml>: emit a flat TSV stream the shell can
# consume without a TOML library. This reader understands only the controlled
# subset this POC's register uses: `[[feature]]` tables, `[[feature.anchor]]`
# subtables, and `key = "value"` string pairs. It is deliberately small; a real
# scale-up would use a proper TOML parser (see README "Deferred").
#
# Output records (tab-separated):
#   FEATURE <id>
#   STORY   <story>
#   TEST    <command>
#   ANCHOR  <index> <path> <sig> <symbol>
# Anchors are indexed per-feature starting at 0. The optional <symbol> is emitted
# LAST because it may be empty: with tab as an IFS-whitespace delimiter, `read`
# collapses adjacent tabs, so an empty field is only safe as the trailing one.
provenance_parse_register() {
  awk '
    function trim(s)  { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unq(s)   { s = trim(s); sub(/^"/, "", s); sub(/"$/, "", s); return s }
    function flush() {
      if (in_anchor) {
        print "ANCHOR\t" anchor_no "\t" a_path "\t" a_sig "\t" a_symbol
        in_anchor = 0
      }
    }
    /^[ \t]*#/ { next }
    /^[ \t]*\[\[feature\]\]/        { flush(); anchor_no = -1; next }
    /^[ \t]*\[\[feature\.anchor\]\]/ {
      flush(); anchor_no++; in_anchor = 1; a_path = ""; a_symbol = ""; a_sig = ""; next
    }
    {
      eq = index($0, "=")
      if (eq <= 0) next
      key = trim(substr($0, 1, eq - 1))
      if (key !~ /^[A-Za-z_]+$/) next
      val = unq(substr($0, eq + 1))
      if (in_anchor) {
        if (key == "path")        a_path = val
        else if (key == "symbol") a_symbol = val
        else if (key == "sig")    a_sig = val
      } else {
        if (key == "id")        print "FEATURE\t" val
        else if (key == "story") print "STORY\t" val
        else if (key == "test")  print "TEST\t" val
      }
    }
    END { flush() }
  ' "$1"
}
