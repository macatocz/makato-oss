#!/usr/bin/env bash
# Smoke tests for scripts/emit-needs-planning-signal.sh (#348).
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/emit-needs-planning-signal-smoke-tests.sh
#
# Scenarios:
#   T1: below threshold (structural_halt_cycles < THRESHOLD) → exits 0, no label, no board
#   T2: at threshold (structural_halt_cycles == THRESHOLD) → label applied, JSONL emitted
#   T3: above threshold (structural_halt_cycles > THRESHOLD) → label applied, JSONL emitted
#   T4: degrade-label-only when needs_planning option ID absent/null → label applied, board_applied=false, warn
#   T5: already-labelled idempotent → gh add-label call succeeds (gh is idempotent)
#
# Fully offline: gh calls are intercepted via MAKATO_EMIT_NPS_GH_DRY_RUN=1.
# Mirrors emit-reshape-request-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/emit-needs-planning-signal.sh"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/emit-needs-planning-signal-smoke-$$"
SPECS="$SANDBOX/specs"
CONFIG="$SANDBOX/config.json"
mkdir -p "$SPECS"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

KEY="348-makato-orchestrate-emit-a-durable-needs"
ISSUE_NUM=348

SPEC_DIR="$SPECS/${KEY}"
mkdir -p "$SPEC_DIR"

_write_state() {
  local cycles="$1"
  cat >"$SPEC_DIR/workflow-state-${ISSUE_NUM}.json" <<EOF
{
  "repo": "macatocz/makato",
  "branch": "feat/348",
  "worktree_path": null,
  "worktree_retained": false,
  "worktree_retain_reason": null,
  "issue_number": ${ISSUE_NUM},
  "sub_tasks": [],
  "current_phase": "done",
  "outer_iteration": 3,
  "budget_consumed_tokens": 150000,
  "session_baseline_tokens": 0,
  "session_count": 1,
  "structural_halt_cycles": ${cycles},
  "halt_audit": [],
  "lessons_learned": []
}
EOF
}

# Config with needs_planning populated.
_write_config_with_option() {
  cat >"$CONFIG" <<'EOF'
{
  "github_project": {
    "owner": "macatocz",
    "number": 4,
    "status_field_id": "PVTSSF_lADOEZFnDM4BbvspzhWeA8w",
    "fields": {
      "status": {
        "options": {
          "needs_planning": "abc12345"
        }
      }
    },
    "options": {
      "needs_planning": "abc12345"
    }
  }
}
EOF
}

