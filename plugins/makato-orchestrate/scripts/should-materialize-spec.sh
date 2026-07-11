#!/usr/bin/env bash
# should-materialize-spec.sh — deterministic HALT-006 recovery gate for the
# PO-agent's Step 1 (#200).
#
# When the PO-agent resolves its spec folder (Step 1) and finds a MISSING
# folder or a stub / hollow `plan.md`, the historical behaviour is an
# unconditional HALT-006 → `needs-human-review`. On a fresh clone this
# dead-ends every autonomous run, because `specs/` is a gitignored scratch dir
# (only `build.jsonl` is tracked), so the plan.md seed-issue wrote locally
# never travels with the clone.
#
# This gate decides — deterministically, offline — whether the PO-agent should
# instead AUTO-MATERIALIZE the plan (dispatch the light-planner agent to write
# a real plan.md from the GitHub issue body) and retry Step 1 once, or fall
# through to the existing HALT-006 path.
#
# Two independent inputs drive the decision, matching issue #200's design:
#
#   1. The HALT-006 sub-cause (issue #200 point 4): only a MISSING folder or a
#      stub / hollow plan.md is materializable. A plan that is already VALID is
#      not a HALT-006 case at all (the PO-agent proceeds normally); every other
#      HALT-006 origin (malformed dispatch bundle, gh-unauth, dependency cycle)
#      is handled elsewhere in the PO-agent and never reaches this gate. The
#      sub-cause is classified by delegating to `validate-plan-body.sh` — the
#      SAME guard seed-issue's lightweight lane uses, so the two never disagree
#      about what "empty" / "stub" means.
#
#   2. Eligibility (issue #200 point 1, reconciled to the merged taxonomy):
#      only issues carrying the `plan-tier:light` label are eligible. That
#      label is the #211 classifier's signal for "small, well-scoped work
#      suitable for the plan-only lightweight lane" — exactly issue #200's
#      "small, low-risk fix/bug scope" gate, expressed in the taxonomy that
#      actually shipped (there is no `type:fix` / `type:bug` label; seed-issue
#      maps bug/fix issues to `type:change`, routed to makato-change).
#      `plan-tier:full` and unlabelled feature/epic issues keep the current
#      HALT-006 → human-review behaviour, since their plans warrant human
#      shaping.
#
# Usage:
#   should-materialize-spec.sh <plan-path> <label>...
#
#   <plan-path>  Absolute or relative path to the resolved plan.md. May not
#               exist (a MISSING spec folder is the canonical fresh-clone case).
#   <label>...  Zero or more issue label names (as separate arguments, e.g.
#               the output of `gh issue view N --json labels
#               --jq '.labels[].name'`). Order is irrelevant.
#
# Output (stdout): exactly one line "<verdict> <reason>"
#   verdict ∈ {materialize, proceed, halt}
#     materialize — MISSING/stub plan AND plan-tier:light → run light-planner,
#                   then re-validate and retry Step 1 once.
#     proceed     — plan.md is already VALID → not a HALT-006 case; the
#                   PO-agent continues to Step 2 unchanged.
#     halt        — MISSING/stub plan AND NOT plan-tier:light → the existing
#                   HALT-006 → needs-human-review path.
#   reason:
#     for `proceed`     → "plan-valid"
#     for `materialize` → the validate-plan-body reason (missing-file,
#                          no-tasks-heading, empty-tasks, no-acceptance-heading,
#                          empty-acceptance)
#     for `halt`        → "<validate-plan-body-reason>-not-light"
#
# Exit code: 0 for `materialize` or `proceed`, 1 for `halt`. The stdout verdict
# is the authoritative signal; the exit code mirrors "is this a stop" for `if`
# convenience.
#
# Pure bash — delegates only to the sibling validate-plan-body.sh (itself pure
# bash + awk/grep). No gh, no network, no agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/validate-plan-body.sh"

PLAN_PATH="${1:-}"
shift || true
# Remaining args are label names.
LABELS=("$@")

# emit <verdict> <reason>: print the one-line result, then exit 0 unless the
# verdict is a hard stop (halt → exit 1). Every terminal path funnels through
# here so stdout and exit code can never disagree.
emit() {
  printf '%s %s\n' "$1" "$2"
  [ "$1" = "halt" ] && exit 1 || exit 0
}

if [ -z "$PLAN_PATH" ]; then
  echo "usage: should-materialize-spec.sh <plan-path> <label>..." >&2
  exit 2
fi

# Classify the HALT-006 sub-cause via the shared plan-body guard. Its stdout is
# "<valid|invalid> <reason>"; we key off both fields.
guard_out="$(bash "$GUARD" "$PLAN_PATH" 2>/dev/null || true)"
guard_verdict="${guard_out%% *}"          # valid | invalid
guard_reason="${guard_out#* }"            # ok | missing-file | empty-tasks | …
[ "$guard_reason" = "$guard_out" ] && guard_reason=""   # no space → no reason

# A valid plan is not a HALT-006 case — the PO-agent proceeds unchanged.
if [ "$guard_verdict" = "valid" ]; then
  emit proceed plan-valid
fi

# From here the plan is MISSING or a stub/hollow file — a materializable
# HALT-006 sub-cause. Eligibility is decided solely by the plan-tier:light
# label.
for label in "${LABELS[@]:-}"; do
  if [ "$label" = "plan-tier:light" ]; then
    emit materialize "${guard_reason:-invalid}"
  fi
done

emit halt "${guard_reason:-invalid}-not-light"
