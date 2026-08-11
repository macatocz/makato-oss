#!/usr/bin/env bash
# test-sagibeast-seed.sh — Unit tests for sagibeast-seed.sh that do not
# require a live PostgreSQL connection.
#
# Technique: override `psql` with a mock function for the connectivity
# and row-count calls; the SQL heredoc is discarded.
#
# Usage:  bash fixtures/test-sagibeast-seed.sh
# Exit codes:  0 all tests passed, 1 any test failed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_SCRIPT="$SCRIPT_DIR/sagibeast-seed.sh"
PASS=0
FAIL=0

run_test() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# ── Test: script exists and is executable ────────────────────────────────────
echo "Task 2 — sagibeast-seed.sh structure tests"
run_test "seed script exists"           test -f "$SEED_SCRIPT"
run_test "seed script is executable"    test -x "$SEED_SCRIPT"
run_test "bash syntax check"            bash -n "$SEED_SCRIPT"

# ── Test: defaults to fallback DB URL ────────────────────────────────────────
run_test "default DB_URL fallback in script" \
    grep -q 'postgresql://localhost:5432/sagibeast_dev' "$SEED_SCRIPT"

# ── Test: SAGIBEAST_DB_URL env var is honoured ───────────────────────────────
run_test "reads SAGIBEAST_DB_URL env var" \
    grep -q 'SAGIBEAST_DB_URL:-' "$SEED_SCRIPT"

# ── Test: exits non-zero when psql cannot connect ────────────────────────────
psql() {
    # Simulate connection failure
    return 1
}
export -f psql
exit_code=0
env -i PATH="$PATH" HOME="$HOME" SAGIBEAST_DB_URL="postgresql://localhost:5432/noexist" \
    bash "$SEED_SCRIPT" >/dev/null 2>&1 || exit_code=$?
unset -f psql
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero on connection failure"
    PASS=$((PASS + 1))
else
    echo "  FAIL: should exit non-zero on connection failure"
    FAIL=$((FAIL + 1))
fi

# ── Test: JSONL audit entries in seed script ─────────────────────────────────
run_test "emits start JSONL entry"  grep -q 'emit_jsonl "start"' "$SEED_SCRIPT"
run_test "emits ok JSONL entry"     grep -q 'emit_jsonl "ok"'    "$SEED_SCRIPT"
run_test "emits error JSONL entry"  grep -q 'emit_jsonl "error"' "$SEED_SCRIPT"

# ── Test: idempotent pattern present ─────────────────────────────────────────
run_test "DROP TABLE IF EXISTS present (idempotent)"  \
    grep -q 'DROP TABLE IF EXISTS' "$SEED_SCRIPT"
run_test "sagibeast_e2e_fixtures table created"        \
    grep -q 'sagibeast_e2e_fixtures' "$SEED_SCRIPT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
