#!/usr/bin/env bash
# Smoke tests for scripts/archive-spec.sh — the deterministic post-merge spec
# archival port (#221). Fully offline: `gh` is never invoked. Issue body/state
# and gh mutations are injected via the script's test hooks.
#
# Usage:
#   plugins/makato-orchestrate/scripts/archive-spec-smoke-tests.sh
#
# Scenarios:
#   T1: derive slug from to-issues footer, archive folder, close issue
#   T2: derive slug from stories.json fallback when footer absent
#   T3: no provenance in body → close issue, no folder move (tolerated)
#   T4: slug present but no matching specs/<slug>-*/ folder → close, no move
#   T5: already-closed issue → close step is an idempotent skip
#   T6: missing issue number → exit 2 (usage error)
#   T7: epic collision — two folders share a slug, disambiguate by issue number
#   T8: Evolution Log row appended to an existing master spec
#   T9: master spec created from template when absent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$SCRIPT_DIR/archive-spec.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  ✗ $1"; echo "      $2"; }

# Each test gets a fresh sandbox specs/ root + fresh gh/body override files.
new_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/specs/master" "$d/specs/archive"
  printf '%s\n' "$d"
}

# Common env for a run against a sandbox.
run_archive() {
  local sandbox="$1"; shift
  MAKATO_ARCHIVE_SPECS_ROOT="$sandbox/specs" \
  MAKATO_ARCHIVE_DATE="2026-07-10" \
  MAKATO_ARCHIVE_SKIP_PUSH=1 \
  MAKATO_ARCHIVE_GH_TEST_FILE="$sandbox/gh.log" \
    bash "$ARCHIVE" "$@" 2>"$sandbox/stderr.log"
}

# ---------------------------------------------------------------------------
echo "T1: slug from footer → archive folder + close issue"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/foo-feature"
  printf 'domain: workflows\n' >"$sb/specs/foo-feature/plan.md"
  printf '# Foo Feature\n' >"$sb/specs/foo-feature/prd.md"
  cat >"$sb/body.txt" <<'EOF'
Some issue text.

*Feature slug: `foo-feature` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 221 || { fail "T1" "non-zero exit"; }

  ok=1
  [[ -d "$sb/specs/archive/2026-07-10-foo-feature" ]] || { ok=0; err="folder not moved"; }
  [[ ! -d "$sb/specs/foo-feature" ]] || { ok=0; err="source folder still present"; }
  grep -q "close #221 reason=completed" "$sb/gh.log" || { ok=0; err="issue not closed"; }
  grep -q "workflows.md" <<<"$(ls "$sb/specs/master")".md 2>/dev/null || \
    [[ -f "$sb/specs/master/workflows.md" ]] || { ok=0; err="master spec not created"; }
  grep -q "2026-07-10 | foo-feature | Archived" "$sb/specs/master/workflows.md" 2>/dev/null || { ok=0; err="evolution log row missing"; }
  grep -q "foo-feature" "$sb/specs/archive/README.md" 2>/dev/null || { ok=0; err="archive index row missing"; }
  [[ "$ok" == 1 ]] && pass "T1" || fail "T1" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T2: slug from stories.json fallback"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/bar-thing"
  printf '# Bar Thing\n' >"$sb/specs/bar-thing/plan.md"
  cat >"$sb/body.txt" <<'EOF'
