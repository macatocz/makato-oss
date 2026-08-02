#!/usr/bin/env bash
# Smoke tests for scripts/sync-living-specs.sh (living-spec delta sync).
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/sync-living-specs-smoke-tests.sh
#
# Scenarios:
#   T1: missing args exits 1
#   T2: missing spec-delta.md exits 1
#   T3: ADDED requirement appended to existing docs/specs/ file
#   T4: MODIFIED requirement replaces matching heading; other sections untouched
#   T5: REMOVED requirement replaced with tombstone comment
#   T6: dangling MODIFIED ref emits WARN but does not fail (exit 0, target unchanged)
#
# Fully offline: all inputs written to a temp sandbox.
# Mirrors mark-ac-checkboxes-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/sync-living-specs.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/sync-living-specs-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ── T1: missing args exits 1 ─────────────────────────────────────────────────
echo "=== T1: missing args exits 1 ==="
if "$SCRIPT" 2>/dev/null; then
  fail "T1: expected non-zero exit on missing args"
fi
pass "T1: missing args rejected"

# ── T2: missing spec-delta.md exits 1 ────────────────────────────────────────
echo "=== T2: missing spec-delta.md exits 1 ==="
if "$SCRIPT" "$SANDBOX/nonexistent/spec-delta.md" "$SANDBOX/docs/specs" 2>/dev/null; then
  fail "T2: expected non-zero exit on missing spec-delta file"
fi
pass "T2: missing spec-delta file rejected"

# ── Setup shared capability dir ──────────────────────────────────────────────
CAP="test-cap"
mkdir -p "$SANDBOX/$CAP" "$SANDBOX/docs/specs"

# Helper: reset the target file to a known state before each test
reset_target() {
  cat > "$SANDBOX/docs/specs/$CAP.md" << 'MDEOF'
# Test Capability Spec

### Existing Heading

**SHALL**: This section was always here.

### Bar Requirement

**SHALL**: The original bar behaviour.
MDEOF
}

# ── T3: ADDED requirement appended to existing file ──────────────────────────
echo "=== T3: ADDED requirement appended to existing file ==="
reset_target
cat > "$SANDBOX/$CAP/spec-delta.md" << 'SDEOF'
## ADDED Requirements

### New Feature

**SHALL**: The system SHALL support the new feature.
SDEOF

"$SCRIPT" "$SANDBOX/$CAP/spec-delta.md" "$SANDBOX/docs/specs" 2>/dev/null \
  || fail "T3: script exited non-zero"

grep -q "### New Feature" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T3: ADDED heading not found in output"
grep -q "SHALL.*new feature" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T3: ADDED body not found in output"
grep -q "Existing Heading" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T3: pre-existing section was lost"
pass "T3: ADDED requirement appended; pre-existing section preserved"

# ── T4: MODIFIED requirement replaces matching heading ────────────────────────
echo "=== T4: MODIFIED replaces matching heading; others untouched ==="
reset_target
cat > "$SANDBOX/$CAP/spec-delta.md" << 'SDEOF'
## MODIFIED Requirements

### Bar Requirement

**SHALL**: The bar behaviour is now updated.
SDEOF

"$SCRIPT" "$SANDBOX/$CAP/spec-delta.md" "$SANDBOX/docs/specs" 2>/dev/null \
  || fail "T4: script exited non-zero"

grep -q "now updated" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T4: MODIFIED body not found in output"
grep -q "original bar" "$SANDBOX/docs/specs/$CAP.md" \
  && fail "T4: old MODIFIED text still present" || true
grep -q "Existing Heading" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T4: unrelated section was lost"
pass "T4: MODIFIED requirement replaced; unrelated section preserved"

# ── T5: REMOVED requirement replaced with tombstone ──────────────────────────
echo "=== T5: REMOVED requirement replaced with tombstone comment ==="
reset_target
cat > "$SANDBOX/$CAP/spec-delta.md" << 'SDEOF'
## REMOVED Requirements

### Existing Heading

**SHALL**: no longer apply.
SDEOF

"$SCRIPT" "$SANDBOX/$CAP/spec-delta.md" "$SANDBOX/docs/specs" 2>/dev/null \
  || fail "T5: script exited non-zero"

grep -q "<!-- REMOVED: Existing Heading -->" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T5: tombstone comment not found"
grep -q "was always here" "$SANDBOX/docs/specs/$CAP.md" \
  && fail "T5: REMOVED body still present after tombstone replacement" || true
grep -q "Bar Requirement" "$SANDBOX/docs/specs/$CAP.md" \
  || fail "T5: unrelated section was lost"
pass "T5: REMOVED section replaced with tombstone; other sections preserved"

# ── T6: dangling MODIFIED ref emits WARN, exits 0, target unchanged ───────────
echo "=== T6: dangling MODIFIED ref emits WARN but does not fail ==="
reset_target
BEFORE="$(cat "$SANDBOX/docs/specs/$CAP.md")"
cat > "$SANDBOX/$CAP/spec-delta.md" << 'SDEOF'
## MODIFIED Requirements

### No Such Heading In Target

**SHALL**: This requirement has no match.
SDEOF

WARN_OUT="$("$SCRIPT" "$SANDBOX/$CAP/spec-delta.md" "$SANDBOX/docs/specs" 2>&1)" \
  || fail "T6: script exited non-zero on dangling MODIFIED"

echo "$WARN_OUT" | grep -qi "WARN" \
  || fail "T6: no WARN emitted on stderr for dangling MODIFIED"

AFTER="$(cat "$SANDBOX/docs/specs/$CAP.md")"
[ "$BEFORE" = "$AFTER" ] \
  || fail "T6: target file was modified on dangling MODIFIED (should be unchanged)"

pass "T6: dangling MODIFIED emits WARN, exits 0, target file unchanged"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "All sync-living-specs smoke tests passed."
