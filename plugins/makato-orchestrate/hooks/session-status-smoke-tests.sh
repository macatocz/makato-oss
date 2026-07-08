#!/usr/bin/env bash
# Smoke tests for session-status.sh (GAP-014 / #31). Run from the makato repo root.
# Exits non-zero on first failure. Cleans up its sandbox on success.
#
# Usage: plugins/makato-orchestrate/hooks/session-status-smoke-tests.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/makato-orchestrate/hooks/session-status.sh"
SANDBOX="$(mktemp -d)"
SPECS="$SANDBOX/specs"
HALT_NONE="$SANDBOX/.no-halt"
HALT_PRESENT="$SANDBOX/HALT"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

mkdir -p "$SPECS"

# ---------------------------------------------------------------------------
# Helper — write a workflow-state.json into a fresh spec directory.
# Usage: _make_state <spec-dir-name> <updated_at> [overrides-jq-filter]
# ---------------------------------------------------------------------------
_make_state() {
  local name="$1"
  local updated_at="$2"
  local overrides="${3:-.}"
  local dir="$SPECS/$name"
  mkdir -p "$dir"
  local issue
  # Derive issue number from leading digits in the spec name; default 99.
  if [[ "$name" =~ ^([0-9]+) ]]; then
    issue="${BASH_REMATCH[1]}"
  else
    issue=99
  fi
  jq -n --arg ts "$updated_at" --argjson issue "$issue" '{
    repo: "macatocz/test",
    branch: "feat/test",
    worktree_path: null,
    worktree_retained: false,
    worktree_retain_reason: null,
    issue_number: $issue,
    sub_tasks: [],
    current_phase: "implement",
    resume_point: null,
    budget_consumed_tokens: 10000,
    budget_limit_tokens: 50000,
    context_warn_tokens: 40000,
    outer_iteration: 1,
    halt_audit: [],
    human_review_cycles: 0,
    github_pr_number: null,
    lessons_learned: [],
    session_summary: null,
    session_count: 0,
    handoff_reason: null,
    restart_failed: false,
    created_at: $ts,
    updated_at: $ts
  } | '"$overrides" > "$dir/workflow-state-${issue}.json"
}

# Run the hook with the sandbox specs root. Halt file path is parameter $1.
_run_hook() {
  local halt_file="${1:-$HALT_NONE}"
  MAKATO_SPECS_ROOT="$SPECS" MAKATO_HALT_FILE="$halt_file" "$HOOK"
}

# ---------------------------------------------------------------------------
# T1 — No state files → "No active workflows", exit 0.
# ---------------------------------------------------------------------------
echo "=== T1: no state files prints 'No active workflows' ==="
out="$(_run_hook)"
[[ "$out" == *"No active workflows"* ]] || { echo "  ✗ FAIL: missing line"; exit 1; }
echo "  ✓ no-active line emitted"

# ---------------------------------------------------------------------------
# T2 — One active workflow → core banner fields.
# ---------------------------------------------------------------------------
echo "=== T2: one active workflow prints banner with phase / budget / timestamp ==="
NOW="$(python3 -c "from datetime import datetime,timezone; n=datetime.now(timezone.utc); print(n.strftime('%Y-%m-%dT%H:%M:%S.')+f'{n.microsecond//1000:03d}Z')")"
_make_state "31-active" "$NOW"
out="$(_run_hook)"
[[ "$out" == *"#31"* ]] || { echo "  ✗ FAIL: issue number"; exit 1; }
[[ "$out" == *"phase: implement"* ]] || { echo "  ✗ FAIL: phase"; exit 1; }
[[ "$out" == *"10000/50000"* ]] || { echo "  ✗ FAIL: budget"; exit 1; }
[[ "$out" == *"(20%)"* ]] || { echo "  ✗ FAIL: pct"; exit 1; }
[[ "$out" == *"halts: 0"* ]] || { echo "  ✗ FAIL: halt count"; exit 1; }
echo "  ✓ banner has issue / phase / budget / pct / halt count"

# ---------------------------------------------------------------------------
# T3 — Stale workflow (updated 25h ago) → STALE marker.
# ---------------------------------------------------------------------------
echo "=== T3: stale workflow gets STALE marker and resume hint ==="
OLD_TS="$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(hours=25)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")"
rm -rf "$SPECS/31-active"
_make_state "42-stale" "$OLD_TS"
out="$(_run_hook)"
[[ "$out" == *"STALE"* ]] || { echo "  ✗ FAIL: missing STALE"; exit 1; }
[[ "$out" == *"/loop --autonomous 42"* ]] || { echo "  ✗ FAIL: missing resume hint"; exit 1; }
echo "  ✓ STALE warning + resume hint"

# ---------------------------------------------------------------------------
# T4 — HALT file present → prominent global banner BEFORE workflow list.
# ---------------------------------------------------------------------------
echo "=== T4: HALT file present prints HALT ACTIVE banner first ==="
touch "$HALT_PRESENT"
out="$(_run_hook "$HALT_PRESENT")"
[[ "$out" == *"HALT ACTIVE"* ]] || { echo "  ✗ FAIL: missing HALT banner"; exit 1; }
# Banner appears before "Active workflows:" header.
halt_line_no="$(printf '%s\n' "$out" | grep -n "HALT ACTIVE" | head -1 | cut -d: -f1)"
list_line_no="$(printf '%s\n' "$out" | grep -n "Active workflows:" | head -1 | cut -d: -f1)"
[[ -n "$halt_line_no" && -n "$list_line_no" ]] && [[ "$halt_line_no" -lt "$list_line_no" ]] \
  || { echo "  ✗ FAIL: HALT banner not before workflow list"; exit 1; }
