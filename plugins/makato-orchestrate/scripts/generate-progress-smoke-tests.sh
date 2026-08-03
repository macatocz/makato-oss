#!/usr/bin/env bash
# Smoke tests for scripts/generate-progress.sh — repo-wide PROGRESS.md roadmap
# generator (#601). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/generate-progress-smoke-tests.sh
#
# Scenarios:
#   T1: No epics found → all sections empty-placeholder but present in output; exit 0.
#   T2: Single closed epic → appears under ## Done section.
#   T3: Single open epic matching active_workflow.issue → appears under ## In Progress.
#   T4: Open epic not in loop queue → appears under ## Not Started.
#   T5: loop-status.json absent → falls back to gh data alone; still exits 0.
#   T6: gh command unavailable → PROGRESS.md written with warning comment; exits 0.
#
# Fully offline: a local `gh` stub returns predictable JSON from fixtures under
# an injected MAKATO_PROGRESS_GH_OVERRIDE; MAKATO_LOOP_STATE_DIR points at a
# sandboxed state dir. Mirrors generate-run-report-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GP="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-progress.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/progress-smoke-$$"
STATE="$SANDBOX/state"
mkdir -p "$SANDBOX" "$STATE"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export MAKATO_LOOP_STATE_DIR="$STATE"

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------------------------------------------------------------------
# Helper: write a loop-status.json fixture.
# Usage: _write_loop_status <active_issue_or_empty> [<queue_json_array>]
# ---------------------------------------------------------------------------
_write_loop_status() {
  local active="${1:-}"
  local queue="${2:-[]}"
  local active_json="null"
  if [[ -n "$active" ]]; then
    active_json="{\"issue\": $active, \"started_at\": \"2026-08-01T10:00:00.000Z\", \"stalled\": false}"
  fi
  jq -n \
    --argjson aw "$active_json" \
    --argjson q "$queue" \
    '{active_workflow: $aw, queue: $q, updated_at: "2026-08-01T10:00:00.000Z"}' \
    >"$STATE/loop-status.json"
}

# ---------------------------------------------------------------------------
# T1: No epics found — all sections present but show empty-placeholder text
# ---------------------------------------------------------------------------
echo "=== T1: No epics found → all sections empty but present ==="

# gh override: empty array
echo "[]" > "$SANDBOX/t1-epics.json"
OUT="$SANDBOX/t1-progress.md"
export MAKATO_PROGRESS_GH_OVERRIDE="$SANDBOX/t1-epics.json"
export MAKATO_PROGRESS_OUT="$OUT"

_write_loop_status "" "[]"

"$GP" || fail "T1: script should exit 0"
[[ -f "$OUT" ]] || fail "T1: PROGRESS.md not written"
grep -q "## Done" "$OUT"         || fail "T1: ## Done section missing"
grep -q "## In Progress" "$OUT"  || fail "T1: ## In Progress section missing"
grep -q "## Not Started" "$OUT"  || fail "T1: ## Not Started section missing"
# All sections should contain placeholder text (no epic entries)
grep -q "_No closed epics found\._\|_No epics currently in progress\._\|_No open epics outside the loop queue\._" "$OUT" \
  || fail "T1: expected at least one empty-placeholder line"
grep -qE "Last updated:" "$OUT" || fail "T1: footer line missing"
pass "T1: no-epics → all sections present with placeholder text, exit 0"

# ---------------------------------------------------------------------------
# T2: Single closed epic → appears under ## Done
# ---------------------------------------------------------------------------
echo "=== T2: Single closed epic → appears under Done ==="

jq -n '[{number: 42, title: "Epic: Roadmap foundation", state: "CLOSED", closedAt: "2026-07-20T12:00:00Z"}]' \
  > "$SANDBOX/t2-epics.json"
OUT="$SANDBOX/t2-progress.md"
export MAKATO_PROGRESS_GH_OVERRIDE="$SANDBOX/t2-epics.json"
export MAKATO_PROGRESS_OUT="$OUT"

_write_loop_status "" "[]"

"$GP" || fail "T2: script should exit 0"
[[ -f "$OUT" ]] || fail "T2: PROGRESS.md not written"
# The Done section should contain the epic entry.
grep -q "## Done" "$OUT" || fail "T2: ## Done section missing"
grep -q "#42" "$OUT"     || fail "T2: closed epic #42 not found in PROGRESS.md"
grep -q "Epic: Roadmap foundation" "$OUT" || fail "T2: epic title not in PROGRESS.md"
# Verify it is NOT in In Progress or Not Started.
done_section="$(awk '/^## Done/,0' "$OUT")"
printf '%s' "$done_section" | grep -q "#42" || fail "T2: #42 not under ## Done"
pass "T2: closed epic #42 appears under ## Done"

# ---------------------------------------------------------------------------
# T3: Single open epic matching active_workflow.issue → ## In Progress
# ---------------------------------------------------------------------------
echo "=== T3: Open epic matching active_workflow.issue → In Progress ==="

jq -n '[{number: 55, title: "Epic: Auth overhaul", state: "OPEN", closedAt: null}]' \
  > "$SANDBOX/t3-epics.json"
OUT="$SANDBOX/t3-progress.md"
export MAKATO_PROGRESS_GH_OVERRIDE="$SANDBOX/t3-epics.json"
export MAKATO_PROGRESS_OUT="$OUT"

