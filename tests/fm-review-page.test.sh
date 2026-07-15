#!/usr/bin/env bash
# Behavior tests for bin/fm-review-page.ts — the tool that gives every review-
# store item a visitable Pulse page.
#
# Hermetic and network-free. The `review` CLI is stubbed with a bash fake on a
# fakebin PATH (FM_REVIEW_BIN points at it) whose read verbs emit canned JSON and
# whose write verbs (update/note) append to a call log so wire-back is asserted
# without ever touching the real store. Pages are written to a throwaway
# FM_REVIEW_PAGE_OUT temp dir. Cases pin every branch that matters:
#   (a) single-id render      -> a page file + a printed URL
#   (b) --all sweep over N     -> N pages + an index listing all N
#   (c) idempotent re-render   -> no duplicate dirs, note skipped when url unchanged
#   (d) artifact links         -> url / brain id / branch rendered on the page
#   (e) markdown body          -> heading, bold, list, fenced code all rendered
#   (f) wire-back              -> page_url metadata set + Page: note on first render
#   (g) empty --all queue      -> an accurate empty index, exit 0
#   (h) unknown id             -> warning + non-zero, no page
#   (i) no args                -> usage error, exit 2
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-review-page.ts"
BASE_URL="http://localhost:31337/review"

# Locate a bun runtime; skip (do not fail) if the host has none, matching the
# repo's tolerance for missing optional toolchains in unit runs.
if ! command -v bun >/dev/null 2>&1; then
  echo "ok - fm-review-page: SKIP (bun not installed)"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-review-page)

# ---------------------------------------------------------------------------
# install_fake_review <fakebin-dir> <items-json-file> <call-log>
#
# Writes a `review` stub into <fakebin-dir> that:
#   - for `list`/`show`, prints the contents of <items-json-file> verbatim
#     (a JSON array of records), so both fetch paths are exercised.
#   - for `update`/`note`, appends the full argv to <call-log> so wire-back
#     calls are asserted.
# ---------------------------------------------------------------------------
install_fake_review() {
  local dir=$1 items=$2 log=$3
  mkdir -p "$dir"
  cat > "$dir/review" <<SH
#!/usr/bin/env bash
case "\$1" in
  list|show) cat "$items" ;;
  update|note) printf '%s\n' "\$*" >> "$log" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/review"
}

# A canned two-item open queue. Item one carries rich markdown + artifacts; item
# two is minimal. No page_url in metadata, so the first render must note.
write_items_json() {
  local file=$1
  cat > "$file" <<'JSON'
[
  {
    "id": "review-aaa",
    "title": "Merge the bridge",
    "description": "## What\nMerge **the bridge** now.\n\n- first point\n- second point\n\n```bash\necho run\n```\n\nSee https://github.com/foo/bar/pull/7 and brain-k0zr4 on branch feat/nightshift-bridge.\n\n## Stakes\nLOW, bounded by design.",
    "status": "open",
    "priority": 1,
    "issue_type": "task",
    "owner": "trillium@x.com",
    "created_at": "2026-07-12T07:47:19Z",
    "updated_at": "2026-07-15T07:47:19Z",
    "metadata": { "brain_slug": "merge-the-bridge" }
  },
  {
    "id": "review-bbb",
    "title": "Enable the groomer",
    "description": "A short body with no special markup.",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "trillium@x.com",
    "created_at": "2026-07-14T09:53:53Z",
    "updated_at": "2026-07-15T09:53:54Z",
    "metadata": {}
  }
]
JSON
}

# run_tool <fakebin> <out> <items> <log> <args...>  -> captures stdout in $OUTPUT
run_tool() {
  local fakebin=$1 out=$2 items=$3 log=$4
  shift 4
  OUTPUT=$(
    FM_REVIEW_BIN="$fakebin/review" \
    FM_REVIEW_PAGE_OUT="$out" \
    FM_REVIEW_PAGE_BASE_URL="$BASE_URL" \
      bun "$TOOL" "$@" 2>&1
  )
  RC=$?
}

