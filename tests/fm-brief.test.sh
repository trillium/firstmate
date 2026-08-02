#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Fork-contribution PR-target rule: a ship task on a project whose PRs must
# land in the captain's own trillium/<repo> fork, never upstream. Detection
# reads the clone's real git remotes in two shapes - a legacy clone whose
# `origin` is still the upstream repo, or the correct swapped setup where
# `origin` is already the trillium fork with a separate `upstream` remote -
# and the generated rule differs by push mode and clone shape:
#   direct-PR             -> explicit `gh pr create --repo trillium/<repo>` form
#   no-mistakes + swapped  -> confirms origin already targets the fork, forbids `--fork-url`
#   no-mistakes + legacy   -> STOP: no-mistakes cannot be driven safely, escalate
# An ordinary captain-owned project (Trillium origin, no `upstream` remote)
# gets no such rule (byte-identical to pre-rule output), and local-only never
# pushes so it stays exempt even on an upstream origin.
make_clone() {
  local dir=$1 origin=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
}

test_fork_first_push_rule() {
  local home brief
  home="$TMP_ROOT/fork-first-home"
  mkdir -p "$home/data" "$home/projects"
  # local-only fixture project (for the exemption case) needs the registry mode.
  cat > "$home/data/projects.md" <<'EOF'
- upstream-local [local-only] - upstream fork on a local-only project (added 2026-07-01)
EOF
  make_clone "$home/projects/upstream-proj" "https://github.com/kunchenguid/gnhf.git"
  make_clone "$home/projects/upstream-ssh" "git@github.com:david-tejada/rango.git"
  make_clone "$home/projects/trillium-proj" "git@github.com:trillium/firstmate.git"
  make_clone "$home/projects/upstream-local" "https://github.com/gastownhall/gascity.git"
  make_clone "$home/projects/swapped-proj" "git@github.com:trillium/rango.git"
  git -C "$home/projects/swapped-proj" remote add upstream "git@github.com:david-tejada/rango.git"

  # no-mistakes on a legacy (non-Trillium, unswapped) origin: the worker must
  # stop rather than let no-mistakes default the PR to upstream.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-nm upstream-proj >/dev/null 2>&1
  brief="$home/data/fork-nm/brief.md"
  assert_grep "# Fork-based project: origin is not yet the fork - STOP before running no-mistakes" "$brief" \
    "no-mistakes brief on a legacy upstream origin lost the stop-before-running rule"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'own `trillium/gnhf` fork, NEVER upstream' "$brief" \
    "no-mistakes fork rule named the wrong fork or dropped the never-upstream wording"
  assert_grep "the PR only goes upstream on the captain's explicit word" "$brief" \
    "fork rule dropped the captain's-explicit-word wording"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'Do NOT run `no-mistakes init --fork-url`' "$brief" \
    "legacy no-mistakes rule dropped the --fork-url warning"
  assert_grep "blocked: project clone's origin is not the trillium fork yet" "$brief" \
    "legacy no-mistakes rule dropped the explicit blocked-status instruction"

  # no-mistakes on the correctly swapped setup (origin = fork, upstream =
  # separate remote): origin already targets the fork, so no-mistakes may run,
  # but --fork-url is still forbidden since it would redirect the PR upstream.
  cat >> "$home/data/projects.md" <<'EOF'
- swapped-proj [no-mistakes] - correctly swapped fork-contribution project (added 2026-08-01)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-nm-swapped swapped-proj >/dev/null 2>&1
  brief="$home/data/fork-nm-swapped/brief.md"
  assert_grep "# Fork-based project: PRs stay in the fork, never upstream" "$brief" \
    "swapped no-mistakes brief lost the fork-target rule"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'already the `trillium/rango` fork, with `upstream` as a separate remote' "$brief" \
    "swapped no-mistakes rule did not confirm the origin/upstream setup"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'Never run `no-mistakes init --fork-url`' "$brief" \
    "swapped no-mistakes rule dropped the --fork-url warning"

  # direct-PR pushes too; SSH origin still resolves the fork name, with an
  # explicit --repo override so gh cannot default the PR base to upstream.
  cat >> "$home/data/projects.md" <<'EOF'
- upstream-ssh [direct-PR] - upstream fork reached over SSH (added 2026-07-01)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-dp upstream-ssh >/dev/null 2>&1
  brief="$home/data/fork-dp/brief.md"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'own `trillium/rango` fork, NEVER upstream' "$brief" \
    "direct-PR fork rule did not resolve the SSH-origin fork name or dropped never-upstream wording"
  # shellcheck disable=SC2016 # Literal backticks must stay unexpanded.
  assert_grep 'gh pr create --repo trillium/rango --base' "$brief" \
    "direct-PR fork rule dropped the explicit --repo override in the gh pr create form"
  assert_grep "never stop to ask fork-vs-local" "$brief" \
    "fork rule dropped the never-ask-fork-vs-local instruction"

  # Trillium-owned origin with no upstream remote: an ordinary captain-owned
  # project, no fork-contribution rule at all.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-tr trillium-proj >/dev/null 2>&1
  brief="$home/data/fork-tr/brief.md"
  assert_no_grep "# Fork-based project" "$brief" \
    "Trillium-origin brief wrongly carried a fork-contribution rule"

  # local-only never pushes: exempt even though the origin is upstream.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-lo upstream-local >/dev/null 2>&1
  brief="$home/data/fork-lo/brief.md"
  assert_no_grep "# Fork-based project" "$brief" \
    "local-only brief wrongly carried a fork-contribution rule"
  pass "fm-brief.sh: fork-contribution PR-target rule covers legacy, swapped, direct-PR, and exempt clone shapes"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# Every ship and scout crewmate brief must open with the Parlay enrollment
# section, so enrolling is the crewmate's first action, the command carries the
# task id, and the section is ordered before # Task. Enrollment is best-effort:
# it must NOT tell the crewmate to block or fail when Parlay is down. Secondmate
# charters are exempt: they return work through the marked-status/corr channel,
# not the shared chat panel.
test_crewmate_briefs_enroll_in_parlay_first() {
  local home brief order
  home="$TMP_ROOT/parlay-enroll-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "enroll-$kind" someproj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "enroll-$kind" someproj >/dev/null 2>&1
    fi
    brief="$home/data/enroll-$kind/brief.md"
    assert_present "$brief" "$kind: brief was not scaffolded"
    assert_grep "# FIRST ACTION: enroll in Parlay" "$brief" \
      "$kind: brief missing the Parlay enrollment section"
    # The enrollment command must carry this task's id, not a placeholder.
    # shellcheck disable=SC2016  # literal backticks and command must stay unexpanded
    assert_grep '`parlay listen --agent enroll-'"$kind"'`' "$brief" \
      "$kind: enrollment command missing or not bound to the task id"
    # shellcheck disable=SC2016  # literal Monitor snippet must stay unexpanded
    assert_grep 'Monitor({ command: "parlay listen --agent enroll-'"$kind"'", persistent: true })' "$brief" \
      "$kind: enrollment missing the persistent Monitor-tool form"
    # Best-effort contract: enrollment is explicitly non-blocking.
    assert_grep "Enrollment is best-effort, never a blocker" "$brief" \
      "$kind: enrollment missing the best-effort, never-a-blocker contract"
    assert_grep "continue with your task normally" "$brief" \
      "$kind: enrollment must tell the crewmate to continue when Parlay is down"
    # It must NOT reintroduce the fail-loudly block-on-failure posture.
    # shellcheck disable=SC2016  # literal blocked-status wording must stay unexpanded
    assert_no_grep '`blocked: parlay enrollment failed' "$brief" \
      "$kind: enrollment must not tell the crewmate to block when enrollment fails"
    assert_no_grep "No agent starts work without enrollment." "$brief" \
      "$kind: enrollment must not carry the mandatory no-work-without-enrollment posture"
    # Enrollment must precede the task so it is genuinely the first action.
    order=$(awk '/FIRST ACTION: enroll in Parlay/{e=NR} /^# Task/{t=NR} END{print (e && t && e<t)?"ok":"bad"}' "$brief")
    [ "$order" = ok ] || fail "$kind: Parlay enrollment section is not ordered before # Task"
  done

  # Secondmate charters do not enroll in the shared chat panel.
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" enroll-sm --secondmate alpha >/dev/null 2>&1
  brief="$home/data/enroll-sm/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep "# FIRST ACTION: enroll in Parlay" "$brief" \
    "secondmate charter wrongly carried the crewmate Parlay enrollment section"
  pass "fm-brief.sh: ship/scout briefs enroll in Parlay first (best-effort); secondmate charters are exempt"
}

# add_beads_task_mock_resolve <fakebin_dir> <minted_id> <calls_log>: a fake `task`
# CLI reporting no existing task:<id>-labeled bead, so `create` mints <minted_id>,
# logging every invocation so a test can assert it was never called.
add_beads_task_mock_resolve() {
  local fakebin_dir=$1 minted_id=$2 calls_log=$3
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
case "\$1" in
  list) printf '[]\n' ;;
  create) printf '%s\n' "$minted_id" ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# Test: under config/backlog-backend=beads, fm-brief.sh does NOT mint or resolve
