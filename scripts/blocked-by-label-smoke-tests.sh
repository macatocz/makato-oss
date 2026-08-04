#!/usr/bin/env bash
# blocked-by-label-smoke-tests.sh — doc-contract assertions for the
# value-bearing blocked-by:N / blocking:N label feature (#608).
#
# All assertions are local grep-based checks; no network calls, no mutations.
# Exits non-zero on first failure.
#
# Usage: scripts/blocked-by-label-smoke-tests.sh
#        (run from the makato repo root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

_pass() { echo "  ✓ $1"; }
_fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# T1: to-issues/SKILL.md contains blocked-by: (new label format)
# ---------------------------------------------------------------------------
echo "=== T1: to-issues SKILL.md uses blocked-by: format ==="
F="$REPO_ROOT/plugins/makato-plan/skills/to-issues/SKILL.md"
grep -q 'blocked-by:' "$F" \
  && _pass "blocked-by: present in to-issues SKILL.md" \
  || _fail "blocked-by: not found in to-issues SKILL.md"

# ---------------------------------------------------------------------------
# T2: to-issues/SKILL.md does NOT contain --add-label "blocked by" (holé removed)
# ---------------------------------------------------------------------------
echo "=== T2: to-issues SKILL.md does NOT contain holé 'blocked by' label ==="
if grep -q '"blocked by"' "$F"; then
  _fail "to-issues SKILL.md still contains holé \"blocked by\" label"
else
  _pass "no holé \"blocked by\" label in to-issues SKILL.md"
fi

# ---------------------------------------------------------------------------
# T3: label-taxonomy.md contains blocked-by:N (new taxonomy doc)
# ---------------------------------------------------------------------------
echo "=== T3: label-taxonomy.md documents blocked-by:N format ==="
F="$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/label-taxonomy.md"
grep -q 'blocked-by:N' "$F" \
  && _pass "blocked-by:N documented in label-taxonomy.md" \
  || _fail "blocked-by:N not found in label-taxonomy.md"

# ---------------------------------------------------------------------------
# T4: label-taxonomy.md contains deprecation notice
# ---------------------------------------------------------------------------
echo "=== T4: label-taxonomy.md contains deprecation notice for holé labels ==="
grep -qi 'deprecated\|deprecation' "$F" \
  && _pass "deprecation notice present in label-taxonomy.md" \
  || _fail "deprecation notice not found in label-taxonomy.md"

# ---------------------------------------------------------------------------
# T5: seed-issue/SKILL.md contains --blocked-by flag
# ---------------------------------------------------------------------------
echo "=== T5: seed-issue SKILL.md documents --blocked-by flag ==="
F="$REPO_ROOT/plugins/makato-orchestrate/skills/seed-issue/SKILL.md"
grep -q -- '--blocked-by' "$F" \
  && _pass "--blocked-by flag documented in seed-issue SKILL.md" \
  || _fail "--blocked-by flag not found in seed-issue SKILL.md"

# ---------------------------------------------------------------------------
# T6: seed-issue/SKILL.md contains retroactive blocking:${ISSUE_NUMBER} patch
# ---------------------------------------------------------------------------
echo "=== T6: seed-issue SKILL.md patches blocking:N onto upstream issues ==="
grep -q 'blocking:' "$F" \
  && _pass "blocking: retroactive patch present in seed-issue SKILL.md" \
  || _fail "blocking: retroactive patch not found in seed-issue SKILL.md"

# ---------------------------------------------------------------------------
# T7: .github/workflows/blocked-by-cleanup.yml exists
# ---------------------------------------------------------------------------
echo "=== T7: blocked-by-cleanup.yml GHA workflow exists ==="
F="$REPO_ROOT/.github/workflows/blocked-by-cleanup.yml"
[ -f "$F" ] \
  && _pass "blocked-by-cleanup.yml exists" \
  || _fail "blocked-by-cleanup.yml not found"

# ---------------------------------------------------------------------------
# T8: blocked-by-cleanup.yml triggers on issues: [closed, reopened]
# ---------------------------------------------------------------------------
echo "=== T8: blocked-by-cleanup.yml triggers on closed and reopened ==="
grep -q 'closed' "$F" && grep -q 'reopened' "$F" \
  && _pass "blocked-by-cleanup.yml triggers on both closed and reopened" \
  || _fail "blocked-by-cleanup.yml missing closed or reopened trigger"

# ---------------------------------------------------------------------------
# T9: blocked-by-cleanup.yml contains status:ready-for-dev promotion path
# ---------------------------------------------------------------------------
echo "=== T9: blocked-by-cleanup.yml promotes fully-unblocked issues ==="
grep -q 'status:ready-for-dev' "$F" \
  && _pass "status:ready-for-dev promotion present in blocked-by-cleanup.yml" \
  || _fail "status:ready-for-dev promotion not found in blocked-by-cleanup.yml"

# ---------------------------------------------------------------------------
# T10: promote-ready.sh contains _reconcile_blocked_by_labels function
# ---------------------------------------------------------------------------
echo "=== T10: promote-ready.sh contains _reconcile_blocked_by_labels function ==="
F="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-ready.sh"
grep -q '_reconcile_blocked_by_labels()' "$F" \
  && _pass "_reconcile_blocked_by_labels function present in promote-ready.sh" \
  || _fail "_reconcile_blocked_by_labels function not found in promote-ready.sh"

# ---------------------------------------------------------------------------
# T11: promote-ready.sh contains blocked-by: pattern (stale label removal)
# ---------------------------------------------------------------------------
echo "=== T11: promote-ready.sh contains blocked-by: pattern ==="
grep -q '"blocked-by:' "$F" \
  && _pass "blocked-by: pattern present in promote-ready.sh" \
  || _fail "blocked-by: pattern not found in promote-ready.sh"

# ---------------------------------------------------------------------------
# T12: scripts/migrate-blocked-by-labels.sh exists
# ---------------------------------------------------------------------------
echo "=== T12: migrate-blocked-by-labels.sh exists ==="
F="$REPO_ROOT/scripts/migrate-blocked-by-labels.sh"
[ -f "$F" ] \
  && _pass "migrate-blocked-by-labels.sh exists" \
  || _fail "migrate-blocked-by-labels.sh not found"

# ---------------------------------------------------------------------------
# T13: migrate-blocked-by-labels.sh supports --dry-run
# ---------------------------------------------------------------------------
echo "=== T13: migrate-blocked-by-labels.sh supports --dry-run ==="
grep -q -- '--dry-run' "$F" \
  && _pass "--dry-run flag present in migrate-blocked-by-labels.sh" \
  || _fail "--dry-run flag not found in migrate-blocked-by-labels.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL BLOCKED-BY-LABEL SMOKE TESTS PASSED (T1–T13) ==="
else
  echo "=== ${FAIL} TEST(S) FAILED ===" >&2
fi
exit "$FAIL"
