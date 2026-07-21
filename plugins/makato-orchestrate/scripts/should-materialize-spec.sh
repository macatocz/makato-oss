#!/usr/bin/env bash
# should-materialize-spec.sh — deterministic HALT-006 recovery gate for the
# PO-agent's Step 1 (#200, extended by #527).
#
# When the PO-agent resolves its spec folder (Step 1) and finds a MISSING
# folder or a stub / hollow `plan.md`, the historical behaviour is an
# unconditional HALT-006 → `needs-human-review`. On a fresh clone this
# dead-ends every autonomous run, because `specs/` is a gitignored scratch dir
# (only `build.jsonl`, `spec.md`, and — since #527 — `stories.json` /
# `created-issues.json` are tracked), so the plan.md seed-issue wrote locally
# never travels with the clone.
#
# This gate decides — deterministically, offline — whether the PO-agent should
# instead AUTO-MATERIALIZE the plan and retry Step 1 once, or fall through to
# the existing HALT-006 path. There are two materialization engines:
#
#   * `materialize-refine` (#527) — a git-tracked `stories.json` with at least
#     one story entry sits next to the plan. The PO-agent dispatches
#     `build-refine --autonomous <KEY>`, which translates that committed
#     `stories.json` into a real `plan-<N>.md` (Step 4 selects the matching
#     story; key is identity, not content). This is the richer, authoritative
#     source and takes PRECEDENCE over the light-planner path.
#   * `materialize` (#200) — no committed stories.json, but the issue carries
#     `plan-tier:light`. The PO-agent dispatches the light-planner agent to
#     synthesize a plan from the GitHub issue body.
#
# Three independent inputs drive the decision:
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
#   2. Committed stories.json presence (#527): the spec dir — derived from
#      `dirname <plan-path>` — carries a `stories.json` that is (a) git-tracked
#      (so it survives a fresh clone/worktree) AND (b) holds ≥ 1 story entry.
#      An UNTRACKED stories.json will not travel with a fresh clone, so it
#      cannot drive the autonomous build-refine path: the gate emits a WARN to
#      stderr and DEGRADES to the tier-based fallback (rows 3/4). Row 2 (a
#      committed stories.json) takes precedence over row 3 (plan-tier:light).
#
#   3. Eligibility for the light-planner fallback (issue #200 point 1):
#      only issues carrying the `plan-tier:light` label are eligible. That
#      label is the #211 classifier's signal for "small, well-scoped work
#      suitable for the plan-only lightweight lane". `plan-tier:full` and
#      unlabelled feature/epic issues WITHOUT a committed stories.json keep the
#      HALT-006 → human-review behaviour, since their plans warrant human
#      shaping.
#
# Decision table (priority top-down, first match wins):
#
#   | # | Condition                                             | Verdict            |
#   |---|-------------------------------------------------------|--------------------|
#   | 1 | plan-<N>.md valid                                     | proceed            |
#   | 2 | missing/stub plan AND tracked stories.json (≥1 story) | materialize-refine |
#   | 3 | missing/stub plan AND plan-tier:light (no stories)    | materialize        |
#   | 4 | otherwise                                             | halt               |
#
# Usage:
#   should-materialize-spec.sh <plan-path> <label>...
#
#   <plan-path>  Absolute or relative path to the resolved plan.md. May not
#               exist (a MISSING spec folder is the canonical fresh-clone case).
#               The stories.json probe reads `<dirname>/stories.json`.
#   <label>...  Zero or more issue label names (as separate arguments, e.g.
#               the output of `gh issue view N --json labels
#               --jq '.labels[].name'`). Order is irrelevant.
#
# Output (stdout): exactly one line "<verdict> <reason>"
#   verdict ∈ {materialize-refine, materialize, proceed, halt}
#     materialize-refine — MISSING/stub plan AND a tracked stories.json with
#                   ≥1 story → dispatch build-refine --autonomous, then
#                   re-validate and retry Step 1 once.
#     materialize — MISSING/stub plan AND plan-tier:light (no committed
#                   stories.json) → run light-planner, then re-validate and
#                   retry Step 1 once.
#     proceed     — plan.md is already VALID → not a HALT-006 case; the
#                   PO-agent continues to Step 2 unchanged.
#     halt        — MISSING/stub plan AND neither engine applies → the existing
#                   HALT-006 → needs-human-review path.
#   reason:
#     for `proceed`            → "plan-valid"
#     for `materialize-refine` → the validate-plan-body reason (missing-file,
#                                 no-tasks-heading, empty-tasks, …)
#     for `materialize`        → the validate-plan-body reason
#     for `halt`               → "<validate-plan-body-reason>-no-engine"
#                                 ("no materialization engine applies" — no
#                                 committed stories.json AND not plan-tier:light)
#
# Exit code: 0 for `materialize-refine`, `materialize`, or `proceed`; 1 for
# `halt`. The stdout verdict is the authoritative signal; the exit code mirrors
# "is this a stop" for `if` convenience.
#
# Delegates to the sibling validate-plan-body.sh (pure bash + awk/grep) for the
# plan sub-cause; uses `git ls-files` to classify stories.json tracked-ness and
# jq/python3 (with a grep fallback) to count story entries. No gh, no network,
# no agent.
#
# Test hooks (keep the smoke tests offline — no git repo required):
#   MAKATO_SPEC_STORIES_TRACKED=1  force the stories.json tracked-check to pass
#   MAKATO_SPEC_STORIES_TRACKED=0  force the stories.json tracked-check to fail
#   (unset → real `git ls-files --error-unmatch` probe)
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

