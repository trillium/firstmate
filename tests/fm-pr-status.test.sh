#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-status.sh"
tmp=$(fm_test_tmproot fm-pr-status)
trap 'rm -rf -- "$tmp"' EXIT
home="$tmp/home"; root="$tmp/root"; fake="$tmp/fake"
mkdir -p "$home/state" "$root" "$fake"
git init -q "$root"
git -C "$root" remote add origin https://github.com/me/fork.git
git -C "$root" remote add upstream https://github.com/upstream/project.git
git -C "$root" config remote.upstream.gh-resolved base
cat > "$fake/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api user --jq .login') echo me ;;
  *'pr list --repo me/fork'*) echo '[{"number":1,"title":"Fork PR","url":"https://github.com/me/fork/pull/1","updatedAt":"2026-11-06T00:00:00Z","createdAt":"2026-10-20T00:00:00Z","mergeStateStatus":"CLEAN","isDraft":true,"author":{"login":"me"}}]' ;;
  *'pr list --repo upstream/project'*) echo 'gh unavailable' >&2; exit 1 ;;
  *'issues/1/comments?'*) echo '[{"user":{"login":"maintainer"},"created_at":"2026-11-01T00:00:00Z"}]' ;;
  *'pr view https://github.com/upstream/project/pull/8'*) echo '{"state":"MERGED","mergedAt":"2026-10-01T00:00:00Z","isDraft":false,"createdAt":"2026-09-01T00:00:00Z"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$fake/gh"
printf 'pr=https://github.com/upstream/project/pull/8\n' > "$home/state/task-closed.meta"
out=$(PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$SCRIPT" --json) || fail "status command failed"
echo "$out" | jq -e '(.schema == "fm-pr-status.v1") and (.prs[0].task == null) and (.prs[0].last_non_operator_comment.author == "maintainer") and (.flags | length == 2)' >/dev/null || fail "missing PR details or flags"
echo "$out" | jq -e '.errors[0].repo == "upstream/project"' >/dev/null || fail "one repository failure did not continue"
pass "fm-pr-status reports PRs, stale drafts, linked closed tasks, and isolated repository failures"

# TOON-shaped output (what gh-axi emits) must be an error, never parsed as rows.
cat > "$fake/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api user --jq .login') echo me ;;
  *'pr list --repo'*) printf 'prs[1]{number,title}:\n  1,Fork PR\n' ;;
  *'pr view'*) printf 'state: MERGED\n' ;;
  *) exit 2 ;;
esac
SH
out=$(PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$SCRIPT" --json) || fail "toon case should still exit 0"
echo "$out" | jq -e '(.prs | length == 0) and (.errors | length == 2) and (.errors[0].message | test("invalid PR list JSON")) and (.flags | length == 0)' >/dev/null || fail "TOON output was not reported as an error"
pass "fm-pr-status reports non-JSON (TOON) output as an error instead of rows"
