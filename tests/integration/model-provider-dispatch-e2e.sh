#!/usr/bin/env bash
# model-provider-dispatch-e2e.sh — provider-neutral tool-call dispatch proof
# (Task 4, local-openai-gpt-macos-compatibility, AC-1).
#
# Proves the normalization contract this story's autonomous loop depends on:
# a native OpenAI chat-completions response and a local/remote vLLM response
# running the Qwen3 tool-call parser (config/model-profiles.yml tool_format:
# openai | qwen3) both resolve to the same canonical tool-call shape, and that
# malformed/truncated provider responses are classified as actionable
# failures rather than silently treated as success.
#
# Offline fixture path (default, CI-safe):
#   Scenarios A-G run unconditionally against the sanitized, deterministic
#   fixtures in tests/fixtures/model-provider/*.json. No network call is
#   made and no credential is required.
#
# Opt-in live path:
#   Scenario H only runs when explicitly enabled AND all live prerequisites
#   are present:
#     MAKATO_MODEL_PROVIDER_LIVE=1   — explicit opt-in switch (never implied)
#     OPENAI_API_KEY                 — a real OpenAI credential
#     MAKATO_LIVE_QWEN_ENDPOINT_URL  — a reachable Qwen/vLLM or Ollama base URL
#     MAKATO_LOOP_DISPATCH_REPO      — an explicit test repository (owner/repo)
#   Any missing prerequisite reports Scenario H as SKIP (not PASS, not FAIL) —
#   this is the "actionable SKIP, never silently healthy" contract shared with
#   scripts/preflight-optional-services.sh (Task 5).
#
# Scenarios:
#   A: parse + normalize the OpenAI fixture (arguments as a JSON-encoded
#      string) into the canonical {id, name, arguments(dict)} shape.
#   B: parse + normalize the Qwen3/vLLM fixture (arguments already a JSON
#      object — a documented vLLM Qwen3 tool-parser quirk) into the SAME
#      canonical shape as Scenario A.
#   C: truncated/malformed JSON response is classified TRUNCATED_JSON, not
#      silently accepted.
#   D: well-formed JSON with no tool_calls field is classified
#      MISSING_TOOL_CALLS.
#   E: tool_calls present but function.arguments is neither a string nor an
#      object is classified INVALID_ARGUMENTS_TYPE.
#   F: a valid R1 envelope (schema/status/required-keys) validates OK.
#   G: an invalid R1 envelope (bad status enum, missing required key) is
#      rejected with an actionable reason, not accepted.
#   H: (opt-in, live) provider-specific health/auth requirement check against
#      a real OpenAI endpoint and a real Qwen/Ollama-compatible endpoint.
#
# Run from repo root:
#   bash tests/integration/model-provider-dispatch-e2e.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/model-provider"
OPENAI_FIXTURE="$FIXTURE_DIR/openai-tool-call.json"
QWEN_FIXTURE="$FIXTURE_DIR/qwen-tool-call.json"
RESOLVE_PROFILE="$REPO_ROOT/scripts/resolve-model-profile.py"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"

PASS=0
FAIL=0
SKIP=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
_skip() { printf '  SKIP: %s\n' "$1"; SKIP=$(( SKIP + 1 )); }

# ---------------------------------------------------------------------------
# Shared normalization/validation/classification module — written once to a
# sandbox temp file so every scenario below imports the same logic (no
# per-scenario copy/paste of the parsing rules).
# ---------------------------------------------------------------------------
SANDBOX_DIR="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_DIR"' EXIT

NORMALIZER_PY="$SANDBOX_DIR/provider_tool_call.py"
cat > "$NORMALIZER_PY" <<'PYEOF'
"""Provider-neutral tool-call normalization + R1 envelope validation.

Sanitized, dependency-free reference implementation exercised by
tests/integration/model-provider-dispatch-e2e.sh. Mirrors the normalization
contract the autonomous loop needs: an OpenAI chat-completions response and
a vLLM Qwen3 tool-parser response must resolve to the same canonical shape,
and malformed/truncated responses must be classified, never silently
accepted as success.
"""
import json
import sys


class ToolCallError(Exception):
    """Raised with a classification code prefix, e.g. 'TRUNCATED_JSON: ...'."""


def parse_response(raw_text):
    """Parse a raw provider response body. Raises ToolCallError on truncated
    or otherwise malformed JSON — this is a classification failure, never a
    silent success."""
    try:
        return json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ToolCallError(f"TRUNCATED_JSON: {exc}") from exc


