#!/usr/bin/env bash
# fm-tab-label-lib.sh - optional captain-private display labels for herdr tabs.
#
# config/tab-labels maps a task id (for a secondmate, its registered id) to the
# tab name firstmate applies at launch and relaunch in place of `fm-<id>`.
# One entry per line: `<id> <label...>`; blank lines and `#` comments are
# ignored and the label is everything after the first run of blanks.
# An absent file, an unlisted id, or an unreadable file means no label, so the
# caller keeps the default `fm-<id>`.

# fm_tab_label_lookup <config-file> <id>: print the configured label, or nothing.
fm_tab_label_lookup() {
  local file=$1 id=$2 key label
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%[[:blank:]]*}
    [ "$key" = "$id" ] || continue
    label=${line#"$key"}
    label=${label#"${label%%[![:blank:]]*}"}
    label=${label%"${label##*[![:blank:]]}"}
    [ -n "$label" ] && { printf '%s\n' "$label"; return 0; }
  done < "$file"
  return 0
}

# fm_tab_label_apply_remote <fm-on-script> <config-dir> <id>: rename a remote
# secondmate's confirmed herdr tab to its label from THIS home's config/tab-labels
# (the remote host's own home has none). No label means no call; a failed rename
# only warns, because the tab name is display-only and the launch already stands.
fm_tab_label_apply_remote() {
  local fm_on=$1 config=$2 id=$3 label
  label=$(fm_tab_label_lookup "$config/tab-labels" "$id")
  [ -n "$label" ] || return 0
  "$fm_on" "$id" fm-remote-secondmate-control.sh tab-rename "$id" "$label" </dev/null >/dev/null 2>&1 \
    || echo "warning: could not apply tab label '$label' to remote secondmate $id's herdr tab" >&2
  return 0
}
