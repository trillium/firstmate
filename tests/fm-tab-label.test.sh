#!/usr/bin/env bash
# tests/fm-tab-label.test.sh - config/tab-labels display labels for herdr tabs.
#
# Drives the lookup library and the adapter's tab rename (the relaunch path)
# against a stub herdr that records its arguments; no real herdr is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tab-label)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup || true' EXIT

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/fm-tab-label-lib.sh
. "$ROOT/bin/fm-tab-label-lib.sh"

CFG=$TMP_ROOT/tab-labels
printf '# comment\n\nmacbook-ops   💎🧭 macbook ops  \nother\t⚓ other\nbare\n' > "$CFG"

assert_equals "$(fm_tab_label_lookup "$CFG" macbook-ops)" "💎🧭 macbook ops" "label keeps inner spaces and emoji, trims edges"
assert_equals "$(fm_tab_label_lookup "$CFG" other)" "⚓ other" "tab separator works"
assert_equals "$(fm_tab_label_lookup "$CFG" bare)" "" "id with no label falls back"
assert_equals "$(fm_tab_label_lookup "$CFG" unlisted)" "" "unlisted id falls back"
assert_equals "$(fm_tab_label_lookup "$TMP_ROOT/missing" macbook-ops)" "" "absent file falls back"

# Relaunch of an adopted tab renames it by id through the herdr adapter.
STUB=$TMP_ROOT/herdr
LOG=$TMP_ROOT/herdr.log
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
EOS
chmod +x "$STUB"
(
  export FM_BACKEND_HERDR_BIN=$STUB PATH="$TMP_ROOT:$PATH"
  # shellcheck source=bin/backends/herdr.sh
  . "$ROOT/bin/backends/herdr.sh"
  fm_backend_herdr_tab_rename default t-9 "$(fm_tab_label_lookup "$CFG" macbook-ops)"
)
assert_contains "$(cat "$LOG")" "tab rename t-9 💎🧭 macbook ops" "relaunch renames the adopted tab to the configured label"
pass "tab labels"
