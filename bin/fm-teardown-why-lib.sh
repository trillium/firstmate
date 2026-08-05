#!/usr/bin/env bash
# fm-teardown-why-lib.sh - the single owner of the `fm-teardown.sh --why-blocked`
# exit protocol, shared by the query itself (bin/fm-teardown.sh) and its caller
# (bin/fm-watch.sh's teardown_blocked_sweep) so the two can never drift.
#
# The protocol is three-way, and deliberately reserves NOTHING for exit 1:
#
#   0                                teardown IS blocked; the refusal text
#                                    naming the blocking work is on stdout.
#   TEARDOWN_WHY_NOT_BLOCKED         teardown is NOT blocked; the production
#                                    safety predicate actually ran and passed.
#   anything else                    INDETERMINATE: the query could not answer.
#
# Why "not blocked" needs its own code instead of exit 1: it is the one answer
# that makes the caller drop a finished task silently and permanently. `exit 1`
# is also what every ordinary failure in fm-teardown.sh's setup produces - a
# missing meta, an endpoint the backend rejects, an unresolvable Orca worktree
# id - so reusing it turns a malformed task into forever-silence instead of a
# retry. Making the silent answer un-collidable BY CONSTRUCTION means the caller
# never has to enumerate which setup steps can fail: everything that is not this
# exact code is indeterminate and gets retried on the next sweep.
# shellcheck disable=SC2034 # Protocol constants read by the sourcing scripts.
TEARDOWN_WHY_NOT_BLOCKED=10
# The explicit indeterminate answer fm-teardown.sh returns when it reached the
# safety predicate but the predicate could not decide (see why_teardown_blocked).
# Callers must treat every non-0, non-TEARDOWN_WHY_NOT_BLOCKED code the same way,
# so this value is a diagnostic aid, never a code the caller special-cases.
# shellcheck disable=SC2034 # Protocol constants read by the sourcing scripts.
TEARDOWN_WHY_INDETERMINATE=11
