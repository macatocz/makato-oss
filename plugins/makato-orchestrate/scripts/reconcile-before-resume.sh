#!/usr/bin/env bash
# reconcile-before-resume.sh — D7 reconcile decision table for boot-time resume (issue #8).
#
# Reads current_phase and current_issue from workflow-state JSON.  When phase=pr,
# queries GitHub for the PR and its latest CI run to decide the resume branch:
#
#   (a) PR open + CI conclusion=success   → exit 0  (resume from merge)
#   (b) PR open + CI conclusion=failure   → exit 2  (resume in fix mode)
#   (c) PR open + CI still running        → bounded poll then exit 2
#   (d) PR absent / ambiguous (poison-pill) → board-reset + exit 1
#
# When phase is anything other than "pr", exits 0 immediately (nothing to reconcile).
#
# Usage:
#   reconcile-before-resume.sh [--workflow-state <path>] [--repo <owner/name>]
#
# Options:
#   --workflow-state <path>  Path to workflow-state JSON
#                            (default: $MAKATO_PV_WORKFLOW_STATE_DIR/workflow-state.json,
#                             fallback: ~/.makato-pv/workflow-state/workflow-state.json)
#   --repo <owner/name>      GitHub repo slug (required when phase=pr)
#
# Environment:
#   MAKATO_PR_CI_TIMEOUT_SECS  Bounded-wait ceiling for CI in_progress (default: 600)
#   MAKATO_RECONCILE_GH_CMD    Override gh command for tests (default: gh)
#   MAKATO_SUPERVISOR_AUDIT    Audit log path (default: ~/.claude/state/supervisor-audit.jsonl)
#   MAKATO_LOOP_STATE_DIR      State dir used to derive default audit log path
#
# Exit codes:
#   0 — not-pr phase, or PR+CI green (resume normally)
#   1 — poison-pill: PR absent/ambiguous; board-reset performed
#   2 — PR open but CI failed/timed-out (resume in fix mode)
#   3 — usage error or unreadable workflow-state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults and argument parsing
# ---------------------------------------------------------------------------
_DEFAULT_WF_DIR="${MAKATO_PV_WORKFLOW_STATE_DIR:-${MAKATO_PERSISTENT_VOLUME_ROOT:-~/.makato-pv}/workflow-state}"
# Expand leading tilde
[[ "$_DEFAULT_WF_DIR" == "~/"* ]] && _DEFAULT_WF_DIR="$HOME/${_DEFAULT_WF_DIR:2}"
[[ "$_DEFAULT_WF_DIR" == "~" ]]   && _DEFAULT_WF_DIR="$HOME"

WF_STATE="${_DEFAULT_WF_DIR}/workflow-state.json"
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow-state) WF_STATE="$2"; shift 2 ;;
    --repo)           REPO="$2";     shift 2 ;;
    *) echo "reconcile-before-resume: unknown argument '$1'" >&2; exit 3 ;;
  esac
done

GH_CMD="${MAKATO_RECONCILE_GH_CMD:-gh}"
CI_TIMEOUT="${MAKATO_PR_CI_TIMEOUT_SECS:-600}"

_STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$HOME/.claude/state}"
AUDIT_LOG="${MAKATO_SUPERVISOR_AUDIT:-${_STATE_DIR}/supervisor-audit.jsonl}"
mkdir -p "$(dirname "$AUDIT_LOG")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ts() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

