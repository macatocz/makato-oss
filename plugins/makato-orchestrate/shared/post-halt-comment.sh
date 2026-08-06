#!/usr/bin/env bash
# post-halt-comment.sh — post one structured GitHub issue comment per
# needs-human-review application.
#
# WHY THIS EXISTS
# ---------------
# When the PO-agent or loop.sh applies the needs-human-review label, the
# issue owner has no context about what broke or how to fix it. This helper
# posts a structured comment with the HALT code, a one-sentence explanation,
# actionable recovery steps, and a "Next step" reminder — matching the
# Recovery column in halt-conditions.md.
#
# USAGE
#   post-halt-comment.sh <HALT_CODE> <ISSUE_NUMBER> <REPO> \
#       [--reason "<text>"] [--what-to-fix "<text>"]
#
# If --reason and --what-to-fix are omitted, the built-in lookup table
# for the given HALT code is used. For unknown codes a generic fallback
# message is generated.
#
# ENVIRONMENT
#   MAKATO_POST_HALT_COMMENT_DISABLE=1
#       Silent no-op, exit 0. Use for local dry-runs.
#
#   MAKATO_POST_HALT_COMMENT_TEST_FILE=<path>
#       Test hook: append the comment body to this file instead of calling
#       `gh issue comment`. The file is appended (not overwritten), so
#       multiple calls can be inspected without resetting between tests.
#
# BEST-EFFORT CONTRACT
#   Any gh failure logs a WARN to stderr and exits 0. This helper NEVER
#   blocks a HALT path or changes the exit code of the enclosing function
#   — same convention as shared/progress-comment.sh.
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
HALT_CODE="${1:-}"
ISSUE="${2:-}"
REPO="${3:-}"

if [[ -z "$HALT_CODE" || -z "$ISSUE" || -z "$REPO" ]]; then
  echo "post-halt-comment: usage: post-halt-comment.sh <HALT_CODE> <ISSUE_NUMBER> <REPO> [--reason '<text>'] [--what-to-fix '<text>']" >&2
  exit 1
fi

shift 3 || true

OVERRIDE_REASON=""
OVERRIDE_WHAT_TO_FIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)      OVERRIDE_REASON="$2";    shift 2 ;;
    --what-to-fix) OVERRIDE_WHAT_TO_FIX="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Opt-out
# ---------------------------------------------------------------------------
if [[ "${MAKATO_POST_HALT_COMMENT_DISABLE:-}" == "1" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Built-in reason / what-to-fix lookup table (sourced from halt-conditions.md)
# Keys map HALT code → "reason|what_to_fix" separated by the first pipe.
# ---------------------------------------------------------------------------
_lookup() {
  local code="$1"
  case "$code" in
    HALT-000)
      echo "Operator HALT file detected — the run was stopped by the operator placing a HALT file.|Remove \`~/.claude/HALT\` once you are ready to resume, then re-invoke \`loop --autonomous <issue>\`."
      ;;
    HALT-001)
      echo "Pre-commit sensor gate failed and sensor-fixer could not repair it within the retry budget.|Inspect the failed sensor output in \`specs/<key>/build.jsonl\`, fix the finding manually, then restart the loop."
      ;;
    HALT-002)
      echo "Test coverage is below the configured floor and re-planning failed to recover.|Either raise coverage manually to meet the floor, or relax the floor in \`makato.config.json\`, then restart the loop."
      ;;
    HALT-003)
      echo "CRITICAL reviewer findings or STRUCTURAL PR comments could not be addressed within the retry budget.|Review the findings in \`specs/<key>/build.jsonl\` and decide per-finding whether to fix manually, suppress with rationale, or re-shape the story via \`makato-plan\`."
      ;;
    HALT-004)
      echo "Sensor-fixer per-finding MAX_LOOPS exhausted on the same finding.|Manually resolve the finding; the sensor harness will then accept a clean commit."
      ;;
    HALT-005)
      echo "Git push was denied by the pre-push deny-list (force-push to main, protected branch, etc.).|Review the push intent — if legitimate, remove the deny condition (e.g. rebase away from main) and restart."
      ;;
    HALT-006)
      echo "The dispatch context bundle (specs/<key>-<slug>/) is missing or malformed.|Re-run \`makato-plan decompose\` to regenerate the spec folder, or expand the issue body so \`light-planner\` can produce a plan, then restart the loop."
      ;;
    HALT-007)
      echo "Token budget exhausted — the per-task or daily token ceiling was reached.|Raise the budget ceiling, split the issue into smaller stories, or write off the work, then restart \`loop --autonomous\`."
      ;;
    HALT-008)
      echo "A retry budget was exhausted (re-plan iterations, merge-conflict cycles, or CI-failure cycles).|Read the \`lessons_learned\` trail in workflow-state.json; rewrite the plan, split the story, or resolve the conflict/CI failure by hand, then restart the loop."
      ;;
    HALT-009)
      echo "The \`claude-halt\` label was detected on this issue — an explicit operator stop.|Remove the \`claude-halt\` label and \`needs-human-review\`, then restart."
      ;;
    HALT-010)
      echo "Human-review cycle ceiling reached — the issue has cycled through review too many times.|Decide whether to cancel, split, or re-shape the story via \`makato-plan\`, then restart."
      ;;
    HALT-011)
      echo "A build sub-skill exited silently without a terminal session line in build.jsonl.|Inspect \`specs/<key>/build.jsonl\` to find where the sub-skill died, fix the root cause, then re-run \`loop --autonomous <issue>\`."
      ;;
    HALT-012)
      echo "The review-poll timed out waiting for a first reviewer decision.|Assign a reviewer (or review the PR yourself), remove \`needs-human-review\`, and re-invoke \`loop --autonomous <issue>\`. Raise \`MAKATO_REVIEW_WAIT_SECS\` for repos with slow review SLAs."
      ;;
    HALT-013)
      echo "Reshape cycle ceiling reached — the issue has been re-shaped the maximum allowed times.|Inspect \`specs/<key>/reshape-request.json\`, shape the issue manually via \`makato-plan\`, remove \`needs-human-review\` and \`needs-reshape\`, then restart."
      ;;
    HALT-014)
      echo "Stall-restart ceiling reached — the issue has stalled the maximum allowed times without progressing.|Diagnose the semantic dead loop (failing CI gate, irresolvable conflict, or unimplementable plan), apply the fix, remove \`needs-human-review\`, then restart."
      ;;
    HALT-STRUCTURAL)
      echo "A dispatched sub-agent returned a failure with escalation:refine and re-planning also failed.|Re-shape the plan via \`makato-plan\`, then restart the loop."
      ;;
    *)
      echo "An unrecognised HALT condition was reached.|Inspect \`specs/<key>/orchestrate.jsonl\` and \`workflow-state.json\` for the root cause, resolve the underlying issue, remove \`needs-human-review\`, then restart the loop."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Resolve reason and what-to-fix (override > lookup > generic fallback)