# a bead at scaffold time (beads-authority migration Stage 3 defers that to
# fm-spawn.sh, at actual dispatch time) - a brief that is scaffolded but never
# spawned must never leave an orphaned bead in the shared store. Covers ship and
# scout briefs; secondmate charters stay exempt as before.
test_beads_backend_does_not_mint_at_brief_time() {
  local home fakebin brief calls_log
  home="$TMP_ROOT/beads-backend-home"
  mkdir -p "$home/data" "$home/config"
  printf 'beads\n' > "$home/config/backlog-backend"
  write_registry "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/beads-backend-fake")
  calls_log="$TMP_ROOT/beads-backend-fake-calls.log"
  add_beads_task_mock_resolve "$fakebin" bead-auto-brief-1 "$calls_log"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" beads-auto-ship no-registry-proj >/dev/null 2>&1
  brief="$home/data/beads-auto-ship/brief.md"
  assert_present "$brief" "ship brief was not scaffolded under the beads backend"
  assert_no_grep "# Bead Receipt" "$brief" \
    "ship brief wrongly minted/rendered a Bead Receipt section at scaffold time under the beads backend"
  assert_no_grep "# Bead Closure" "$brief" \
    "ship brief wrongly minted/rendered a Bead Closure section at scaffold time under the beads backend"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" beads-auto-scout no-registry-proj --scout >/dev/null 2>&1
  brief="$home/data/beads-auto-scout/brief.md"
  assert_present "$brief" "scout brief was not scaffolded under the beads backend"
  assert_no_grep "# Bead Receipt" "$brief" \
    "scout brief wrongly minted/rendered a Bead Receipt section at scaffold time under the beads backend"

  # Secondmate charters stay exempt too.
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" beads-auto-sm --secondmate alpha >/dev/null 2>&1
  brief="$home/data/beads-auto-sm/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded under the beads backend"
  assert_no_grep "# Bead Receipt" "$brief" \
    "secondmate charter wrongly picked up bead auto-linking under the beads backend"

  # An explicit FM_HOOK_BEADS_ID still renders the hook sections under the beads
  # backend (the pre-existing --beads opt-in path is unaffected by deferring
  # auto-minting); it must not trigger any task CLI lookup/mint either.
  FM_HOOK_BEADS_ID=bead-explicit-under-beads-backend \
    PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" beads-explicit-ship no-registry-proj >/dev/null 2>&1
  brief="$home/data/beads-explicit-ship/brief.md"
  assert_grep "task set-state bead-explicit-under-beads-backend dispatch=claimed" "$brief" \
    "an explicit FM_HOOK_BEADS_ID did not render the Bead Receipt section under the beads backend"

  [ -e "$calls_log" ] \
    && fail "fm-brief.sh invoked the task CLI under the beads backend, minting a bead at scaffold time: $(cat "$calls_log")"
  pass "fm-brief.sh: under config/backlog-backend=beads, briefs never mint/resolve a bead at scaffold time (deferred to fm-spawn.sh); an explicit FM_HOOK_BEADS_ID still renders hook sections; secondmate charters stay exempt"
}