_write_loop_status "55" "[]"

"$GP" || fail "T3: script should exit 0"
[[ -f "$OUT" ]] || fail "T3: PROGRESS.md not written"
grep -q "## In Progress" "$OUT" || fail "T3: ## In Progress section missing"
grep -q "#55" "$OUT"             || fail "T3: open epic #55 not found in PROGRESS.md"
in_progress_section="$(awk '/^## In Progress/{p=1;next} p&&/^## /{p=0} p' "$OUT")"
printf '%s\n' "$in_progress_section" | grep -q "#55" || fail "T3: #55 not under ## In Progress"
pass "T3: epic #55 (active_workflow.issue) appears under ## In Progress"

# ---------------------------------------------------------------------------
# T4: Open epic not in loop queue → ## Not Started
# ---------------------------------------------------------------------------
echo "=== T4: Open epic not in loop queue → Not Started ==="

jq -n '[{number: 99, title: "Epic: Future work", state: "OPEN", closedAt: null}]' \
  > "$SANDBOX/t4-epics.json"
OUT="$SANDBOX/t4-progress.md"
export MAKATO_PROGRESS_GH_OVERRIDE="$SANDBOX/t4-epics.json"
export MAKATO_PROGRESS_OUT="$OUT"

# No active workflow, empty queue
_write_loop_status "" "[]"

"$GP" || fail "T4: script should exit 0"
[[ -f "$OUT" ]] || fail "T4: PROGRESS.md not written"
grep -q "## Not Started" "$OUT" || fail "T4: ## Not Started section missing"
grep -q "#99" "$OUT"             || fail "T4: epic #99 not found in PROGRESS.md"
not_started_section="$(awk '/^## Not Started/{p=1;next} p&&/^## /{p=0} p' "$OUT")"
printf '%s\n' "$not_started_section" | grep -q "#99" || fail "T4: #99 not under ## Not Started"
pass "T4: unqueued open epic #99 appears under ## Not Started"

# ---------------------------------------------------------------------------
# T5: loop-status.json absent → falls back to gh data alone; exits 0
# ---------------------------------------------------------------------------
echo "=== T5: loop-status.json absent → falls back to gh data alone ==="

jq -n '[{number: 77, title: "Epic: Standalone", state: "OPEN", closedAt: null}]' \
  > "$SANDBOX/t5-epics.json"
OUT="$SANDBOX/t5-progress.md"
export MAKATO_PROGRESS_GH_OVERRIDE="$SANDBOX/t5-epics.json"
export MAKATO_PROGRESS_OUT="$OUT"

# Remove loop-status.json — should not exist in a clean state dir.
rm -f "$STATE/loop-status.json"

"$GP" || fail "T5: script should exit 0 when loop-status.json is absent"
[[ -f "$OUT" ]] || fail "T5: PROGRESS.md not written"
grep -q "## Done\|## In Progress\|## Not Started" "$OUT" || fail "T5: sections missing"
# Epic #77 is open and no loop context → falls to Not Started.
grep -q "#77" "$OUT" || fail "T5: epic #77 not in PROGRESS.md"
# Warning comment should appear (no loop-status.json).
grep -q "PROGRESS.md generation warning:" "$OUT" \
  || fail "T5: expected warning comment when loop-status.json is absent"
pass "T5: absent loop-status.json → graceful fallback, warning comment, exit 0"

# ---------------------------------------------------------------------------
# T6: gh command unavailable → PROGRESS.md written with warning; exits 0
# ---------------------------------------------------------------------------
echo "=== T6: gh command unavailable → PROGRESS.md written with warning, exit 0 ==="

OUT="$SANDBOX/t6-progress.md"
# Unset the override so the script uses its real `gh` code path.
unset MAKATO_PROGRESS_GH_OVERRIDE 2>/dev/null || true
export MAKATO_PROGRESS_OUT="$OUT"

# Create a fresh loop-status.json so T5 context is gone.
_write_loop_status "" "[]"

# Shadow gh with a fake binary that exits 1 (simulates gh call failure).
# Keep the rest of PATH intact so bash and other tools remain accessible.
FAKE_BIN="$SANDBOX/fakebin-t6"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\necho "error: gh not available (test stub)" >&2\nexit 1\n' \
  > "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/gh"
OLD_PATH="$PATH"
export PATH="$FAKE_BIN:$OLD_PATH"

# The script must exit 0 even when gh fails.
"$GP" || { export PATH="$OLD_PATH"; fail "T6: script should exit 0 when gh is unavailable"; }
export PATH="$OLD_PATH"

[[ -f "$OUT" ]] || fail "T6: PROGRESS.md not written when gh is unavailable"
# Warning comment must appear.
grep -q "PROGRESS.md generation warning:" "$OUT" \
  || fail "T6: expected warning comment when gh is unavailable"
# All three sections must still be present.
grep -q "## Done"        "$OUT" || fail "T6: ## Done section missing"
grep -q "## In Progress" "$OUT" || fail "T6: ## In Progress section missing"
grep -q "## Not Started" "$OUT" || fail "T6: ## Not Started section missing"
grep -qE "Last updated:" "$OUT" || fail "T6: footer line missing"
pass "T6: gh unavailable → PROGRESS.md written with warning comment, all sections present, exit 0"

echo ""
echo "=== ALL TESTS PASSED (T1–T6 generate-progress, #601) ==="