# stories_tracked <file>: true when the file is git-tracked (survives a fresh
# clone/worktree). Honours the MAKATO_SPEC_STORIES_TRACKED test hook so smoke
# tests need no real git repo.
stories_tracked() {
  local f="$1"
  case "${MAKATO_SPEC_STORIES_TRACKED:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  git -C "$(dirname "$f")" ls-files --error-unmatch "$(basename "$f")" \
    >/dev/null 2>&1
}

# stories_has_entries <file>: true when the JSON carries a non-empty
# `stories[]` array. Prefers jq, then python3, then a grep heuristic — so the
# gate stays functional on minimal images without a hard jq dependency.
stories_has_entries() {
  local f="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.stories // []) | length > 0' "$f" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if len(d.get("stories", [])) > 0 else 1)' "$f" 2>/dev/null
  else
    # Heuristic: a "stories" key whose array holds at least one object.
    grep -q '"stories"' "$f" 2>/dev/null && grep -qE '\{[^}]' "$f" 2>/dev/null
  fi
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
# HALT-006 sub-cause.

# --- Row 2: committed stories.json is the richer, authoritative source ------
# A git-tracked stories.json with ≥1 story next to the plan lets the PO-agent
# dispatch `build-refine --autonomous <KEY>` (build-refine Step 4 selects the
# matching story). This takes precedence over the plan-tier:light light-planner
# path below (row 3). An untracked stories.json cannot survive a fresh clone —
# warn and degrade to the tier fallback rather than promise a path that will
# vanish on checkout.
#
# Capture each helper's outcome into an explicit bool BEFORE the decision
# logic, so correctness never depends on a helper staying syntactically inside
# an `if` test (a `return 1` from an assignment context would trip `set -e`).
SPEC_DIR="$(dirname "$PLAN_PATH")"
STORIES="$SPEC_DIR/stories.json"

stories_present=false
[ -f "$STORIES" ] && stories_present=true

stories_nonempty=false
if [ "$stories_present" = true ] && stories_has_entries "$STORIES"; then
  stories_nonempty=true
fi

stories_is_tracked=false
if [ "$stories_nonempty" = true ] && stories_tracked "$STORIES"; then
  stories_is_tracked=true
fi

if [ "$stories_is_tracked" = true ]; then
  emit materialize-refine "${guard_reason:-invalid}"
elif [ "$stories_nonempty" = true ]; then
  # Present + non-empty but untracked → cannot survive a fresh clone.
  echo "should-materialize-spec: WARN untracked stories.json at $STORIES —" \
    "build-refine materialization is unavailable on a fresh clone;" \
    "degrading to the tier-based fallback" >&2
fi

# --- Row 3: light-planner fallback (plan-tier:light) ------------------------
# No committed stories.json applies. Eligibility for the light-planner engine
# is decided solely by the plan-tier:light label.
for label in "${LABELS[@]:-}"; do
  if [ "$label" = "plan-tier:light" ]; then
    emit materialize "${guard_reason:-invalid}"
  fi
done

# --- Row 4: no materialization engine applies → HALT-006 --------------------
# Neither a committed stories.json (row 2) nor plan-tier:light (row 3) applies.
emit halt "${guard_reason:-invalid}-no-engine"
