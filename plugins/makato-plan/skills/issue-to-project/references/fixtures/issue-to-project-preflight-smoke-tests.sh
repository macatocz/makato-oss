#!/usr/bin/env bash
# Smoke tests for issue-to-project Pre-flight check 5 (verify-on-first-call, v2.3.0+).
#
# issue-to-project is a prose skill — its logic lives in SKILL.md +
# references/sync-process.md and is executed by an agent, not a script.
# This file is the *executable spec* for the deterministic core of
# Pre-flight check 5 Step 0.5: it re-implements the two-probe board-ID
# verification logic exactly as the prose describes it, runs it against
# synthetic stub responses, and asserts the acceptance criteria for #606:
#
#   T1. ITP_SKIP_VERIFY=1 → check 5 skipped, WARN logged, exit 0, no gh calls.
#   T2. gh project view returns a project_node_id that does NOT match the
#       cached value → AssertionError → CROSS_REPO_VERIFY_FAILED, exit 1.
#   T3. gh project field-list returns a fields list that does NOT contain the
#       cached status_field_id → AssertionError → CROSS_REPO_VERIFY_FAILED, exit 1.
#   T4. Both IDs are present in the respective probe responses → check 5
#       passes cleanly, exit 0.
#
# If the prose in sync-process.md Step 0.5 changes the algorithm, update this
# reference implementation in lockstep — a drift here means the spec and its
# guard disagree.
#
# Pure bash + python3 stdlib. No real gh, no network, no agent.
set -euo pipefail

pass=0
fail=0

# check <test-name> <expected> <actual>
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  PASS: %s → %s\n' "$name" "$actual"
  else
    fail=$((fail + 1))
    printf '  FAIL: %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual"
  fi
}

echo "== issue-to-project pre-flight check 5 smoke tests (#606) =="

# ---------------------------------------------------------------------------
# Reference implementation of the deterministic core of sync-process.md
# Step 0.5 (Pre-flight check 5 — verify-on-first-call).
#
# preflight_check5(skip_verify, view_ok, view_json, list_ok, list_json,
#                  project_node_id, status_field_id)
#
# Arguments simulate what the real skill does with actual gh calls:
#   skip_verify      — "1" when ITP_SKIP_VERIFY=1, else ""
#   view_ok          — "1" when gh project view exits 0, else "0"
#   view_json        — raw JSON text returned by gh project view
#   list_ok          — "1" when gh project field-list exits 0, else "0"
#   list_json        — raw JSON text returned by gh project field-list
#   project_node_id  — cached PROJECT_NODE_ID from .claude/config.json
#   status_field_id  — cached STATUS_FIELD_ID from .claude/config.json
#
# Emits one line: "exit=<N> halt=<code|none> warn=<line|none>"
# If the prose changes the algorithm, update this block in lockstep.
# ---------------------------------------------------------------------------
run_check5() {
  python3 - "$@" <<'PY'
import json
import sys

(skip_verify, view_ok, view_json,
 list_ok, list_json,
 project_node_id, status_field_id) = sys.argv[1:]

# --- ITP_SKIP_VERIFY bypass (sync-process.md Step 0.5 "Skip conditions") ---
if skip_verify == "1":
    warn = "[issue-to-project] WARN: ITP_SKIP_VERIFY=1 — skipping board ID verification"
    print(f"exit=0 halt=none warn={warn}")
    sys.exit(0)

# --- Probe 1: gh project view → assert project_node_id ---
if view_ok != "1":
    # Bash || branch: probe call itself failed
    print("exit=1 halt=CROSS_REPO_VERIFY_FAILED warn=none")
    sys.exit(0)

try:
    d = json.loads(view_json)
    assert d["id"] == project_node_id, (
        f"issue-to-project: cached project_node_id does not match live board "
        f"({project_node_id!r} vs {d['id']!r}). Re-run 'issue-to-project --init'."
    )
except (AssertionError, KeyError, json.JSONDecodeError):
    print("exit=1 halt=CROSS_REPO_VERIFY_FAILED warn=none")
    sys.exit(0)

# --- Probe 2: gh project field-list → assert status_field_id ---
if list_ok != "1":
    # Bash || branch: field-list call itself failed
    print("exit=1 halt=CROSS_REPO_VERIFY_FAILED warn=none")
    sys.exit(0)

try:
    fnodes = json.loads(list_json).get("fields", [])
    assert any(f.get("id") == status_field_id for f in fnodes), (
        f"issue-to-project: cached status_field_id {status_field_id!r} not found on live board. "
        "Re-run 'issue-to-project --init'."
    )
except (AssertionError, json.JSONDecodeError):
    print("exit=1 halt=CROSS_REPO_VERIFY_FAILED warn=none")
    sys.exit(0)

# --- Both probes passed ---
print("exit=0 halt=none warn=none")
PY
}

