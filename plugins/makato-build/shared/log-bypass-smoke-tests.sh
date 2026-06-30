#!/usr/bin/env bash
# Smoke tests for log-bypass.sh — the canonical autonomous_bypass JSONL emitter.
#
# Coverage:
#   T1 — canonical 5-field shape (no extras)
#   T2 — with extras (skill-specific context merged into data)
#   T3 — extras cannot override canonical fields (bypassed always true)
#   T4 — every documented trigger value accepted
#   T5 — missing required arg → exit 2
#   T6 — invalid trigger → exit 2
#   T7 — non-object extras → exit 3
#   T8 — non-JSON extras → exit 3
#   T9 — ISO-8601-ms timestamp (matches the schema regex used by audit consumers)
#  T10 — entry lands in $REPO_ROOT/specs/<key>-*/build.jsonl
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/log-bypass.sh"
FAIL=0

_setup() {
  unset TMPDIR  # avoid inheriting a deleted dir from a prior _teardown
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR"
  git init -q
  mkdir -p specs/TEST-001-smoke
}

_teardown() {
  cd /
  rm -rf "$WORKDIR"
  unset WORKDIR
}

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: canonical 5-field shape (no extras) -----
echo "T1: canonical 5-field shape"
_setup
"$HELPER" build-refine TEST-001 work-item-key use-arg cli_flag >/dev/null
LINE="$(tail -1 specs/TEST-001-smoke/build.jsonl)"
[[ "$(jq -r .skill <<<"$LINE")" == "build-refine" ]] && _pass "skill" || _fail "skill"
[[ "$(jq -r .story <<<"$LINE")" == "TEST-001" ]] && _pass "story" || _fail "story"
[[ "$(jq -r .step <<<"$LINE")" == "decision" ]] && _pass "step" || _fail "step"
[[ "$(jq -r .status <<<"$LINE")" == "decision" ]] && _pass "status" || _fail "status"
[[ "$(jq -r .data.event <<<"$LINE")" == "autonomous_bypass" ]] && _pass "data.event" || _fail "data.event"
[[ "$(jq -r .data.gate <<<"$LINE")" == "work-item-key" ]] && _pass "data.gate" || _fail "data.gate"
[[ "$(jq -r .data.bypassed <<<"$LINE")" == "true" ]] && _pass "data.bypassed" || _fail "data.bypassed"
[[ "$(jq -r .data.default_taken <<<"$LINE")" == "use-arg" ]] && _pass "data.default_taken" || _fail "data.default_taken"
[[ "$(jq -r .data.trigger <<<"$LINE")" == "cli_flag" ]] && _pass "data.trigger" || _fail "data.trigger"
_teardown

# ----- T2: with extras -----
echo "T2: extras merged into data"
_setup
"$HELPER" build-address-pr-comments TEST-001 out-of-scope-carry-over open-followup-issue cli_flag \
  '{"comment_id":"42","follow_up_issue":"https://example.com/issues/99"}' >/dev/null
LINE="$(tail -1 specs/TEST-001-smoke/build.jsonl)"
[[ "$(jq -r .data.comment_id <<<"$LINE")" == "42" ]] && _pass "extras.comment_id" || _fail "extras.comment_id"
[[ "$(jq -r .data.follow_up_issue <<<"$LINE")" == "https://example.com/issues/99" ]] && _pass "extras.follow_up_issue" || _fail "extras.follow_up_issue"
[[ "$(jq -r .data.event <<<"$LINE")" == "autonomous_bypass" ]] && _pass "canonical fields still present" || _fail "canonical fields still present"
_teardown

# ----- T3: extras cannot override canonical fields -----
echo "T3: extras cannot override canonical fields"
_setup
"$HELPER" build-x TEST-001 g d cli_flag '{"bypassed":false,"event":"hijack","gate":"override-attempt"}' >/dev/null
LINE="$(tail -1 specs/TEST-001-smoke/build.jsonl)"
[[ "$(jq -r .data.bypassed <<<"$LINE")" == "true" ]] && _pass "bypassed stays true" || _fail "bypassed stays true"
[[ "$(jq -r .data.event <<<"$LINE")" == "autonomous_bypass" ]] && _pass "event stays autonomous_bypass" || _fail "event stays autonomous_bypass"
[[ "$(jq -r .data.gate <<<"$LINE")" == "g" ]] && _pass "gate stays from positional arg" || _fail "gate stays from positional arg"
_teardown

# ----- T4: every documented trigger value accepted -----
echo "T4: every documented trigger accepted"
_setup
for t in agent_id cli_flag task_id_bundle 'agent_id|cli_flag|task_id_bundle'; do
  if "$HELPER" build-x TEST-001 g d "$t" >/dev/null 2>&1; then
    _pass "trigger=$t"
  else
    _fail "trigger=$t"
  fi
done
_teardown

# ----- T5: missing required arg -----
echo "T5: missing required arg → exit 2"
_setup
"$HELPER" build-x TEST-001 >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && _pass "exit 2 on missing args" || _fail "exit $rc on missing args (expected 2)"
_teardown

# ----- T6: invalid trigger -----
echo "T6: invalid trigger → exit 2"
_setup
"$HELPER" build-x TEST-001 g d nonsense >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && _pass "exit 2 on bad trigger" || _fail "exit $rc on bad trigger (expected 2)"
_teardown

# ----- T7: non-object extras -----
echo "T7: non-object extras → exit 3"
_setup
"$HELPER" build-x TEST-001 g d cli_flag '"a-string"' >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] && _pass "exit 3 on string extras" || _fail "exit $rc on string extras (expected 3)"
"$HELPER" build-x TEST-001 g d cli_flag '[1,2,3]' >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] && _pass "exit 3 on array extras" || _fail "exit $rc on array extras (expected 3)"
_teardown

# ----- T8: non-JSON extras -----
echo "T8: non-JSON extras → exit 3"
_setup
"$HELPER" build-x TEST-001 g d cli_flag 'not-json' >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] && _pass "exit 3 on garbage extras" || _fail "exit $rc on garbage extras (expected 3)"
_teardown

# ----- T9: ISO-8601-ms timestamp -----
echo "T9: ISO-8601-ms timestamp shape"
_setup
"$HELPER" build-x TEST-001 g d cli_flag >/dev/null
LINE="$(tail -1 specs/TEST-001-smoke/build.jsonl)"
TS="$(jq -r .ts <<<"$LINE")"
if [[ "$TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
  _pass "ts matches ISO-8601-ms ($TS)"
else
  _fail "ts does not match ISO-8601-ms: $TS"
fi
_teardown

# ----- T10: entry lands in specs/<key>-*/build.jsonl -----
echo "T10: entry lands in spec folder"
_setup
"$HELPER" build-x TEST-001 g d cli_flag >/dev/null
if [[ -s specs/TEST-001-smoke/build.jsonl ]]; then
  _pass "build.jsonl exists and is non-empty"
else
  _fail "build.jsonl missing or empty"
fi
_teardown

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All log-bypass.sh smoke tests passed."
  exit 0
else
  echo "$FAIL log-bypass.sh smoke test(s) failed."
  exit 1
fi
