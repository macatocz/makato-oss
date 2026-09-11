#!/usr/bin/env bash
# Smoke tests for build-log.sh single-entry vs --batch mode (#118).
#
# Coverage:
#   T1 — single-entry mode (legacy) appends one row
#   T2 — --batch mode reads NDJSON from stdin and appends each row
#   T3 — --batch matches single-entry output for the same set of entries
#   T4 — --batch skips blank lines
#   T5 — --batch skips malformed JSON lines (audit-log "never crashes" invariant)
#   T6 — --batch is idempotent on empty stdin (no rows appended)
#   T7 — malformed timestamps are repaired to ISO-8601 milliseconds
#   T8 — numeric issue keys append to an existing slug folder
#
# Exit: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/build-log.sh"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

_setup() {
  unset TMPDIR
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR" || exit 1
  git init -q
  mkdir -p specs/TEST-001-x
}
_teardown() {
  cd /
  rm -rf "$WORKDIR"
  unset WORKDIR
}

# ----- T1: single-entry mode -----
echo "T1: single-entry mode appends one row"
_setup
"$HELPER" TEST-001 '{"ts":"2026-06-30T00:00:00.000Z","skill":"s","story":"TEST-001","step":"x","status":"ok"}'
LINES=$(wc -l < specs/TEST-001-x/build.jsonl | tr -d ' ')
[[ "$LINES" == "1" ]] && _pass "1 line appended" || _fail "expected 1, got $LINES"
_teardown

# ----- T2: --batch mode -----
echo "T2: --batch mode reads NDJSON from stdin"
_setup
printf '%s\n' \
  '{"ts":"2026-06-30T00:00:00.000Z","skill":"s","story":"TEST-001","step":"a","status":"ok"}' \
  '{"ts":"2026-06-30T00:00:00.001Z","skill":"s","story":"TEST-001","step":"b","status":"ok"}' \
  '{"ts":"2026-06-30T00:00:00.002Z","skill":"s","story":"TEST-001","step":"c","status":"ok"}' \
  | "$HELPER" TEST-001 --batch
LINES=$(wc -l < specs/TEST-001-x/build.jsonl | tr -d ' ')
[[ "$LINES" == "3" ]] && _pass "3 lines appended" || _fail "expected 3, got $LINES"
_teardown

# ----- T3: --batch output matches single-entry output -----
echo "T3: --batch output matches per-row single-entry output"
_setup
# Per-row single-entry baseline
for s in a b c; do
  "$HELPER" TEST-001 "{\"step\":\"$s\",\"status\":\"ok\"}"
done
SINGLE="$(cat specs/TEST-001-x/build.jsonl)"
rm specs/TEST-001-x/build.jsonl
# Batch run
printf '%s\n' \
  '{"step":"a","status":"ok"}' \
  '{"step":"b","status":"ok"}' \
  '{"step":"c","status":"ok"}' \
  | "$HELPER" TEST-001 --batch
BATCH="$(cat specs/TEST-001-x/build.jsonl)"
if [[ "$SINGLE" == "$BATCH" ]]; then
  _pass "outputs match byte-for-byte"
else
  _fail "outputs differ"
  diff <(echo "$SINGLE") <(echo "$BATCH")
fi
_teardown

# ----- T4: --batch skips blank lines -----
echo "T4: --batch skips blank lines"
_setup
printf '%s\n' \
  '{"step":"a","status":"ok"}' \
  '' \
  '{"step":"b","status":"ok"}' \
  '' \
  | "$HELPER" TEST-001 --batch
LINES=$(wc -l < specs/TEST-001-x/build.jsonl | tr -d ' ')
[[ "$LINES" == "2" ]] && _pass "2 lines appended (blanks skipped)" || _fail "expected 2, got $LINES"
_teardown

# ----- T5: --batch skips malformed JSON lines -----
echo "T5: --batch skips malformed JSON lines"
_setup
printf '%s\n' \
  '{"step":"a","status":"ok"}' \
  'this-is-not-json' \
  '{"step":"b","status":"ok"}' \
  '{garbage' \
  '{"step":"c","status":"ok"}' \
  | "$HELPER" TEST-001 --batch 2>/dev/null
LINES=$(wc -l < specs/TEST-001-x/build.jsonl | tr -d ' ')
[[ "$LINES" == "3" ]] && _pass "3 lines appended (malformed skipped)" || _fail "expected 3, got $LINES"
_teardown

# ----- T6: --batch idempotent on empty stdin -----
echo "T6: --batch idempotent on empty stdin"
_setup
echo -n "" | "$HELPER" TEST-001 --batch
if [[ -f specs/TEST-001-x/build.jsonl ]]; then
  LINES=$(wc -l < specs/TEST-001-x/build.jsonl | tr -d ' ')
else
  LINES=0
fi
[[ "$LINES" == "0" ]] && _pass "0 lines appended on empty stdin" || _fail "expected 0, got $LINES"
_teardown

# ----- T7: malformed timestamp repair ----------------------------------------
echo "T7: malformed timestamps are repaired"
_setup
"$HELPER" TEST-001 '{"ts":"2026-09-11T05:17:52.884198000Z'\''","skill":"s","story":"TEST-001","step":"x","status":"ok"}' 2>"$WORKDIR/stderr"
TS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ts"])' specs/TEST-001-x/build.jsonl)"
if [[ "$TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] &&
   grep -q "repaired invalid ts" "$WORKDIR/stderr"; then
  _pass "invalid timestamp repaired and warning emitted"
else
  _fail "invalid timestamp was not repaired: $TS"
fi
_teardown

# ----- T8: numeric issue-to-slug resolution -------------------------------
echo "T8: numeric issue key resolves existing slug folder"
_setup
rm -rf specs/TEST-001-x
mkdir -p specs/db-schema-redesign
printf '%s\n' '# plan' > specs/db-schema-redesign/plan-995.md
"$HELPER" 995 '{"step":"numeric","status":"ok"}'
if [[ -f specs/db-schema-redesign/build.jsonl && ! -e specs/995 ]]; then
  _pass "numeric issue appended to slug folder"
else
  _fail "numeric issue created the wrong audit folder"
fi
_teardown

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All build-log batch-mode smoke tests passed."
  exit 0
else
  echo "$FAIL build-log batch-mode smoke test(s) failed."
  exit 1
fi