# Helpers to extract fields from the "exit=N halt=X warn=Y" output line
# Use POSIX sed — no grep -P (unavailable on macOS BSD grep).
xexit() { echo "$1" | sed 's/exit=\([^ ]*\).*/\1/'; }
xhalt() { echo "$1" | sed 's/.*halt=\([^ ]*\).*/\1/'; }
xwarn() { echo "$1" | sed 's/.*warn=//'; }

# ---------------------------------------------------------------------------
# Fixture values used across tests
# ---------------------------------------------------------------------------
CACHED_NODE_ID="PVT_kwDOAaaaaaBBBB"
CACHED_FIELD_ID="PVTSSF_lADOAaaaaaBBBB_CCCC"

# gh project view response with MATCHING project_node_id
VIEW_OK_JSON='{"id":"PVT_kwDOAaaaaaBBBB","title":"My Board","items":{"totalCount":12}}'

# gh project view response with MISMATCHED project_node_id
VIEW_MISMATCH_JSON='{"id":"PVT_kwDOAAAAAAAAZZZZ","title":"My Board","items":{"totalCount":12}}'

# gh project field-list response that CONTAINS the cached status_field_id
LIST_OK_JSON='{"fields":[{"id":"PVTSSF_lADOAaaaaaBBBB_CCCC","name":"Status","type":"ProjectV2SingleSelectField"},{"id":"PVTF_lADOAaaaaaBBBB_DDDD","name":"Priority","type":"ProjectV2Field"}]}'

# gh project field-list response that does NOT contain the cached status_field_id
LIST_MISSING_JSON='{"fields":[{"id":"PVTF_lADOAaaaaaBBBB_DDDD","name":"Priority","type":"ProjectV2Field"}]}'

# ---------------------------------------------------------------------------
# T1: ITP_SKIP_VERIFY=1 → check 5 skipped entirely, WARN logged, exit 0
# ---------------------------------------------------------------------------
echo ""
echo "T1: ITP_SKIP_VERIFY=1 bypasses check 5"
T1="$(run_check5 "1" "1" "$VIEW_OK_JSON" "1" "$LIST_OK_JSON" "$CACHED_NODE_ID" "$CACHED_FIELD_ID")"
check "T1 exit code is 0"               "0"                         "$(xexit "$T1")"
check "T1 no HALT emitted"              "none"                      "$(xhalt "$T1")"
# The WARN line must contain the skip message
if echo "$T1" | grep -q "ITP_SKIP_VERIFY=1"; then
  check "T1 WARN contains ITP_SKIP_VERIFY=1 message" "present" "present"
else
  check "T1 WARN contains ITP_SKIP_VERIFY=1 message" "present" "absent"
fi

# ---------------------------------------------------------------------------
# T2: project_node_id mismatch → CROSS_REPO_VERIFY_FAILED
# (gh project view returns a different id than the cached one)
# ---------------------------------------------------------------------------
echo ""
echo "T2: project_node_id mismatch triggers CROSS_REPO_VERIFY_FAILED"
T2="$(run_check5 "" "1" "$VIEW_MISMATCH_JSON" "1" "$LIST_OK_JSON" "$CACHED_NODE_ID" "$CACHED_FIELD_ID")"
check "T2 exit code is 1"               "1"                         "$(xexit "$T2")"
check "T2 HALT is CROSS_REPO_VERIFY_FAILED" "CROSS_REPO_VERIFY_FAILED" "$(xhalt "$T2")"

# ---------------------------------------------------------------------------
# T3: status_field_id absent from field-list → CROSS_REPO_VERIFY_FAILED
# (project_node_id is correct, but the field-list does not contain the field)
# ---------------------------------------------------------------------------
echo ""
echo "T3: status_field_id absent from field-list triggers CROSS_REPO_VERIFY_FAILED"
T3="$(run_check5 "" "1" "$VIEW_OK_JSON" "1" "$LIST_MISSING_JSON" "$CACHED_NODE_ID" "$CACHED_FIELD_ID")"
check "T3 exit code is 1"               "1"                         "$(xexit "$T3")"
check "T3 HALT is CROSS_REPO_VERIFY_FAILED" "CROSS_REPO_VERIFY_FAILED" "$(xhalt "$T3")"

# ---------------------------------------------------------------------------
# T4: both IDs valid → check 5 passes, exit 0
# ---------------------------------------------------------------------------
echo ""
echo "T4: both IDs valid — check 5 passes"
T4="$(run_check5 "" "1" "$VIEW_OK_JSON" "1" "$LIST_OK_JSON" "$CACHED_NODE_ID" "$CACHED_FIELD_ID")"
check "T4 exit code is 0"               "0"                         "$(xexit "$T4")"
check "T4 no HALT emitted"              "none"                      "$(xhalt "$T4")"
check "T4 no WARN emitted"              "none"                      "$(xwarn "$T4")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "issue-to-project pre-flight check 5 smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