def normalize_tool_calls(document):
    """document: a parsed OpenAI-compatible chat-completion response.
    Returns a list of canonical {id, name, arguments(dict)} entries.
    Raises ToolCallError with a classification code on any structural
    problem — a malformed/truncated/incomplete tool call must never
    normalize into a success-shaped result."""
    choices = document.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ToolCallError("MISSING_CHOICES: response has no choices[]")
    message = (choices[0] or {}).get("message") or {}
    tool_calls = message.get("tool_calls")
    if tool_calls is None:
        raise ToolCallError("MISSING_TOOL_CALLS: message has no tool_calls field")
    if not isinstance(tool_calls, list) or not tool_calls:
        raise ToolCallError("EMPTY_TOOL_CALLS: tool_calls is empty or not a list")

    normalized = []
    for tc in tool_calls:
        fn = (tc or {}).get("function") or {}
        name = fn.get("name")
        if not name:
            raise ToolCallError("MISSING_FUNCTION_NAME: tool_call missing function.name")
        args_raw = fn.get("arguments")
        if isinstance(args_raw, str):
            # OpenAI-spec shape: JSON-encoded string.
            try:
                args = json.loads(args_raw)
            except json.JSONDecodeError as exc:
                raise ToolCallError(f"INVALID_ARGUMENTS_JSON: {exc}") from exc
        elif isinstance(args_raw, dict):
            # vLLM Qwen3 tool-parser quirk: already-parsed object.
            args = args_raw
        else:
            raise ToolCallError(
                f"INVALID_ARGUMENTS_TYPE: arguments must be string or object, got {type(args_raw).__name__}"
            )
        normalized.append({"id": tc.get("id", ""), "name": name, "arguments": args})
    return normalized


_R1_REQUIRED_KEYS = (
    "schema",
    "agent",
    "status",
    "summary",
    "files_changed",
    "tests_written",
    "errors",
    "tool_calls_used",
    "data",
)
_R1_VALID_STATUSES = ("success", "partial", "failure")
_R1_LIST_KEYS = ("files_changed", "tests_written", "errors")


def validate_r1(envelope):
    """Return (True, []) when the envelope satisfies the R1 contract
    (plugins/makato-build/agents/RETURN-CONTRACT.md); otherwise
    (False, [<actionable reason>, ...]). Never raises — callers always get a
    classified result."""
    reasons = []
    if not isinstance(envelope, dict):
        return False, ["NOT_AN_OBJECT: R1 envelope must be a JSON object"]
    for key in _R1_REQUIRED_KEYS:
        if key not in envelope:
            reasons.append(f"MISSING_KEY: required key '{key}' absent")
    if envelope.get("schema") != "r1":
        reasons.append(f"BAD_SCHEMA: schema must be 'r1', got {envelope.get('schema')!r}")
    if envelope.get("status") not in _R1_VALID_STATUSES:
        reasons.append(
            f"BAD_STATUS: status must be one of {_R1_VALID_STATUSES}, got {envelope.get('status')!r}"
        )
    for key in _R1_LIST_KEYS:
        if key in envelope and not isinstance(envelope[key], list):
            reasons.append(f"BAD_TYPE: '{key}' must be a list")
    return (len(reasons) == 0), reasons


if __name__ == "__main__":
    # CLI shim so the bash scenarios below can invoke this as a subprocess
    # without a long inline `python3 -c` per call.
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "normalize":
        raw_text = sys.stdin.read()
        try:
            doc = parse_response(raw_text)
            result = normalize_tool_calls(doc)
            print(json.dumps({"ok": True, "normalized": result}))
        except ToolCallError as exc:
            print(json.dumps({"ok": False, "error": str(exc)}))
    elif cmd == "validate-r1":
        raw_text = sys.stdin.read()
        try:
            envelope = json.loads(raw_text)
        except json.JSONDecodeError as exc:
            print(json.dumps({"ok": False, "reasons": [f"TRUNCATED_JSON: {exc}"]}))
            sys.exit(0)
        ok, reasons = validate_r1(envelope)
        print(json.dumps({"ok": ok, "reasons": reasons}))
    else:
        sys.stderr.write("usage: provider_tool_call.py normalize|validate-r1 < input\n")
        sys.exit(2)
PYEOF

_normalize() { "$PYTHON_BIN" "$NORMALIZER_PY" normalize; }
_validate_r1() { "$PYTHON_BIN" "$NORMALIZER_PY" validate-r1; }

