#!/usr/bin/env bash
# emit-needs-planning-signal.sh — emit the Needs Planning reshape signal when
# structural_halt_cycles reaches the configured threshold (#348).
#
# Usage:
#   emit-needs-planning-signal.sh <KEY> <ISSUE_NUMBER>
#
#   KEY          composite key (e.g. "348-makato-orchestrate-emit-a-durable-needs")
#   ISSUE_NUMBER GitHub issue number (e.g. 348)
#
# What it does:
#   1. Reads structural_halt_cycles from workflow-state-<ISSUE_NUMBER>.json.
#   2. Compares to MAKATO_STRUCTURAL_RESHAPE_THRESHOLD (default 2).
#   3. Below threshold: exits 0, no-op.
#   4. At/above threshold:
#      a) Applies `needs-reshape` label via `gh issue edit --add-label`.
#         Creates the label with colour #0075ca if absent.
#      b) Attempts to set board Status to Needs Planning via `gh project item-edit`
#         using the `needs_planning` option ID from .claude/config.json.
#         Degrades gracefully to label-only when the option ID is absent or null
#         or when the `gh` call fails.
#      c) Emits a JSONL entry to orchestrate.jsonl via build-log.sh.
#
# Test hooks (all optional):
#   MAKATO_EMIT_NPS_SPECS_DIR    override specs/ root (tests)
#   MAKATO_EMIT_NPS_CONFIG_FILE  override .claude/config.json path (tests)
#   MAKATO_EMIT_NPS_GH_DRY_RUN  if set to "1", skip actual gh calls and echo
#                                 commands to stdout instead (tests)
#   MAKATO_EMIT_NPS_GH_ITEM_ID          when SET (even to empty string),
#                                         _get_item_id returns this value instead
#                                         of calling gh project item-list (tests)
#   MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT  when set in dry-run, item-add returns
#                                         this ID instead of calling gh (tests)
#   MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL    when "1" in dry-run, item-add returns
#                                         empty (simulates gh failure) (tests)
#
# Exit codes:
#   0  success or no-op (below threshold, board/label soft failures are WARN)
#   1  unrecoverable input error (missing KEY or ISSUE_NUMBER, invalid integer)
set -euo pipefail

KEY="${1:?key required (e.g. 348-makato-orchestrate-emit-a-durable-needs)}"
ISSUE_NUMBER="${2:?issue_number required (e.g. 348)}"

