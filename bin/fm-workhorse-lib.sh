# shellcheck shell=bash
# Workhorse queue helpers, sourced by bin/fm-workhorse-{file,ring,claim,close}.sh.
# Usage: . bin/fm-workhorse-lib.sh
#
# This file is the single owner of how the workhorse flow reaches its bead
# store and how a workhorse bead's body is laid out and read back.
#
# STORE PINNING. Every call goes through `task` (the tasks federation CLI)
# with BEADS_DIR exported explicitly to the task store and with the working
# directory moved to that store's parent, so a `.beads` in the caller's cwd or
# a different wrapper resolution can never win. The pinned directory defaults
# to $HOME/data/tasks/.beads; FM_WORKHORSE_BEADS_DIR overrides it for a host
# whose task store lives elsewhere. A pinned directory that does not exist is
# refused rather than silently falling through to another store.
#
# BEAD BODY. The description is a Markdown brief with exactly these `## `
# sections, in this order (fm-workhorse-file.sh writes them; claim and close
# read them back): Captain's intent, Firstmate spec, Out of scope, Definition
# of done, Evidence required, Delivery mode + yolo posture, Answer-to. The
# Evidence section is a list of `- PR link:`, `- Report path:`, and
# `- Command output:` lines; the kinds present are what fm-workhorse-close.sh
# requires. The delivery section carries `mode:`, `yolo:`, and `project:` lines.

FM_WORKHORSE_LABEL=workhorse

fm_workhorse_beads_dir() {
  printf '%s\n' "${FM_WORKHORSE_BEADS_DIR:-${HOME:-}/data/tasks/.beads}"
}

# Fail unless the pinned store exists; prints the refusal and returns 1.
fm_workhorse_store_check() {
  local dir
  dir=$(fm_workhorse_beads_dir)
  case "$dir" in
    /*) ;;
    *) echo "error: the pinned task store must be an absolute path (got '$dir'); set FM_WORKHORSE_BEADS_DIR" >&2; return 1 ;;
  esac
  [ -d "$dir" ] || {
    echo "error: pinned task store $dir does not exist; refusing to fall back to any other beads store (set FM_WORKHORSE_BEADS_DIR if this host keeps it elsewhere)" >&2
    return 1
  }
  command -v task >/dev/null 2>&1 || {
    echo "error: the task store CLI 'task' is not on PATH" >&2
    return 1
  }
}

# Run `task <args>` against the pinned store from the store's own parent dir.
fm_workhorse_task() {
  local dir
  dir=$(fm_workhorse_beads_dir)
  (
    cd "$(dirname "$dir")" || exit 1
    BEADS_DIR="$dir" exec task "$@"
  )
}

# A bead id is a lowercase slug; this rejects anything that could be read as a
# flag or smuggle shell or path text into later commands.
fm_workhorse_valid_bead_id() {  # <id>
  printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$'
}

# Print the bead as one JSON object, refusing when it does not exist, is not in
# the pinned store, or does not carry the workhorse label.
fm_workhorse_bead_json() {  # <bead-id>
  local id=$1 out
  fm_workhorse_valid_bead_id "$id" || {
    echo "error: '$id' is not a valid bead id" >&2
    return 1
  }
  out=$(fm_workhorse_task show "$id" --json 2>/dev/null) || {
    echo "error: bead $id was not found in the pinned task store $(fm_workhorse_beads_dir)" >&2
    return 1
  }
  out=$(printf '%s' "$out" | jq -c 'if type == "array" then .[0] else . end' 2>/dev/null) || out=
  { [ -n "$out" ] && [ "$out" != null ]; } || {
    echo "error: bead $id returned no readable record from the pinned task store" >&2
    return 1
  }
  printf '%s' "$out" | jq -e --arg l "$FM_WORKHORSE_LABEL" --arg id "$id" \
    '.id == $id and ((.labels // []) | index($l)) != null' >/dev/null 2>&1 || {
    echo "error: bead $id does not carry the '$FM_WORKHORSE_LABEL' label" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# Print the body of one `## <heading>` section of a bead description, without
# its leading and trailing blank lines.
fm_workhorse_section() {  # <description-text> <heading>
  printf '%s\n' "$1" | awk -v h="## $2" '
    $0 == h { grab = 1; next }
    grab && /^## / { exit }
    grab { lines[n++] = $0 }
    END {
      s = 0; e = n - 1
      while (s <= e && lines[s] ~ /^[[:space:]]*$/) s++
      while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }
  '
}

# Print the value of `<key>: <value>` inside the delivery section.
fm_workhorse_delivery_field() {  # <description-text> <key>
  fm_workhorse_section "$1" "Delivery mode + yolo posture" \
    | sed -n "s/^$2:[[:space:]]*//p" | head -n1
}

# Print the evidence kinds a body names, one of pr, report, command per line.
fm_workhorse_evidence_kinds() {  # <description-text>
  fm_workhorse_section "$1" "Evidence required" | sed -n \
    -e 's/^- PR link:.*/pr/p' \
    -e 's/^- Report path:.*/report/p' \
    -e 's/^- Command output:.*/command/p'
}