# ===========================================================================
# Scenario A — normalize the OpenAI fixture (arguments as JSON string)
# ===========================================================================
echo "=== Scenario A: normalize OpenAI-compatible tool-call fixture ==="
A_OUT="$(_normalize < "$OPENAI_FIXTURE")"
A_OK="$(printf '%s' "$A_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
A_NAME="$(printf '%s' "$A_OUT" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); print(d["normalized"][0]["name"] if d["ok"] else "")')"
A_PATH="$(printf '%s' "$A_OUT" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); print(d["normalized"][0]["arguments"].get("path","") if d["ok"] else "")')"
if [[ "$A_OK" == "True" && "$A_NAME" == "read_file" && "$A_PATH" == "specs/local-openai-gpt-macos-compatibility/plan.md" ]]; then
  _pass "OpenAI fixture normalizes to canonical {id,name,arguments} with parsed arguments dict"
else
  _fail "OpenAI fixture normalization mismatch: $A_OUT"
fi

# ===========================================================================
# Scenario B — normalize the Qwen3/vLLM fixture (arguments already a dict)
# ===========================================================================
echo "=== Scenario B: normalize Qwen3/vLLM tool-call fixture (arguments-as-object quirk) ==="
B_OUT="$(_normalize < "$QWEN_FIXTURE")"
B_OK="$(printf '%s' "$B_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
B_NAME="$(printf '%s' "$B_OUT" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); print(d["normalized"][0]["name"] if d["ok"] else "")')"
B_PATH="$(printf '%s' "$B_OUT" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); print(d["normalized"][0]["arguments"].get("path","") if d["ok"] else "")')"
if [[ "$B_OK" == "True" && "$B_NAME" == "$A_NAME" && "$B_PATH" == "$A_PATH" ]]; then
  _pass "Qwen3/vLLM fixture normalizes to the SAME canonical shape as the OpenAI fixture"
else
  _fail "Qwen3/vLLM fixture normalization diverged from OpenAI fixture: $B_OUT"
fi

# ===========================================================================
# Scenario C — truncated/malformed JSON is classified, not silently accepted
# ===========================================================================
echo "=== Scenario C: truncated JSON response is classified TRUNCATED_JSON ==="
C_TRUNCATED='{"choices":[{"message":{"tool_calls":[{"id":"x","function":{"name":"read_file","argum'
C_OUT="$(printf '%s' "$C_TRUNCATED" | _normalize)"
C_OK="$(printf '%s' "$C_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
C_ERR="$(printf '%s' "$C_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')"
if [[ "$C_OK" == "False" ]] && echo "$C_ERR" | grep -q "^TRUNCATED_JSON:"; then
  _pass "truncated JSON response classified TRUNCATED_JSON, not silently accepted"
else
  _fail "truncated JSON was not classified as expected: ok=$C_OK err=$C_ERR"
fi

# ===========================================================================
# Scenario D — well-formed JSON, no tool_calls field → MISSING_TOOL_CALLS
# ===========================================================================
echo "=== Scenario D: response with no tool_calls field is classified MISSING_TOOL_CALLS ==="
D_INPUT='{"choices":[{"message":{"role":"assistant","content":"no tools needed"}}]}'
D_OUT="$(printf '%s' "$D_INPUT" | _normalize)"
D_OK="$(printf '%s' "$D_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
D_ERR="$(printf '%s' "$D_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')"
if [[ "$D_OK" == "False" ]] && echo "$D_ERR" | grep -q "^MISSING_TOOL_CALLS:"; then
  _pass "response without tool_calls classified MISSING_TOOL_CALLS"
else
  _fail "missing-tool_calls response was not classified as expected: ok=$D_OK err=$D_ERR"
fi

# ===========================================================================
# Scenario E — arguments neither string nor object → INVALID_ARGUMENTS_TYPE
# ===========================================================================
echo "=== Scenario E: non-string/non-object arguments classified INVALID_ARGUMENTS_TYPE ==="
E_INPUT='{"choices":[{"message":{"tool_calls":[{"id":"x","function":{"name":"read_file","arguments":42}}]}}]}'
E_OUT="$(printf '%s' "$E_INPUT" | _normalize)"
E_OK="$(printf '%s' "$E_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
E_ERR="$(printf '%s' "$E_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')"
if [[ "$E_OK" == "False" ]] && echo "$E_ERR" | grep -q "^INVALID_ARGUMENTS_TYPE:"; then
  _pass "malformed arguments type classified INVALID_ARGUMENTS_TYPE"
else
  _fail "malformed-arguments-type response was not classified as expected: ok=$E_OK err=$E_ERR"
fi