# ---------------------------------------------------------------------------
# Validate ISSUE_NUMBER is a positive integer.
# ---------------------------------------------------------------------------
if [[ ! "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "emit-needs-planning-signal: ISSUE_NUMBER must be a positive integer (got '$ISSUE_NUMBER')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve repo root via --git-common-dir so the script works from a worktree.
# ---------------------------------------------------------------------------
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

SPECS_DIR="${MAKATO_EMIT_NPS_SPECS_DIR:-$REPO_ROOT/specs}"
CONFIG_FILE="${MAKATO_EMIT_NPS_CONFIG_FILE:-$REPO_ROOT/.claude/config.json}"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
BUILD_LOG="$REPO_ROOT/plugins/makato-build/shared/build-log.sh"
THRESHOLD="${MAKATO_STRUCTURAL_RESHAPE_THRESHOLD:-2}"

# ---------------------------------------------------------------------------
# Resolve spec folder: find specs/<KEY>-*/ then fall back to specs/<KEY>/.
# ---------------------------------------------------------------------------
SPEC_FOLDER=""
if [[ -d "$SPECS_DIR" ]]; then
  SPEC_FOLDER="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${KEY}-*" | head -1)"
fi
if [[ -z "$SPEC_FOLDER" ]] && [[ -d "$SPECS_DIR/$KEY" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi
if [[ -z "$SPEC_FOLDER" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC).
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Read workflow-state.
# ---------------------------------------------------------------------------
STATE_FILE="$SPEC_FOLDER/workflow-state-${ISSUE_NUMBER}.json"
if [[ -f "$STATE_FILE" ]]; then
  STATE_JSON="$(cat "$STATE_FILE")"
else
  STATE_JSON="$("$WS" read "$KEY" "$ISSUE_NUMBER" 2>/dev/null)"
fi
if [[ "$STATE_JSON" == "{}" ]] || [[ -z "$STATE_JSON" ]]; then
  echo "emit-needs-planning-signal: workflow-state-${ISSUE_NUMBER}.json not found for KEY=$KEY" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read structural_halt_cycles from state. Default to 0 if absent.
# ---------------------------------------------------------------------------
STRUCTURAL_HALT_CYCLES="$(echo "$STATE_JSON" | jq '.structural_halt_cycles // 0')"

# ---------------------------------------------------------------------------
# Threshold check: exit 0 (no-op) when below threshold.
# ---------------------------------------------------------------------------
if [[ "$STRUCTURAL_HALT_CYCLES" -lt "$THRESHOLD" ]]; then
  # Below threshold — no signal emitted.
  exit 0
fi

# ---------------------------------------------------------------------------
# At or above threshold — emit the Needs Planning signal.
# ---------------------------------------------------------------------------

# Read REPO from workflow state.
REPO="$(echo "$STATE_JSON" | jq -r '.repo // empty')"

LABEL_APPLIED=false
BOARD_APPLIED=false
WARN_REASON=""

# ---------------------------------------------------------------------------
# (a) Apply needs-reshape label via gh issue edit.
#     Create the label with #0075ca if absent (idempotent).
# ---------------------------------------------------------------------------
_apply_label() {
  if [[ "${MAKATO_EMIT_NPS_GH_DRY_RUN:-0}" == "1" ]]; then
    echo "gh issue edit $ISSUE_NUMBER --repo $REPO --add-label needs-reshape"
    return 0
  fi

  if [[ -z "$REPO" ]]; then
    return 1
  fi

  # Ensure label exists (creates with colour if absent; ignores 422 already-exists).
  gh label create needs-reshape \
    --repo "$REPO" \
    --color "0075ca" \
    --description "Issue has hit the structural-HALT recurrence threshold; needs planning pass" \
    2>/dev/null || true

  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label needs-reshape 2>/dev/null
}

if _apply_label; then
  LABEL_APPLIED=true
else
  WARN_REASON="label-apply-failed"
fi

# ---------------------------------------------------------------------------
# (b) Attempt to set board Status to Needs Planning.
#     Reads needs_planning option ID from .claude/config.json.
#     Degrades gracefully when the ID is absent, null, or the call fails.
# ---------------------------------------------------------------------------
NEEDS_PLANNING_OPTION_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
  # Try both config locations where the option ID may live.
  NEEDS_PLANNING_OPTION_ID="$(jq -r '
    (.github_project.fields.status.options.needs_planning // empty),
    (.github_project.options.needs_planning // empty)
    | select(. != null and . != "null" and . != "")
    | . ' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"
fi

if [[ -n "$NEEDS_PLANNING_OPTION_ID" ]] && [[ "$NEEDS_PLANNING_OPTION_ID" != "null" ]]; then
  # Resolve board metadata from config.
  PROJECT_OWNER="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE" 2>/dev/null || true)"
  PROJECT_NUMBER="$(jq -r '.github_project.number // empty' "$CONFIG_FILE" 2>/dev/null || true)"
  STATUS_FIELD_ID="$(jq -r '.github_project.status_field_id // .github_project.fields.status.id // empty' "$CONFIG_FILE" 2>/dev/null || true)"

  if [[ -n "$PROJECT_OWNER" ]] && [[ -n "$PROJECT_NUMBER" ]] && [[ -n "$STATUS_FIELD_ID" ]]; then
    # Resolve the board item ID for the linked issue.
    _get_item_id() {
      if [[ -n "${MAKATO_EMIT_NPS_GH_ITEM_ID+x}" ]]; then
        echo "${MAKATO_EMIT_NPS_GH_ITEM_ID}"
        return 0
      fi
      gh project item-list "$PROJECT_NUMBER" \
        --owner "$PROJECT_OWNER" \
        --format json \
        --jq ".items[] | select(.content.number == $ISSUE_NUMBER) | .id" \
        2>/dev/null | head -1 || true
    }

    ITEM_ID="$(_get_item_id)"

    if [[ -z "$ITEM_ID" ]] && [[ -n "$REPO" ]]; then
      # Issue absent from board — attempt idempotent item-add (mirrors _promote_labelled_ready pattern).
      if [[ "${MAKATO_EMIT_NPS_GH_DRY_RUN:-0}" == "1" ]]; then
        if [[ "${MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL:-0}" == "1" ]]; then
          ITEM_ID=""
        elif [[ -n "${MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT:-}" ]]; then
          ITEM_ID="$MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT"
          echo "gh project item-add $PROJECT_NUMBER --owner $PROJECT_OWNER --url https://github.com/$REPO/issues/$ISSUE_NUMBER"
        fi
      else
        ITEM_ID="$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
          --url "https://github.com/$REPO/issues/$ISSUE_NUMBER" \
          --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
      fi
    fi

    if [[ -n "$ITEM_ID" ]]; then
      _set_board_status() {
        if [[ "${MAKATO_EMIT_NPS_GH_DRY_RUN:-0}" == "1" ]]; then
          echo "gh project item-edit --id $ITEM_ID --project-id $PROJECT_NUMBER --owner $PROJECT_OWNER --field-id $STATUS_FIELD_ID --single-select-option-id $NEEDS_PLANNING_OPTION_ID"
          return 0
        fi
        gh project item-edit \
          --id "$ITEM_ID" \
          --project-id "$PROJECT_NUMBER" \
          --owner "$PROJECT_OWNER" \
          --field-id "$STATUS_FIELD_ID" \
          --single-select-option-id "$NEEDS_PLANNING_OPTION_ID" \
          2>/dev/null
      }

      if _set_board_status; then
        BOARD_APPLIED=true
      else
        WARN_REASON="${WARN_REASON:+$WARN_REASON,}board-status-failed"
      fi
    else
      WARN_REASON="${WARN_REASON:+$WARN_REASON,}board-item-not-found"
    fi
  else
    WARN_REASON="${WARN_REASON:+$WARN_REASON,}board-config-incomplete"
  fi
else
  # needs_planning option ID not yet populated — degrade to label-only.
  WARN_REASON="${WARN_REASON:+$WARN_REASON,}needs-planning-option-id-absent"
fi

# ---------------------------------------------------------------------------
# (c) Emit JSONL entry to orchestrate.jsonl via build-log.sh.
# ---------------------------------------------------------------------------
EMIT_STATUS="ok"
if [[ -n "$WARN_REASON" ]]; then
  EMIT_STATUS="warn"
fi

TS="$(_now)"
JSONL_ENTRY="$(printf '{"ts":"%s","skill":"emit-needs-planning-signal","story":"%s","step":"emit-needs-planning","status":"%s","data":{"structural_halt_cycles":%d,"threshold":%d,"label_applied":%s,"board_applied":%s,"warn_reason":"%s"}}' \
  "$TS" \
  "$KEY" \
  "$EMIT_STATUS" \
  "$STRUCTURAL_HALT_CYCLES" \
  "$THRESHOLD" \
  "$LABEL_APPLIED" \
  "$BOARD_APPLIED" \
  "$WARN_REASON")"

if [[ -x "$BUILD_LOG" ]]; then
  "$BUILD_LOG" "$KEY" "$JSONL_ENTRY" 2>/dev/null || true
fi

# Always exit 0 — board/label failures are WARN only; the PO-agent must not
# block termination on a best-effort signal.
exit 0
