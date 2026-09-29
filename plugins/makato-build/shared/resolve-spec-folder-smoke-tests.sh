#!/usr/bin/env bash
# Runtime coverage for numeric issue-to-spec ownership resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-spec-folder.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

# A child issue can be mapped by created-issues.json even when only a sibling plan exists.
SPECS="$TEST_ROOT/specs"
SHARED_SPEC="$SPECS/grounding-tool-api-layer-search-pricing"
mkdir -p "$SHARED_SPEC"
cat >"$SHARED_SPEC/created-issues.json" <<'JSON'
{
  "slug": "grounding-tool-api-layer-search-pricing",
  "issues": [
    {"issue_number": 1106},
    {"issue_number": 1107, "blocked_by": [1106]}
  ]
}
JSON
: >"$SHARED_SPEC/plan-1106.md"
RESOLVED="$(bash "$RESOLVER" "$SPECS" 1107)"
[[ "$RESOLVED" == "$SHARED_SPEC" ]] \
  || fail "issue 1107 resolved to '$RESOLVED', expected '$SHARED_SPEC'"
pass "issue #1107 maps to shared spec through created-issues.json"

# Never choose arbitrarily when more than one manifest claims an issue.
DUPLICATE_SPEC="$SPECS/another-spec"
mkdir -p "$DUPLICATE_SPEC"
cat >"$DUPLICATE_SPEC/created-issues.json" <<'JSON'
{"issues": [{"issue_number": 1107}]}
JSON
if bash "$RESOLVER" "$SPECS" 1107 >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
  fail "duplicate manifest owners were accepted"
fi
grep -q 'multiple created-issues.json files' "$TEST_ROOT/err" \
  || fail "duplicate-owner failure did not explain the ambiguity"
pass "duplicate manifest owners are rejected"

# Preserve exact-folder priority and the existing unique-prefix fallback.
EXACT_SPECS="$TEST_ROOT/exact-specs"
mkdir -p "$EXACT_SPECS/1107"
RESOLVED="$(bash "$RESOLVER" "$EXACT_SPECS" 1107)"
[[ "$RESOLVED" == "$EXACT_SPECS/1107" ]] || fail "exact folder did not win"
pass "exact folder still takes precedence"

PREFIX_SPECS="$TEST_ROOT/prefix-specs"
mkdir -p "$PREFIX_SPECS/77-existing-feature"
RESOLVED="$(bash "$RESOLVER" "$PREFIX_SPECS" 77)"
[[ "$RESOLVED" == "$PREFIX_SPECS/77-existing-feature" ]] \
  || fail "unique prefix fallback resolved to '$RESOLVED'"
pass "unique key-prefix fallback remains supported"

printf 'All resolve-spec-folder smoke tests passed.\n'