Implements specs/bar-thing/stories.json story 3.
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 42 || fail "T2" "non-zero exit"
  ok=1
  [[ -d "$sb/specs/archive/2026-07-10-bar-thing" ]] || { ok=0; err="folder not moved from fallback slug"; }
  grep -q "close #42" "$sb/gh.log" || { ok=0; err="issue not closed"; }
  [[ "$ok" == 1 ]] && pass "T2" || fail "T2" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T3: no provenance → close issue, no folder move"
{
  sb="$(new_sandbox)"
  cat >"$sb/body.txt" <<'EOF'
A hand-filed issue with no to-issues footer at all.
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 99
  rc=$?
  ok=1
  [[ "$rc" == 0 ]] || { ok=0; err="expected exit 0, got $rc"; }
  grep -q "close #99" "$sb/gh.log" || { ok=0; err="issue not closed"; }
  [[ "$ok" == 1 ]] && pass "T3" || fail "T3" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T4: slug present but no matching folder → close, no move"
{
  sb="$(new_sandbox)"
  cat >"$sb/body.txt" <<'EOF'
*Feature slug: `ghost-feature` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 7
  rc=$?
  ok=1
  [[ "$rc" == 0 ]] || { ok=0; err="expected exit 0, got $rc"; }
  grep -q "close #7" "$sb/gh.log" || { ok=0; err="issue not closed"; }
  grep -q "gitignored on this runner" "$sb/gh.log" || { ok=0; err="comment not the no-folder variant"; }
  [[ "$ok" == 1 ]] && pass "T4" || fail "T4" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T5: already-closed issue → idempotent skip"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/idem-feature"
  printf '# Idem\n' >"$sb/specs/idem-feature/plan.md"
  cat >"$sb/body.txt" <<'EOF'
*Feature slug: `idem-feature` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=CLOSED \
    run_archive "$sb" --issue 5 || fail "T5" "non-zero exit"
  ok=1
  # Folder still archived (move is independent of close), but NO close mutation recorded.
  [[ -d "$sb/specs/archive/2026-07-10-idem-feature" ]] || { ok=0; err="folder should still be moved"; }
  if grep -q "close #5" "$sb/gh.log" 2>/dev/null; then ok=0; err="close mutation should be skipped for closed issue"; fi
  grep -q "already closed" "$sb/stderr.log" || { ok=0; err="idempotent skip notice missing"; }
  [[ "$ok" == 1 ]] && pass "T5" || fail "T5" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T6: missing issue number → exit 2"
{
  sb="$(new_sandbox)"
  set +e
  run_archive "$sb"
  rc=$?
  set -e
  [[ "$rc" == 2 ]] && pass "T6" || fail "T6" "expected exit 2, got $rc"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T7: epic collision — disambiguate by issue number"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/epic-slug-f1" "$sb/specs/epic-slug-f2"
  printf '# F1\n' >"$sb/specs/epic-slug-f1/plan.md"
  printf '# F2\n' >"$sb/specs/epic-slug-f2/plan.md"
  # created-issues.json in f2 references issue 147.
  printf '{"issue_number": 147}\n' >"$sb/specs/epic-slug-f2/created-issues.json"
  cat >"$sb/body.txt" <<'EOF'
*Feature slug: `epic-slug` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 147 || fail "T7" "non-zero exit"
  ok=1
  [[ -d "$sb/specs/archive/2026-07-10-epic-slug-f2" ]] || { ok=0; err="wrong folder archived (disambiguation failed)"; }
  [[ -d "$sb/specs/epic-slug-f1" ]] || { ok=0; err="f1 should be untouched"; }
  [[ "$ok" == 1 ]] && pass "T7" || fail "T7" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T8: Evolution Log row appended to existing master spec"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/evo-feature"
  printf 'domain: integrations\n' >"$sb/specs/evo-feature/plan.md"
  # Pre-seed a master spec with an existing evolution row.
  cat >"$sb/specs/master/integrations.md" <<'EOF'
# Master Spec: integrations

**Last Updated**: 2026-01-01
**Features Merged**: 1

---

## Current Requirements

---

## Evolution Log

| Date | Feature | Change Type | Summary | Rationale |
|------|---------|-------------|---------|-----------|
| 2026-01-01 | old-feature | Archived | old | seed |

---

## Superseded Requirements

| Requirement | Superseded By | Date | Feature | Reason |
|-------------|---------------|------|---------|--------|
EOF
  cat >"$sb/body.txt" <<'EOF'
*Feature slug: `evo-feature` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 88 || fail "T8" "non-zero exit"
  ok=1
  grep -q "evo-feature | Archived" "$sb/specs/master/integrations.md" || { ok=0; err="new evolution row missing"; }
  grep -q "old-feature | Archived" "$sb/specs/master/integrations.md" || { ok=0; err="existing evolution row lost"; }
  # New row must sit under the separator, above the seed row is fine — just assert both present + separator intact.
  grep -q '^|------|' "$sb/specs/master/integrations.md" || { ok=0; err="table separator corrupted"; }
  [[ "$ok" == 1 ]] && pass "T8" || fail "T8" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T9: master spec created from template when absent"
{
  sb="$(new_sandbox)"
  mkdir -p "$sb/specs/fresh-feature"
  printf 'domain: reporting\n' >"$sb/specs/fresh-feature/plan.md"
  cat >"$sb/body.txt" <<'EOF'
*Feature slug: `fresh-feature` — produced by to-issues v3.4.0.*
EOF
  MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE="$sb/body.txt" \
  MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE=OPEN \
    run_archive "$sb" --issue 90 || fail "T9" "non-zero exit"
  ok=1
  [[ -f "$sb/specs/master/reporting.md" ]] || { ok=0; err="master spec not created"; }
  grep -q "# Master Spec: reporting" "$sb/specs/master/reporting.md" 2>/dev/null || { ok=0; err="template heading missing"; }
  grep -q "fresh-feature | Archived" "$sb/specs/master/reporting.md" 2>/dev/null || { ok=0; err="evolution row missing in new master"; }
  [[ "$ok" == 1 ]] && pass "T9" || fail "T9" "${err:-unknown}"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────"
echo "archive-spec smoke tests: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
echo "ALL PASS"