# Test: under the default (non-beads) backend, briefs are unchanged - no Bead
# Receipt/Closure sections appear absent an explicit FM_HOOK_BEADS_ID, exactly
# as before this backend existed.
test_default_backend_omits_hook_sections() {
  local home brief
  home="$TMP_ROOT/default-backend-home"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" no-beads-ship no-registry-proj >/dev/null 2>&1
  brief="$home/data/no-beads-ship/brief.md"
  assert_present "$brief" "ship brief was not scaffolded under the default backend"
  assert_no_grep "# Bead Receipt" "$brief" \
    "ship brief wrongly carried a Bead Receipt section under the default backend"
  assert_no_grep "# Bead Closure" "$brief" \
    "ship brief wrongly carried a Bead Closure section under the default backend"

  # An explicit FM_HOOK_BEADS_ID still works under the default backend (the
  # pre-existing --beads opt-in path, now that the hook loop is actually wired).
  FM_HOOK_BEADS_ID=bead-explicit-99 FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" explicit-beads-ship no-registry-proj >/dev/null 2>&1
  brief="$home/data/explicit-beads-ship/brief.md"
  assert_grep "task set-state bead-explicit-99 dispatch=claimed" "$brief" \
    "an explicit FM_HOOK_BEADS_ID did not render the Bead Receipt section under the default backend"
  pass "fm-brief.sh: default backend omits Bead Receipt/Closure sections unless FM_HOOK_BEADS_ID is explicitly set"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_fork_first_push_rule
test_scout_and_secondmate_scaffold
test_crewmate_briefs_enroll_in_parlay_first
test_beads_backend_does_not_mint_at_brief_time
test_default_backend_omits_hook_sections