# ---------------------------------------------------------------------------
if [[ -n "$OVERRIDE_REASON" || -n "$OVERRIDE_WHAT_TO_FIX" ]]; then
  REASON="${OVERRIDE_REASON:-An autonomous HALT condition was reached.}"
  WHAT_TO_FIX="${OVERRIDE_WHAT_TO_FIX:-Inspect the orchestrate.jsonl and workflow-state.json for the root cause, then remove \`needs-human-review\` and restart the loop.}"
else
  LOOKUP="$(_lookup "$HALT_CODE")"
  REASON="${LOOKUP%%|*}"
  WHAT_TO_FIX="${LOOKUP#*|}"
fi

# ---------------------------------------------------------------------------
# Build comment body
# ---------------------------------------------------------------------------
# `seed-issue` (re)creates the specs/<n>-<slug>/ folder and moves the board
# card to Ready. It is ONLY the correct resume verb when that folder is
# missing/malformed (HALT-006) or when the issue was never seeded. By the time
# any *other* HALT fires, the loop has already seeded the issue and usually
# opened a PR — a second seed-issue run forks a duplicate stub plan.md (shared
# specs/ folder collision). For those, the resume verb lives in WHAT_TO_FIX
# above (typically `re-invoke loop --autonomous <issue>`); the board hint alone
# is the safe, non-duplicating "Next step".
if [[ "$HALT_CODE" == "HALT-006" ]]; then
  NEXT_STEP="Run \`seed-issue ${ISSUE}\` (or move the board card to Status=Ready) once the fix is applied."
else
  NEXT_STEP="Once the fix above is applied, move the board card to Status=Ready (or re-invoke \`loop --autonomous ${ISSUE}\`). Do NOT run \`seed-issue\` — the spec folder already exists and re-seeding forks a duplicate stub plan.md."
fi

COMMENT_BODY="## Needs human review

**Reason:** ${HALT_CODE} — ${REASON}
**What to fix:** ${WHAT_TO_FIX}
**Next step:** ${NEXT_STEP}"

# ---------------------------------------------------------------------------
# Emit: test hook or real gh call
# ---------------------------------------------------------------------------
if [[ -n "${MAKATO_POST_HALT_COMMENT_TEST_FILE:-}" ]]; then
  printf '%s\n' "$COMMENT_BODY" >> "$MAKATO_POST_HALT_COMMENT_TEST_FILE"
  exit 0
fi

# Production path — best-effort, never fatal.
if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$COMMENT_BODY" >/dev/null 2>&1; then
  echo "post-halt-comment: WARN — could not post comment on #${ISSUE} (${REPO}); proceeding (best-effort)" >&2
fi

exit 0