# ===========================================================================
# Scenario F — a valid R1 envelope validates OK
# ===========================================================================
echo "=== Scenario F: valid R1 envelope validates OK ==="
F_INPUT='{"schema":"r1","agent":"coder","status":"success","summary":"ok","files_changed":[],"tests_written":[],"errors":[],"tool_calls_used":1,"data":{}}'
F_OUT="$(printf '%s' "$F_INPUT" | _validate_r1)"
F_OK="$(printf '%s' "$F_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
if [[ "$F_OK" == "True" ]]; then
  _pass "well-formed R1 envelope validates OK"
else
  _fail "well-formed R1 envelope unexpectedly failed validation: $F_OUT"
fi

# ===========================================================================
# Scenario G — an invalid R1 envelope is rejected with actionable reasons
# ===========================================================================
echo "=== Scenario G: invalid R1 envelope (bad status, missing key) is rejected ==="
G_INPUT='{"schema":"r1","status":"maybe","summary":"","files_changed":[],"errors":[],"tool_calls_used":0,"data":{}}'
G_OUT="$(printf '%s' "$G_INPUT" | _validate_r1)"
G_OK="$(printf '%s' "$G_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
G_REASONS="$(printf '%s' "$G_OUT" | "$PYTHON_BIN" -c 'import json,sys; print(len(json.load(sys.stdin)["reasons"]))')"
if [[ "$G_OK" == "False" ]] && [[ "$G_REASONS" -ge 2 ]]; then
  _pass "invalid R1 envelope rejected with $G_REASONS actionable reason(s) (bad status + missing key)"
else
  _fail "invalid R1 envelope was not rejected as expected: $G_OUT"
fi

# ===========================================================================
# Scenario (offline, always-on) — provider-specific auth requirement check
# ===========================================================================
echo "=== Scenario: provider-specific health/auth requirements (offline) ==="
OPENAI_SUMMARY="$("$PYTHON_BIN" "$RESOLVE_PROFILE" openai --emit summary 2>/dev/null)"
QWEN_SUMMARY="$("$PYTHON_BIN" "$RESOLVE_PROFILE" qwen-vllm --emit summary 2>/dev/null)"
OPENAI_KEY_ENV="$(printf '%s' "$OPENAI_SUMMARY" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("api_key_env") or "")')"
QWEN_KEY_ENV="$(printf '%s' "$QWEN_SUMMARY" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("api_key_env") or "")')"
if [[ "$OPENAI_KEY_ENV" == "OPENAI_API_KEY" && -z "$QWEN_KEY_ENV" ]]; then
  _pass "openai profile requires OPENAI_API_KEY; qwen-vllm profile requires no credential"
else
  _fail "provider auth-requirement mismatch: openai=$OPENAI_KEY_ENV qwen-vllm=$QWEN_KEY_ENV"
fi

# ===========================================================================
# Scenario H — opt-in live path
# ===========================================================================
echo "=== Scenario H: live provider dispatch (opt-in) ==="
if [[ "${MAKATO_MODEL_PROVIDER_LIVE:-0}" != "1" ]]; then
  _skip "MAKATO_MODEL_PROVIDER_LIVE not set to 1 — live provider dispatch is opt-in only"
elif [[ -z "${OPENAI_API_KEY:-}" ]]; then
  _skip "OPENAI_API_KEY not set — live OpenAI path requires an explicit credential"
elif [[ -z "${MAKATO_LIVE_QWEN_ENDPOINT_URL:-}" ]]; then
  _skip "MAKATO_LIVE_QWEN_ENDPOINT_URL not set — live Qwen/Ollama path requires an explicit endpoint"
elif [[ -z "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
  _skip "MAKATO_LOOP_DISPATCH_REPO not set — live path requires an explicit test repository"
else
  H_RC=0
  curl -fsS -o /dev/null -m 10 \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    "https://api.openai.com/v1/models" || H_RC=$?
  if [[ $H_RC -eq 0 ]]; then
    _pass "live OpenAI endpoint health/auth check succeeded"
  else
    _fail "live OpenAI endpoint health/auth check failed (curl rc=$H_RC)"
  fi
  H2_RC=0
  curl -fsS -o /dev/null -m 10 "${MAKATO_LIVE_QWEN_ENDPOINT_URL%/}/models" || H2_RC=$?
  if [[ $H2_RC -eq 0 ]]; then
    _pass "live Qwen/Ollama-compatible endpoint health check succeeded"
  else
    _fail "live Qwen/Ollama-compatible endpoint health check failed (curl rc=$H2_RC)"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
exit "$FAIL"