# ===========================================================================
# (b)+(e)+(f) --all sweep over N items renders N pages + index, with markdown
# and wire-back.
# ===========================================================================
t_all_sweep() {
  local case_dir="$TMP_ROOT/all"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  write_items_json "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  expect_code 0 "$RC" "all: exit 0"

  # N pages exist.
  assert_present "$out/review-aaa/index.html" "all: page for review-aaa written"
  assert_present "$out/review-bbb/index.html" "all: page for review-bbb written"
  assert_present "$out/index.html" "all: index written"

  # index lists both items with links to their pages.
  assert_grep 'href="./review-aaa/"' "$out/index.html" "all: index links review-aaa"
  assert_grep 'href="./review-bbb/"' "$out/index.html" "all: index links review-bbb"
  assert_grep '2 items' "$out/index.html" "all: index reports item count"

  # markdown rendered on item one (e).
  local page="$out/review-aaa/index.html"
  assert_grep '<strong>the bridge</strong>' "$page" "md: bold rendered"
  assert_grep '<li>first point</li>' "$page" "md: list rendered"
  assert_grep 'class="codeblock"' "$page" "md: fenced code rendered"
  assert_grep '<h2>What</h2>' "$page" "md: heading rendered"

  # printed URLs (b).
  assert_contains "$OUTPUT" "$BASE_URL/review-aaa/" "all: printed review-aaa url"
  assert_contains "$OUTPUT" "$BASE_URL/review-bbb/" "all: printed review-bbb url"
  assert_contains "$OUTPUT" "index: $BASE_URL/" "all: printed index url"

  # wire-back (f): metadata set + note for BOTH items (no prior page_url).
  assert_grep "update review-aaa --set-metadata page_url=$BASE_URL/review-aaa/" "$log" "wire: aaa metadata set"
  assert_grep "note review-aaa Page: $BASE_URL/review-aaa/" "$log" "wire: aaa noted"
  assert_grep "update review-bbb --set-metadata page_url=$BASE_URL/review-bbb/" "$log" "wire: bbb metadata set"

  pass "fm-review-page: --all sweep renders N pages + index with markdown + wire-back"
}

# ===========================================================================
# (d) artifact links: url is clickable, brain id + branch are shown.
# ===========================================================================
t_artifacts() {
  local case_dir="$TMP_ROOT/artifacts"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  write_items_json "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  local page="$out/review-aaa/index.html"

  assert_grep 'https://github.com/foo/bar/pull/7' "$page" "artifact: url present"
  assert_grep '<a href="https://github.com/foo/bar/pull/7"' "$page" "artifact: url is a link"
  assert_grep 'brain-k0zr4' "$page" "artifact: brain id present"
  assert_grep 'feat/nightshift-bridge' "$page" "artifact: branch present"

  pass "fm-review-page: artifact links (url/brain/branch) render on the page"
}