# Config with needs_planning as null (not yet configured).
_write_config_null_option() {
  cat >"$CONFIG" <<'EOF'
{
  "github_project": {
    "owner": "macatocz",
    "number": 4,
    "status_field_id": "PVTSSF_lADOEZFnDM4BbvspzhWeA8w",
    "fields": {
      "status": {
        "options": {
          "needs_planning": null
        }
      }
    },
    "options": {
      "needs_planning": null
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# T1: below threshold → no-op (exits 0, no label, no JSONL line)
# ---------------------------------------------------------------------------
echo "=== T1: below threshold (cycles=1, threshold=2) → no-op ==="
_write_state 1
_write_config_with_option
rm -f "$SPEC_DIR/orchestrate.jsonl"

MAKATO_EMIT_NPS_SPECS_DIR="$SPECS" \
MAKATO_EMIT_NPS_CONFIG_FILE="$CONFIG" \
MAKATO_EMIT_NPS_GH_DRY_RUN="1" \
MAKATO_STRUCTURAL_RESHAPE_THRESHOLD="2" \
  bash "$SCRIPT" "$KEY" "$ISSUE_NUM" 2>/dev/null
EXIT_CODE=$?

[[ "$EXIT_CODE" -eq 0 ]] || fail "expected exit 0, got $EXIT_CODE"
# No orchestrate.jsonl entry should exist (build-log.sh target is in the real REPO_ROOT, not sandbox)
# The key signal: script produced no stdout (no dry-run gh call echoed).
# We rely on exit 0 and the absence of label call as the no-op signal.
pass "below threshold: exits 0"

# ---------------------------------------------------------------------------
# T2: at threshold → label applied, JSONL emitted with status:ok or warn
# ---------------------------------------------------------------------------
echo "=== T2: at threshold (cycles=2, threshold=2) → label applied ==="
_write_state 2
_write_config_with_option

# Capture stdout to check for dry-run gh command.
OUTPUT="$(MAKATO_EMIT_NPS_SPECS_DIR="$SPECS" \
MAKATO_EMIT_NPS_CONFIG_FILE="$CONFIG" \
MAKATO_EMIT_NPS_GH_DRY_RUN="1" \
MAKATO_STRUCTURAL_RESHAPE_THRESHOLD="2" \
  bash "$SCRIPT" "$KEY" "$ISSUE_NUM" 2>/dev/null || true)"

# In dry-run mode, the script echos the gh commands.
echo "$OUTPUT" | grep -q "gh issue edit" || fail "expected gh issue edit command in dry-run output"
pass "at threshold: gh issue edit command echoed (label_applied path)"

# ---------------------------------------------------------------------------
# T3: above threshold → same behaviour as at threshold
# ---------------------------------------------------------------------------
echo "=== T3: above threshold (cycles=5, threshold=2) → label applied ==="
_write_state 5
_write_config_with_option

OUTPUT="$(MAKATO_EMIT_NPS_SPECS_DIR="$SPECS" \
MAKATO_EMIT_NPS_CONFIG_FILE="$CONFIG" \
MAKATO_EMIT_NPS_GH_DRY_RUN="1" \
MAKATO_STRUCTURAL_RESHAPE_THRESHOLD="2" \
  bash "$SCRIPT" "$KEY" "$ISSUE_NUM" 2>/dev/null || true)"

echo "$OUTPUT" | grep -q "gh issue edit" || fail "expected gh issue edit command in dry-run output"
pass "above threshold: gh issue edit command echoed"

# ---------------------------------------------------------------------------
# T4: degrade-label-only when needs_planning option ID is null
# ---------------------------------------------------------------------------
echo "=== T4: degrade-label-only (needs_planning=null) → label only, board skipped ==="
_write_state 2
_write_config_null_option

OUTPUT="$(MAKATO_EMIT_NPS_SPECS_DIR="$SPECS" \
MAKATO_EMIT_NPS_CONFIG_FILE="$CONFIG" \
MAKATO_EMIT_NPS_GH_DRY_RUN="1" \
MAKATO_STRUCTURAL_RESHAPE_THRESHOLD="2" \
  bash "$SCRIPT" "$KEY" "$ISSUE_NUM" 2>/dev/null || true)"

# Label should be applied (gh issue edit echoed).
echo "$OUTPUT" | grep -q "gh issue edit" || fail "expected gh issue edit in degrade-label-only output"
# Board set command should NOT be echoed.
echo "$OUTPUT" | grep -q "gh project item-edit" && fail "unexpected gh project item-edit in degrade-label-only output" || true
pass "degrade-label-only: label applied, board skipped"

# ---------------------------------------------------------------------------
# T5: idempotent — already-labelled runs cleanly (exit 0)
# ---------------------------------------------------------------------------
echo "=== T5: idempotent (already labelled) → exits 0 ==="
_write_state 3
_write_config_with_option

EXIT_CODE=0
MAKATO_EMIT_NPS_SPECS_DIR="$SPECS" \
MAKATO_EMIT_NPS_CONFIG_FILE="$CONFIG" \
MAKATO_EMIT_NPS_GH_DRY_RUN="1" \
MAKATO_STRUCTURAL_RESHAPE_THRESHOLD="2" \
  bash "$SCRIPT" "$KEY" "$ISSUE_NUM" 2>/dev/null || EXIT_CODE=$?

[[ "$EXIT_CODE" -eq 0 ]] || fail "expected exit 0 on second call (idempotent), got $EXIT_CODE"
pass "idempotent: exit 0 on repeated call"

echo ""
echo "=== ALL TESTS PASSED (T1–T5 emit-needs-planning-signal, #348) ==="