_audit() {
  local action="$1" branch="$2" issue="$3"
  printf '{"ts":"%s","action":"%s","branch":"%s","issue":%s}\n' \
    "$(_ts)" "$action" "$branch" "$issue" >> "$AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Step 1 — Read workflow-state
# ---------------------------------------------------------------------------
if [[ ! -f "$WF_STATE" ]]; then
  echo "reconcile-before-resume: workflow-state not found at '$WF_STATE' — nothing to reconcile" >&2
  exit 0
fi

CURRENT_PHASE="$(jq -r '.current_phase // empty' "$WF_STATE" 2>/dev/null || true)"
CURRENT_ISSUE="$(jq -r '.issue_number // empty' "$WF_STATE" 2>/dev/null || true)"

if [[ -z "$CURRENT_PHASE" || "$CURRENT_PHASE" == "null" ]]; then
  echo "reconcile-before-resume: current_phase unset — nothing to reconcile" >&2
  exit 0
fi

if [[ "$CURRENT_PHASE" != "pr" ]]; then
  echo "reconcile-before-resume: current_phase='$CURRENT_PHASE' (not pr) — skip" >&2
  exit 0
fi

# phase=pr — repo arg is required
if [[ -z "$REPO" ]]; then
  echo "reconcile-before-resume: --repo required when current_phase=pr" >&2
  exit 3
fi

ISSUE="${CURRENT_ISSUE:-null}"
BRANCH="$(jq -r '.branch // empty' "$WF_STATE" 2>/dev/null || true)"

echo "reconcile-before-resume: phase=pr issue=$ISSUE branch=${BRANCH:-<unknown>} repo=$REPO" >&2

# ---------------------------------------------------------------------------
# Step 2 — Query for an open PR on this issue's branch
# ---------------------------------------------------------------------------
# Note: --jq is NOT used here so that test stubs can return raw JSON arrays
# and have them processed by the explicit jq pipe below. This keeps the gh
# call testable without a fully functional gh binary.
PR_NUMBER=""
if [[ -n "$BRANCH" ]]; then
  PR_JSON="$("$GH_CMD" pr list --repo "$REPO" \
    --head "$BRANCH" --state open \
    --json number 2>/dev/null || echo "[]")"
  PR_NUMBER="$(printf '%s' "$PR_JSON" | jq -r '.[0].number // empty' 2>/dev/null || true)"
fi

# Fallback: search by issue number when branch lookup found nothing
if [[ -z "$PR_NUMBER" && "$ISSUE" != "null" && -n "$ISSUE" ]]; then
  PR_JSON="$("$GH_CMD" pr list --repo "$REPO" \
    --search "is:open #${ISSUE}" \
    --json number 2>/dev/null || echo "[]")"
  PR_NUMBER="$(printf '%s' "$PR_JSON" | jq -r '.[0].number // empty' 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Step 3 — D7 branch (d): no open PR → poison-pill abort
# ---------------------------------------------------------------------------
if [[ -z "$PR_NUMBER" ]]; then
  echo "reconcile-before-resume: no open PR found for branch=${BRANCH:-<unknown>} — poison-pill detected" >&2

  _audit "poison_pill_detected" "d" "$ISSUE"

  # Add needs-human-review label (best-effort)
  if [[ "$ISSUE" != "null" && -n "$ISSUE" ]]; then
    "$GH_CMD" issue edit "$ISSUE" --repo "$REPO" \
      --add-label "needs-human-review" 2>/dev/null || true
  fi

  # Board-reset to Ready via gh project item-edit (best-effort; requires project config)
  if [[ -n "${MAKATO_TARGET_REPO_ROOT:-}" ]]; then
    TARGET_ROOT="$(cd "$MAKATO_TARGET_REPO_ROOT" 2>/dev/null && pwd -P)" || {
      echo "reconcile-before-resume: target repository root is not a directory: $MAKATO_TARGET_REPO_ROOT" >&2
      exit 1
    }
    git -C "$TARGET_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
      echo "reconcile-before-resume: target repository root is not a git checkout: $TARGET_ROOT" >&2
      exit 1
    }
    CLAUDE_CONFIG="$(cat "$TARGET_ROOT/.claude/config.json" 2>/dev/null || true)"
  else
    CLAUDE_CONFIG="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo '.')/.." 2>/dev/null && \
      cat .claude/config.json 2>/dev/null || true)"
  fi
  if [[ -n "$CLAUDE_CONFIG" ]]; then
    PROJECT_ID="$(printf '%s' "$CLAUDE_CONFIG" | jq -r '.github_project.project_id // empty' 2>/dev/null || true)"
    READY_OPTION_ID="$(printf '%s' "$CLAUDE_CONFIG" | jq -r '.github_project.status_options.ready // empty' 2>/dev/null || true)"
    ITEM_ID="$("$GH_CMD" project item-list "$PROJECT_ID" \
      --owner "$(printf '%s' "$REPO" | cut -d/ -f1)" \
      --format json --jq ".items[] | select(.content.number == $ISSUE) | .id" 2>/dev/null || true)"
    if [[ -n "$PROJECT_ID" && -n "$READY_OPTION_ID" && -n "$ITEM_ID" ]]; then
      "$GH_CMD" project item-edit --id "$ITEM_ID" \
        --project-id "$PROJECT_ID" \
        --field-id status --single-select-option-id "$READY_OPTION_ID" 2>/dev/null || true
    fi
  fi

  # Zero out current_phase and current_issue in workflow-state
  TMP="$(mktemp)"
  jq '.current_phase = null | .issue_number = null' "$WF_STATE" > "$TMP" && mv "$TMP" "$WF_STATE"

  _audit "reconcile_result" "d" "$ISSUE"
  exit 1