echo "  ✓ HALT ACTIVE banner appears before workflow list"
rm "$HALT_PRESENT"

# ---------------------------------------------------------------------------
# T5 — halt_audit non-empty → per-line HALT: <code>.
# ---------------------------------------------------------------------------
echo "=== T5: halt_audit entries surface last HALT code on the banner line ==="
rm -rf "$SPECS/42-stale"
_make_state "55-halted" "$NOW" '.halt_audit = [{"code":"HALT-008","ts":"2026-06-29T10:30:00.000Z","data":{}}]'
out="$(_run_hook)"
[[ "$out" == *"HALT: HALT-008"* ]] || { echo "  ✗ FAIL: missing per-line HALT code"; exit 1; }
[[ "$out" == *"halts: 1"* ]] || { echo "  ✗ FAIL: halt count not 1"; exit 1; }
echo "  ✓ halt code surfaced"

# ---------------------------------------------------------------------------
# T6 — budget_limit_tokens = 0 → ?% instead of divide-by-zero / crash.
# ---------------------------------------------------------------------------
echo "=== T6: zero budget limit shows ?% (no divide-by-zero) ==="
rm -rf "$SPECS/55-halted"
_make_state "60-nobudget" "$NOW" '.budget_limit_tokens = 0'
out="$(_run_hook)"
[[ "$out" == *"(?%)"* ]] || { echo "  ✗ FAIL: missing ?% guard"; exit 1; }
echo "  ✓ zero limit shows ?%"

# ---------------------------------------------------------------------------
# T7 — Multiple workflows → all surface in output.
# ---------------------------------------------------------------------------
echo "=== T7: multiple workflows all appear in output ==="
rm -rf "$SPECS/60-nobudget"
_make_state "70-first" "$NOW"
_make_state "71-second" "$NOW"
_make_state "72-third" "$NOW"
out="$(_run_hook)"
[[ "$out" == *"#70"* ]] || { echo "  ✗ FAIL: #70 missing"; exit 1; }
[[ "$out" == *"#71"* ]] || { echo "  ✗ FAIL: #71 missing"; exit 1; }
[[ "$out" == *"#72"* ]] || { echo "  ✗ FAIL: #72 missing"; exit 1; }
echo "  ✓ all three workflows listed"

# ---------------------------------------------------------------------------
# T8 — Disable env var short-circuits.
# ---------------------------------------------------------------------------
echo "=== T8: MAKATO_DISABLE_SESSION_STATUS=1 exits silently ==="
out="$(MAKATO_DISABLE_SESSION_STATUS=1 MAKATO_SPECS_ROOT="$SPECS" MAKATO_HALT_FILE="$HALT_NONE" "$HOOK")"
[[ -z "$out" ]] || { echo "  ✗ FAIL: expected empty output, got: $out"; exit 1; }
echo "  ✓ disabled hook emits no banner"

# ---------------------------------------------------------------------------
# T9 — Non-numeric budget fields render as ?% and hook exits 0.
# ---------------------------------------------------------------------------
echo "=== T9: non-numeric budget fields show ?% and exit 0 ==="
rm -rf "$SPECS"/70-* "$SPECS"/71-* "$SPECS"/72-*
_make_state "98-badbudget" "$NOW" '.budget_consumed_tokens = "bad" | .budget_limit_tokens = "also-bad"'
out="$(_run_hook)"
[[ "$out" == *"(?%)"* ]] || { echo "  ✗ FAIL: expected ?% for non-numeric budget"; exit 1; }
echo "  ✓ non-numeric budget shown as ?% without crash"

# ---------------------------------------------------------------------------
# T10 — po-agent Step 6a contains gh pr checks polling
# ---------------------------------------------------------------------------
echo "=== T10: po-agent Step 6a contains gh pr checks polling ==="
grep -q 'gh pr checks' plugins/makato-orchestrate/agents/po-agent.md   || { echo "  ✗ FAIL: Step 6a CI polling command missing"; exit 1; }
echo "  ✓ Step 6a CI polling command present"

# ---------------------------------------------------------------------------
# T11 — po-agent Step 6a contains gh run view --log-failed
# ---------------------------------------------------------------------------
echo "=== T11: po-agent Step 6a contains gh run view --log-failed ==="
grep -q 'gh run view --log-failed' plugins/makato-orchestrate/agents/po-agent.md   || { echo "  ✗ FAIL: Step 6a CI log fetch command missing"; exit 1; }
echo "  ✓ Step 6a CI log fetch command present"

# ---------------------------------------------------------------------------
# T12 — po-agent Step 6b contains gh pr view --json reviewDecision
# ---------------------------------------------------------------------------
echo "=== T12: po-agent Step 6b contains gh pr view --json reviewDecision ==="
grep -q 'reviewDecision' plugins/makato-orchestrate/agents/po-agent.md   || { echo "  ✗ FAIL: Step 6b review-decision polling missing"; exit 1; }
echo "  ✓ Step 6b review-decision polling present"

# ---------------------------------------------------------------------------
# T13 — po-agent label matrix contains HALT-010
# ---------------------------------------------------------------------------
echo "=== T13: po-agent label matrix contains HALT-010 ==="
grep -q 'HALT-010' plugins/makato-orchestrate/agents/po-agent.md   || { echo "  ✗ FAIL: HALT-010 missing from po-agent"; exit 1; }
echo "  ✓ HALT-010 present in label matrix"

echo ""
echo "All 13 session-status smoke tests passed."
