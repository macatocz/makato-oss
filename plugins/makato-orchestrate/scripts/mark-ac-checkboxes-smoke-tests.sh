#!/usr/bin/env bash
# Smoke tests for scripts/mark-ac-checkboxes.sh (AC-verification Layer 3).
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/mark-ac-checkboxes-smoke-tests.sh
#
# Scenarios:
#   T1: missing args exits 1
#   T2: malformed verdict JSON exits 1
#   T3: granular — verified AC flips only its matched box; others untouched
#   T4: granular — verified==false leaves its box unchecked
#   T5: granular — never flips an already-[x] box back to [ ]
#   T6: granular — normalization pairs "AC-1: Foo" plan text with "- [ ] Foo" issue line
#   T7: fallback-all — 0 matches + all verified → every box checked
#   T8: fallback-none — 0 matches + one gap → no box checked
#   T9: empty verdict array → skipped, body unchanged
#   T10: indentation and label text preserved byte-for-byte except the marker
#
# Fully offline: verdicts + issue body injected via fixture files.
# Mirrors emit-reshape-request-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/mark-ac-checkboxes.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/mark-ac-checkboxes-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# run <verdicts-json> <body-text> → sets OUT (stdout body) and SUMMARY (stderr json)
run() {
  local vfile="$SANDBOX/v.json" bfile="$SANDBOX/b.md"
  printf '%s' "$1" > "$vfile"
  printf '%s' "$2" > "$bfile"
  SUMMARY="$("$SCRIPT" "$vfile" "$bfile" 2>"$SANDBOX/err.txt" >"$SANDBOX/out.txt"; :)"
  SUMMARY="$(cat "$SANDBOX/err.txt")"
  OUT="$(cat "$SANDBOX/out.txt")"
}

echo "=== T1: missing args exits 1 ==="
if "$SCRIPT" 2>/dev/null; then fail "T1: expected non-zero exit"; fi
pass "T1: missing args rejected"

echo "=== T2: malformed verdict JSON exits 1 ==="
printf '{not json' > "$SANDBOX/bad.json"; printf 'body' > "$SANDBOX/b.md"
if "$SCRIPT" "$SANDBOX/bad.json" "$SANDBOX/b.md" 2>/dev/null; then fail "T2: expected non-zero exit"; fi
pass "T2: malformed JSON rejected"

BODY3='## Definition of Done

- [ ] Alpha behaviour works
- [ ] Beta behaviour works'
echo "=== T3: granular — matched verified box flips, other untouched ==="
run '[{"ac_id":"AC-1","ac_text":"Alpha behaviour works","verified":true},{"ac_id":"AC-2","ac_text":"Beta behaviour works","verified":false}]' "$BODY3"
echo "$OUT" | grep -qF -- '- [x] Alpha behaviour works' || fail "T3: Alpha not checked"
echo "$OUT" | grep -qF -- '- [ ] Beta behaviour works'  || fail "T3: Beta wrongly changed"
echo "$SUMMARY" | grep -q '"mode": "granular"' || fail "T3: mode not granular ($SUMMARY)"
echo "$SUMMARY" | grep -q '"boxes_checked": 1' || fail "T3: boxes_checked != 1 ($SUMMARY)"
pass "T3: granular single-box flip"

echo "=== T4: granular — verified==false leaves box unchecked ==="
run '[{"ac_id":"AC-1","ac_text":"Alpha behaviour works","verified":true},{"ac_id":"AC-2","ac_text":"Beta behaviour works","verified":false}]' "$BODY3"
echo "$OUT" | grep -qF -- '- [ ] Beta behaviour works' || fail "T4: false verdict changed"
pass "T4: gap verdict stays unchecked"

echo "=== T5: never flips [x] back to [ ] ==="
BODY5='- [x] Already done
- [ ] Alpha behaviour works'
run '[{"ac_id":"AC-1","ac_text":"Already done","verified":false}]' "$BODY5"
echo "$OUT" | grep -qF -- '- [x] Already done' || fail "T5: existing [x] got unchecked"
pass "T5: existing [x] preserved"

echo "=== T6: normalization pairs AC-N-prefixed text with plain issue line ==="
run '[{"ac_id":"AC-1","ac_text":"AC-1: Alpha behaviour works.","verified":true}]' "$BODY3"
echo "$OUT" | grep -qF -- '- [x] Alpha behaviour works' || fail "T6: normalized match failed"
pass "T6: label/prefix normalization matches"

echo "=== T7: fallback-all — 0 matches + all verified → all checked ==="
BODY7='- [ ] Completely different wording one
- [ ] Completely different wording two'
run '[{"ac_id":"AC-1","ac_text":"nonmatching alpha","verified":true},{"ac_id":"AC-2","ac_text":"nonmatching beta","verified":true}]' "$BODY7"
echo "$SUMMARY" | grep -q '"mode": "fallback-all"' || fail "T7: mode not fallback-all ($SUMMARY)"
[[ "$(echo "$OUT" | grep -cF -- '- [x]')" == "2" ]] || fail "T7: expected 2 boxes checked"
pass "T7: fallback-all checks every box"

echo "=== T8: fallback-none — 0 matches + one gap → none checked ==="
run '[{"ac_id":"AC-1","ac_text":"nonmatching alpha","verified":true},{"ac_id":"AC-2","ac_text":"nonmatching beta","verified":false}]' "$BODY7"
echo "$SUMMARY" | grep -q '"mode": "fallback-none"' || fail "T8: mode not fallback-none ($SUMMARY)"
[[ "$(echo "$OUT" | grep -cF -- '- [x]')" == "0" ]] || fail "T8: expected 0 boxes checked"
echo "$OUT" | grep -qF -- '- [ ] Completely different wording one' || fail "T8: body altered"
pass "T8: fallback-none leaves all unchecked"

echo "=== T9: empty verdict array → skipped, body unchanged ==="
run '[]' "$BODY3"
echo "$SUMMARY" | grep -q '"mode": "skipped"' || fail "T9: mode not skipped ($SUMMARY)"
[[ "$OUT" == "$BODY3" ]] || fail "T9: body changed on empty verdicts"
pass "T9: empty verdicts is a no-op"

echo "=== T10: indentation + label preserved except marker ==="
BODY10='  - [ ]   Indented alpha with spacing'
run '[{"ac_id":"AC-1","ac_text":"Indented alpha with spacing","verified":true}]' "$BODY10"
echo "$OUT" | grep -qF -- '  - [x]   Indented alpha with spacing' || fail "T10: indent/spacing not preserved ($OUT)"
pass "T10: indent and spacing preserved"

echo ""
echo "All mark-ac-checkboxes smoke tests passed."