fi

echo "reconcile-before-resume: found open PR #$PR_NUMBER" >&2

# ---------------------------------------------------------------------------
# Step 4 — Query CI status for the PR's head commit
# ---------------------------------------------------------------------------
_query_ci() {
  # Returns: success | failure | running | unknown
  # Uses explicit jq pipes (not --jq) so test stubs can return raw JSON.
  local checks_json conclusion status_val

  checks_json="$("$GH_CMD" pr checks "$PR_NUMBER" --repo "$REPO" \
    --json name,state,conclusion 2>/dev/null || echo "[]")"

  # "running" when any check has a null conclusion (still in progress).
  status_val="$(printf '%s' "$checks_json" | jq -r '
    if length == 0 then "unknown"
    elif any(.[].conclusion == null) then "running"
    else "done" end' 2>/dev/null || echo "unknown")"

  if [[ "$status_val" == "running" ]]; then
    echo "running"
    return
  fi

  # All checks have concluded — classify the outcome.
  conclusion="$(printf '%s' "$checks_json" | jq -r '
    [.[].conclusion] |
    if length == 0 then "unknown"
    elif any(. == "failure" or . == "cancelled" or . == "timed_out") then "failure"
    elif all(. == "success" or . == "skipped") then "success"
    else "unknown" end' 2>/dev/null || echo "unknown")"

  echo "$conclusion"
}

CI_STATE="$(_query_ci)"
echo "reconcile-before-resume: CI state=$CI_STATE" >&2

# ---------------------------------------------------------------------------
# Branch (a): PR open + CI green → exit 0
# ---------------------------------------------------------------------------
if [[ "$CI_STATE" == "success" ]]; then
  echo "reconcile-before-resume: branch (a) — PR+CI green, resume normally" >&2
  _audit "reconcile_result" "a" "$ISSUE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Branch (b): PR open + CI failure → exit 2
# ---------------------------------------------------------------------------
if [[ "$CI_STATE" == "failure" ]]; then
  echo "reconcile-before-resume: branch (b) — PR+CI failure, resume in fix mode" >&2
  _audit "reconcile_result" "b" "$ISSUE"
  exit 2
fi

# ---------------------------------------------------------------------------
# Branch (c): PR open + CI still running → bounded poll then exit 2
# ---------------------------------------------------------------------------
if [[ "$CI_STATE" == "running" || "$CI_STATE" == "unknown" ]]; then
  echo "reconcile-before-resume: branch (c) — CI in progress, polling up to ${CI_TIMEOUT}s" >&2
  ELAPSED=0
  POLL_INTERVAL=30

  while [[ "$ELAPSED" -lt "$CI_TIMEOUT" ]]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
    CI_STATE="$(_query_ci)"
    echo "reconcile-before-resume: [c] poll at ${ELAPSED}s — CI state=$CI_STATE" >&2

    if [[ "$CI_STATE" == "success" ]]; then
      echo "reconcile-before-resume: branch (c→a) — CI cleared to green during wait" >&2
      _audit "reconcile_result" "a" "$ISSUE"
      exit 0
    elif [[ "$CI_STATE" == "failure" ]]; then
      echo "reconcile-before-resume: branch (c→b) — CI failed during wait" >&2
      _audit "reconcile_result" "b" "$ISSUE"
      exit 2
    fi
  done

  echo "reconcile-before-resume: branch (c) — timeout after ${CI_TIMEOUT}s, degrading to fix mode" >&2
  _audit "reconcile_result" "c" "$ISSUE"
  exit 2
fi

# Fallback: treat any other state as ambiguous → degrade to fix mode (not a hard poison-pill)
echo "reconcile-before-resume: branch (c/fallback) — ambiguous CI state='$CI_STATE', degrading to fix mode" >&2
_audit "reconcile_result" "c" "$ISSUE"
exit 2