# ===========================================================================
# (j) REGRESSION: a code-span-heavy body must render every `code` span and leak
# NO placeholder marker. A prior implementation used a text placeholder that
# corrupted into NUL bytes and leaked bare "CODE0" tokens into rendered pages.
# This pins the split-based renderer against that whole class of leak.
# ===========================================================================
t_codespan_no_leak() {
  local case_dir="$TMP_ROOT/codespan"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  # A single item whose body is dense with adjacent code spans, em-dashes, and a
  # multi-span list line — the exact shape that leaked before.
  cat > "$items" <<'JSON'
[{"id":"review-code","title":"Code heavy","description":"A generator for firstmate — `bin/fm-groom.sh` — that grooms the `ideas` store.\n\n- Branch `feat/fm-groom` (4 files: `bin/fm-groom.sh`, `bin/fm-groom-lib.sh`, `bin/fm-groom-json-field.sh`, `tests/fm-groom.test.sh`).\n- Full write-up: brain doc `brain-m8bxn`.\n\nRails: OFF by default (dry-run unless `FM_GROOM_ENABLED=1`); rate-limited (`FM_GROOM_MAX_IN_FLIGHT`, default 2).","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  expect_code 0 "$RC" "codespan: exit 0"

  local page="$out/review-code/index.html"
  # NO placeholder leak of any kind.
  assert_no_grep "CODE0" "$page" "codespan: no CODE0 placeholder leak"
  assert_no_grep "CODE1" "$page" "codespan: no CODE1 placeholder leak"
  # Every code span actually rendered as <code>.
  assert_grep "<code>bin/fm-groom.sh</code>" "$page" "codespan: first span rendered"
  assert_grep "<code>ideas</code>" "$page" "codespan: adjacent span rendered"
  assert_grep "<code>feat/fm-groom</code>" "$page" "codespan: list-line span rendered"
  assert_grep "<code>FM_GROOM_ENABLED=1</code>" "$page" "codespan: parenthesized span rendered"
  assert_grep "<code>brain-m8bxn</code>" "$page" "codespan: doc-id span rendered"

  pass "fm-review-page: code-span-heavy body renders every span with no placeholder leak"
}

# ===========================================================================
# (a) single-id render produces a page + printed URL.
# ===========================================================================
t_single() {
  local case_dir="$TMP_ROOT/single"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  # show returns just the one requested item.
  cat > "$items" <<'JSON'
[{"id":"review-aaa","title":"Just one","description":"solo body","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-aaa
  expect_code 0 "$RC" "single: exit 0"
  assert_present "$out/review-aaa/index.html" "single: page written"
  assert_contains "$OUTPUT" "$BASE_URL/review-aaa/" "single: printed url"
  # even a single-id render refreshes the index.
  assert_present "$out/index.html" "single: index refreshed"

  pass "fm-review-page: single-id render produces a page file + URL"
}

# ===========================================================================
# (c) idempotent re-render: no duplicate dirs; note skipped when url unchanged.
# ===========================================================================
t_idempotent() {
  local case_dir="$TMP_ROOT/idem"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  # metadata already carries the exact page_url the tool would compute.
  cat > "$items" <<JSON
[{"id":"review-aaa","title":"Already wired","description":"body","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{"page_url":"$BASE_URL/review-aaa/"}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  run_tool "$fakebin" "$out" "$items" "$log" --all
  expect_code 0 "$RC" "idem: second run exit 0"

  # exactly one item dir, no duplicates from two runs.
  local dir_count
  dir_count=$(find "$out" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dir_count" = "1" ] || fail "idem: expected 1 item dir, got $dir_count"

  # note was NEVER emitted (url matched existing metadata on every run).
  assert_no_grep "note review-aaa" "$log" "idem: note skipped when url unchanged"
  # metadata set is still emitted (idempotent set is safe).
  assert_grep "update review-aaa --set-metadata page_url=$BASE_URL/review-aaa/" "$log" "idem: metadata still set"

  pass "fm-review-page: idempotent re-render (no dupes, note skipped on unchanged url)"
}

# ===========================================================================
# (g) --all over an empty queue writes an accurate empty index, exit 0.
# ===========================================================================
t_empty() {
  local case_dir="$TMP_ROOT/empty"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  printf '[]\n' > "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  expect_code 0 "$RC" "empty: exit 0"
  assert_present "$out/index.html" "empty: index written"
  assert_grep 'review queue is clear' "$out/index.html" "empty: index shows clear-queue message"
  assert_absent "$log" "empty: no wire-back calls for empty queue"

  pass "fm-review-page: empty --all queue writes an accurate empty index"
}

# ===========================================================================
# (h) unknown id -> warning + non-zero exit, no page.
# ===========================================================================
t_unknown_id() {
  local case_dir="$TMP_ROOT/unknown"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  # show returns nothing for the requested id.
  printf '[]\n' > "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-missing
  [ "$RC" -ne 0 ] || fail "unknown: expected non-zero exit, got 0"
  assert_contains "$OUTPUT" "not found: review-missing" "unknown: warns about missing id"
  assert_absent "$out/review-missing/index.html" "unknown: no page for missing id"

  pass "fm-review-page: unknown id warns and exits non-zero"
}

# ===========================================================================
# (i) no args -> usage error, exit 2.
# ===========================================================================
t_no_args() {
  local case_dir="$TMP_ROOT/noargs"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  printf '[]\n' > "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log"
  expect_code 2 "$RC" "noargs: exit 2"
  assert_contains "$OUTPUT" "pass one or more item ids" "noargs: usage error printed"

  pass "fm-review-page: no args is a usage error (exit 2)"
}

# ===========================================================================
# (o) SINGLE TOP BAR: the page opts out of Pulse portal shell injection
# (<meta name="pulse-shell" content="off">) and renders exactly one top bar of
# its own — no second injected global nav. Regression for the double-nav-bar bug
# where portal's injectShell stacked /_pulse/nav.js on top of this page's
# .topbar. Both the item page and the index opt out.
# ===========================================================================
t_single_topbar() {
  local case_dir="$TMP_ROOT/topbar"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  write_items_json "$items"
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" --all
  expect_code 0 "$RC" "topbar: exit 0"
  local page="$out/review-aaa/index.html"

  # Opt-out meta present on item page AND index.
  assert_grep 'name="pulse-shell" content="off"' "$page" "topbar: item page opts out of shell injection"
  assert_grep 'name="pulse-shell" content="off"' "$out/index.html" "topbar: index opts out of shell injection"
  # The page never emits the injected shell scripts itself (no manual double).
  assert_no_grep '/_pulse/nav.js' "$page" "topbar: no injected nav.js in the page"
  assert_no_grep '/annotate/pulse-agent.js' "$page" "topbar: no chat-panel script in the page"
  # Exactly one top bar (its own .topbar), rendered once.
  local topbars
  topbars=$(grep -c 'class="topbar"' "$page")
  [ "$topbars" = "1" ] || fail "topbar: expected exactly 1 .topbar, got $topbars"

  pass "fm-review-page: opts out of shell injection and renders exactly one top bar"
}

# ===========================================================================
# (k) DECISION PANEL: every rendered item carries an interactive decision panel
# with Approve/Decline/Comment controls that POST to /api/review/decision, and
# the item id is embedded for the same-origin fetch.
# ===========================================================================
t_decision_panel() {
  local case_dir="$TMP_ROOT/panel"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  cat > "$items" <<'JSON'
[{"id":"review-znt","title":"Merge the bridge","description":"## What\nMerge it.\n\n## Stakes\nLOW.","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-znt
  expect_code 0 "$RC" "panel: exit 0"
  local page="$out/review-znt/index.html"

  assert_grep 'class="decision"' "$page" "panel: decision panel present"
  assert_grep 'data-verdict="approve"' "$page" "panel: approve button present"
  assert_grep 'data-verdict="decline"' "$page" "panel: decline button present"
  assert_grep 'data-verdict="comment"' "$page" "panel: comment button present"
  assert_grep '<textarea' "$page" "panel: comment textarea present"
  assert_grep "/api/review/decision" "$page" "panel: posts to the decision endpoint"
  # id embedded for the fetch payload (JSON-encoded).
  assert_grep 'data-review-id' "$page" "panel: item id embedded for fetch"
  assert_grep 'review-znt' "$page" "panel: item id value present"

  pass "fm-review-page: every item renders an interactive decision panel"
}

# ===========================================================================
# (l) STRUCTURED BREAKDOWN: What/Why/Stakes/Recommendation/Artifact fields are
# parsed from the body and rendered as a skimmable context block, not just a
# flat body dump.
# ===========================================================================
t_context_breakdown() {
  local case_dir="$TMP_ROOT/context"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  cat > "$items" <<'JSON'
[{"id":"review-ctx","title":"Bridge decision","description":"## What\nMerge the NightShift bridge.\n\n## Why\nIt unblocks the auto-dole queue.\n\n## Stakes\nTouches the live inference DB.\n\n## Recommendation\nMerge after a dry run.\n\nARTIFACT: branch feat/nightshift-tasks-bridge; brain-k0zr4.","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-ctx
  local page="$out/review-ctx/index.html"

  assert_grep 'class="context"' "$page" "context: structured block present"
  assert_grep '>What<' "$page" "context: What field labelled"
  assert_grep '>Why<' "$page" "context: Why field labelled"
  assert_grep '>Stakes<' "$page" "context: Stakes field labelled"
  assert_grep '>Recommendation<' "$page" "context: Recommendation field labelled"
  assert_grep '>Artifact<' "$page" "context: Artifact field labelled"
  assert_grep 'It unblocks the auto-dole queue.' "$page" "context: Why prose rendered"
  assert_grep 'Merge after a dry run.' "$page" "context: Recommendation prose rendered"

  pass "fm-review-page: body parsed into a What/Why/Stakes/Recommendation/Artifact breakdown"
}

# ===========================================================================
# (m) RECORDED DECISION: a Captain decision already in the item's notes renders
# as a standing-decision banner (so the page reflects that a decision landed).
# ===========================================================================
t_recorded_decision() {
  local case_dir="$TMP_ROOT/recorded"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  cat > "$items" <<'JSON'
[{"id":"review-done","title":"Already decided","description":"body","notes":"Page: http://x/\nCaptain decision: approve - ship it after dry run @ 2026-07-15T10:00:00Z","status":"open","priority":1,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-15T10:00:00Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-done
  local page="$out/review-done/index.html"

  assert_grep 'Standing decision:' "$page" "recorded: standing-decision banner present"
  assert_grep '>approve<' "$page" "recorded: verdict shown"
  assert_grep 'ship it after dry run' "$page" "recorded: recorded comment shown"

  pass "fm-review-page: an already-recorded decision renders as a standing-decision banner"
}

# ===========================================================================
# (n) NO CONTEXT FIELDS: a plain body with none of the labelled sections still
# renders (falls back to the flat body) — the context block is simply absent.
# ===========================================================================
t_no_context_fields() {
  local case_dir="$TMP_ROOT/nocontext"
  local fakebin="$case_dir/bin" out="$case_dir/out"
  local items="$case_dir/items.json" log="$case_dir/calls.log"
  mkdir -p "$case_dir"
  cat > "$items" <<'JSON'
[{"id":"review-flat","title":"Flat body","description":"Just a plain paragraph with no labelled sections at all.","status":"open","priority":2,"created_at":"2026-07-14T07:47:19Z","updated_at":"2026-07-14T07:47:19Z","metadata":{}}]
JSON
  install_fake_review "$fakebin" "$items" "$log"

  run_tool "$fakebin" "$out" "$items" "$log" review-flat
  expect_code 0 "$RC" "nocontext: exit 0"
  local page="$out/review-flat/index.html"
  # Panel still present (always), body still rendered, context block absent.
  assert_grep 'class="decision"' "$page" "nocontext: decision panel still present"
  assert_grep 'Just a plain paragraph' "$page" "nocontext: flat body still rendered"
  assert_no_grep 'class="context"' "$page" "nocontext: no empty context block"

  pass "fm-review-page: a body with no labelled sections renders flat (panel still present)"
}

t_all_sweep
t_artifacts
t_codespan_no_leak
t_single
t_idempotent
t_empty
t_unknown_id
t_no_args
t_decision_panel
t_context_breakdown
t_recorded_decision
t_no_context_fields
t_single_topbar
