#!/usr/bin/env bash
# fm-groom-lib.sh - brief-FORMULATION and SAFETY-CLASSIFICATION for fm-groom.sh.
#
# This is the value core split out from the orchestrator (fm-groom.sh): given a
# rough idea (title + description), MANUFACTURE a concrete, runnable brief string
# and DECIDE whether that work is safe to auto-dispatch. Both decisions go through
# an LLM (PAI Inference.ts, subscription-billed) with PLAIN, non-instructional
# prompts so PAI's PromptGuard injection inspector does not block the nested claude
# (see data/learnings.md: instruction-style briefs -- "You are an agent...",
# "guardrails", "do NOT..." -- are classified as injection and blocked at 0 turns).
#
# Sourced by fm-groom.sh; no side effects at source time. Every function prints to
# stdout and returns non-zero on failure so the orchestrator can decide fallback.
#
# Dependencies: bun + PAI Inference.ts on the resolving path (fm_groom_inference_bin).
set -u

# Strip leading and trailing blank lines from a string (portable: awk, not the
# GNU-only multiline sed forms that BSD/macOS sed rejects). Interior blank lines
# are preserved so a formulated brief keeps its paragraph structure.
fm_groom_trim_blank_lines() {
  printf '%s\n' "$1" | awk '
    { lines[NR] = $0 }
    END {
      first = 0; last = 0
      for (i = 1; i <= NR; i++) if (lines[i] ~ /[^[:space:]]/) { if (!first) first = i; last = i }
      if (!first) exit
      for (i = first; i <= last; i++) print lines[i]
    }'
}

# Resolve the PAI Inference.ts tool. Overridable via FM_GROOM_INFERENCE for tests
# (a mock script that reads the same argv shape). Default is the PAI install path.
fm_groom_inference_bin() {
  if [ -n "${FM_GROOM_INFERENCE:-}" ]; then
    printf '%s\n' "$FM_GROOM_INFERENCE"
    return 0
  fi
  printf '%s\n' "${HOME}/.claude/PAI/TOOLS/Inference.ts"
}

# Run one inference turn. Args: <level> <system_prompt> <user_prompt>.
# When FM_GROOM_INFERENCE is set it is invoked directly as an executable with the
# same three positional args (level system user) plus a leading --level pair, so a
# mock can stub the LLM without bun. Otherwise `bun <Inference.ts> --level ...`.
# Prints the model's stdout; returns the child's exit status.
fm_groom_infer() {
  local level=$1 system=$2 user=$3 bin
  bin=$(fm_groom_inference_bin)
  if [ -n "${FM_GROOM_INFERENCE:-}" ]; then
    "$bin" --level "$level" "$system" "$user"
  else
    bun "$bin" --level "$level" "$system" "$user"
  fi
}

# Formulate a concrete runnable brief from a rough idea.
# Args: <title> <description>. Prints the formulated brief to stdout.
# The prompts are deliberately descriptive ("Write a task description...")
# rather than imperative role-play, both to dodge PromptGuard AND because the
# OUTPUT is what a downstream agent will act on -- we want a plain task spec, not
# a persona. Returns non-zero if inference failed or produced empty output.
fm_groom_formulate_brief() {
  local title=$1 desc=$2 system user out
  system=$(cat <<'SYS'
The assistant is a technical planning helper. Given a short product idea, it
writes a single concrete, self-contained task description that another engineer
could pick up and run without further clarification. The description names the
goal in one sentence, lists the concrete first steps, names the files or systems
likely involved when they are inferable, and states what "done" looks like. It
writes plain prose and short lists. It never adds preamble, never asks questions,
and never role-plays. It outputs only the task description, nothing else.
SYS
)
  user=$(printf 'Idea title: %s\n\nIdea notes: %s\n\nWrite the concrete task description now.' "$title" "$desc")
  out=$(fm_groom_infer standard "$system" "$user") || return 1
  out=$(fm_groom_trim_blank_lines "$out")
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Classify a formulated brief as safe-to-auto-dispatch or escalate.
# Args: <title> <brief>. Prints exactly one word on the first line:
#   safe      research / design / prototype / investigation - reversible, no
#             production or shared-state mutation; OK to auto-dispatch.
#   escalate  merges, deploys, credential/security changes, anything touching
#             production or irreversible shared state - firstmate must NOT run it;
#             file a review item for the captain instead.
# A second line carries a one-sentence rationale. Any parse failure or ambiguous
# answer is treated by the caller as `escalate` (fail-safe). Returns non-zero on
# inference failure so the caller can fail-safe.
fm_groom_classify() {
  local title=$1 brief=$2 system user out verdict
  system=$(cat <<'SYS'
The assistant is a risk triage helper for an autonomous work dispatcher. It reads
a task description and answers whether the task is safe for an automated system to
start on its own, unattended, without a human first approving it.

It answers with exactly one word on the first line: "safe" or "escalate".

A task is "safe" when it is research, investigation, design, a scoped prototype,
a local experiment, documentation, or analysis -- work that is reversible and does
not merge code, deploy, publish, rotate credentials, change security or auth
settings, delete data, or otherwise mutate production or shared state.

A task is "escalate" when it merges or pushes to a shared branch, deploys or
releases, publishes anything externally, touches credentials, keys, auth, or
security posture, deletes or migrates data, or makes any irreversible or
production-affecting change. When uncertain, it answers "escalate".

The second line is one short sentence of rationale. It outputs nothing else.
SYS
)
  user=$(printf 'Task title: %s\n\nTask description: %s\n\nAnswer now.' "$title" "$brief")
  # standard tier (sonnet, 30s): the fast/haiku 15s ceiling is too tight for the
  # safety reasoning, and a timeout would fail-safe to escalate -- costing the
  # captain a needless review item. Classification reliability is worth one tier up.
  out=$(fm_groom_infer standard "$system" "$user") || return 1
  # ASCII-only on purpose: the verdict vocabulary is "safe"/"escalate".
  # shellcheck disable=SC2018,SC2019
  verdict=$(printf '%s\n' "$out" | sed -e '/./,$!d' | head -1 | tr 'A-Z' 'a-z' | tr -cd 'a-z')
  case "$verdict" in
    safe|escalate) : ;;
    *) verdict=escalate ;;  # fail-safe: anything unparseable escalates
  esac
  # Emit verdict then the rationale line (best-effort; may be empty).
  printf '%s\n' "$verdict"
  printf '%s\n' "$out" | sed -e '/./,$!d' | sed -n '2p'
}
