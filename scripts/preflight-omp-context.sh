#!/usr/bin/env bash
# Profile-aware OMP compatibility preflight (local-openai-gpt-macos-compatibility,
# Task 5). Verifies the endpoint/auth/tool contract for the model profile
# selected via MAKATO_MODEL_PROFILE (config/model-profiles.yml: openai |
# qwen-vllm | apple-ollama) before dispatching the po-agent. Exits 0 with a
# confirmation line on pass; exits 1 with an actionable error on failure.
# Never reads or echoes a credential VALUE — only whether the profile's
# declared api_key_env is present in the environment.
#
# Usage:
#   MAKATO_MODEL_PROFILE=openai scripts/preflight-omp-context.sh
#   VLLM_API_BASE=http://host:8100 scripts/preflight-omp-context.sh   # qwen-vllm override
#   OPENAI_BASE_URL=https://api.openai.com/v1 scripts/preflight-omp-context.sh
#   MAKATO_APPLE_OLLAMA_BASE_URL=http://localhost:11434/v1 scripts/preflight-omp-context.sh
#
# Defaults to MAKATO_MODEL_PROFILE=qwen-vllm (the checked-in local-vLLM
# default) when unset, so every existing remote-Linux caller (systemd
# ExecStartPre, docs/vast-ai-llm-deployment.md) keeps working unchanged.
#
# Env overrides: MAKATO_MODEL_PROFILE, MODEL_PROFILES_FILE, OMP_MODELS_FILE,
#   OMP_CONFIG_FILE, MAKATO_PYTHON_BIN, VLLM_API_BASE, OPENAI_BASE_URL,
#   MAKATO_APPLE_OLLAMA_BASE_URL.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${REPO_ROOT}/scripts/resolve-model-profile.py"
PROFILES_FILE="${MODEL_PROFILES_FILE:-${REPO_ROOT}/config/model-profiles.yml}"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"
CONFIG_FILE="infra/vllm-serve.yaml"
OMP_MODELS_FILE="${OMP_MODELS_FILE:-${HOME:-/root}/.omp/agent/models.yml}"
OMP_CONFIG_FILE="${OMP_CONFIG_FILE:-${HOME:-/root}/.omp/agent/config.yml}"

# The canonical Makato model roles (mirrors scripts/resolve-model-profile.py
# EXPECTED_ROLES — a copy on purpose, since this is a shell script).
EXPECTED_ROLES=(default task smol tiny plan advisor designer commit slow vision orchestrator)

# Print the scalar value of the first `<key>:` inside the block reached by the
# space-separated top-level key path (e.g. "providers local"). With --direct,
# only the block's immediate children count. Scoping matters because the
# installer merges into the user's files, so other blocks (other providers,
# retry.fallbackChains.default, ...) can carry same-named keys earlier on.
# Reads block-style YAML only — the layout the installer and PyYAML write.
omp_yaml_get() {
  local direct=0
  if [ "$1" = "--direct" ]; then
    direct=1
    shift
  fi
  awk -v path="$2" -v key="$3" -v direct="$direct" '
    BEGIN { depth = split(path, levels, " "); matched = 0; child_indent[0] = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */)
      indent = RLENGTH
      line = substr($0, indent + 1)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      while (matched > 0 && indent <= level_indent[matched]) matched--
      if (matched < depth) {
        if (child_indent[matched] < 0) child_indent[matched] = indent
        if (indent == child_indent[matched] && line == levels[matched + 1] ":") {
          matched++
          level_indent[matched] = indent
          child_indent[matched] = -1
        }
        next
      }
      if (child_indent[depth] < 0) child_indent[depth] = indent
      if (direct && indent != child_indent[depth]) next
      sub(/^- +/, "", line)
      if (index(line, key ":") != 1) next
      value = substr(line, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
      print value
      exit
    }
  ' "$1"
}

MAKATO_MODEL_PROFILE="${MAKATO_MODEL_PROFILE:-qwen-vllm}"
PROFILE="$MAKATO_MODEL_PROFILE"

if [ ! -f "$RESOLVER" ]; then
  echo "ERROR: profile resolver not found at ${RESOLVER}" >&2
  exit 1
fi

# Structural validation (malformed/unsupported profile, missing role, bad
# tool_format) happens inside resolve-model-profile.py — its stderr already
# flows straight through to this script's stderr on failure.
SUMMARY_JSON="$("$PYTHON_BIN" "$RESOLVER" "$PROFILE" --config "$PROFILES_FILE" --emit summary)" || {
  echo "ERROR: profile '${PROFILE}' failed structural validation — see resolver output above" >&2
  exit 1
}

PROVIDER=""
BASE_URL=""
API_KEY_ENV=""
TOOL_FORMAT=""
REQUIRED=""
MAX_OUTPUT=""
ROLE_MODELS=""
while IFS=$'\t' read -r record_type key value; do
  if [ "$record_type" = "scalar" ]; then
    case "$key" in
      provider) PROVIDER="$value" ;;
      base_url) BASE_URL="$value" ;;
      api_key_env) API_KEY_ENV="$value" ;;
      tool_format) TOOL_FORMAT="$value" ;;
      context_window) REQUIRED="$value" ;;
      max_tokens) MAX_OUTPUT="$value" ;;
    esac
  elif [ "$record_type" = "role" ]; then
    ROLE_MODELS="${ROLE_MODELS}${key}"$'\t'"${value}"$'\n'
  fi
done < <(printf '%s' "$SUMMARY_JSON" | "$PYTHON_BIN" -c '
import json
import sys

profile = json.load(sys.stdin)
for key in ("provider", "base_url", "api_key_env", "tool_format", "context_window", "max_tokens"):
    print("scalar\t{}\t{}".format(key, profile.get(key) or ""))
for role, model in profile["roles"].items():
    print(f"role\t{role}\t{model}")
')

# ── Presence-only credential check (never the value) ─────────────────────────
if [ -n "$API_KEY_ENV" ]; then
  if ! "$PYTHON_BIN" -c 'import os, sys; sys.exit(0 if os.environ.get(sys.argv[1]) else 1)' "$API_KEY_ENV"; then
    echo "ERROR: profile '${PROFILE}' requires credential env var ${API_KEY_ENV} to be set (value not shown)" >&2
    exit 1
  fi
fi

# ── Endpoint resolution (profile-specific override, then profile default) ────
case "$PROFILE" in
  qwen-vllm)
    EFFECTIVE_BASE="${VLLM_API_BASE:-http://localhost:8100}"
    ;;
  openai)
    EFFECTIVE_BASE="${OPENAI_BASE_URL:-$BASE_URL}"
    ;;
  apple-ollama)
    EFFECTIVE_BASE="${MAKATO_APPLE_OLLAMA_BASE_URL:-$BASE_URL}"
    ;;
  *)
    EFFECTIVE_BASE="$BASE_URL"
    ;;
esac

# ── Provider-specific health/tool probe ───────────────────────────────────────
if [ "$PROFILE" = "qwen-vllm" ]; then
  # Deep probe: the local/remote vLLM endpoint must report a context window
  # at least as large as the profile requires (preserves the pre-existing
  # contract documented in docs/vast-ai-llm-deployment.md).
  MODELS_URL="${EFFECTIVE_BASE}/v1/models"
  response=$(curl -sf --max-time 10 "$MODELS_URL" 2>&1) || {
    echo "ERROR: endpoint unreachable — ${MODELS_URL}" >&2
    echo "  Check that vllm.service is running: systemctl status vllm" >&2
    echo "  Required context_length: ${REQUIRED}" >&2
    exit 1
  }

  context_length=$("$PYTHON_BIN" - "$response" "$REQUIRED" <<'PYEOF'
import sys, json

raw, required = sys.argv[1], int(sys.argv[2])
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"ERROR: could not parse /v1/models response: {exc}", file=sys.stderr)
    sys.exit(1)

models = data.get("data", [])
if not models:
    print("ERROR: /v1/models returned no model entries", file=sys.stderr)
    sys.exit(1)

# Prefer the entry served as "open"; fall back to the first entry.
target = next((m for m in models if "open" in m.get("id", "")), models[0])

# vLLM exposes the context window under max_model_len or context_length.
ctx = target.get("max_model_len") or target.get("context_length")
if ctx is None:
    print("ERROR: neither max_model_len nor context_length found in model entry", file=sys.stderr)
    sys.exit(1)

print(ctx)
PYEOF
  ) || exit 1

  if [ "$context_length" -lt "$REQUIRED" ]; then
    echo "ERROR: context_length=${context_length} is below the required minimum of ${REQUIRED}" >&2
    echo "  Fix: set max_model_len: ${REQUIRED} (or higher) in ${CONFIG_FILE}" >&2
    echo "  Then restart the service: sudo systemctl restart vllm" >&2
    exit 1
  fi
  HEALTH_SUMMARY="context_length=${context_length}"
else
  # Native OpenAI / Apple-local Ollama: a lighter reachability probe.
  # Presence-only credentials mean we never send the key here — any HTTP
  # status code (including 401/403 on an auth-gated endpoint) proves the
  # network path, DNS, and TLS are working; only a connection-level failure
  # ("000") is treated as unreachable.
  MODELS_URL="${EFFECTIVE_BASE}/models"
  # curl's -w '%{http_code}' already prints "000" on a connection-level
  # failure, so the fallback below only covers the case where curl produced
  # no output at all (e.g. the binary itself failed to start).
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$MODELS_URL" 2>/dev/null) || true
  [ -z "$http_code" ] && http_code="000"
  if [ "$http_code" = "000" ]; then
    echo "ERROR: endpoint unreachable — ${MODELS_URL}" >&2
    if [ "$PROFILE" = "apple-ollama" ]; then
      echo "  Check that the local Ollama server is running: ollama serve" >&2
    else
      echo "  Check network/DNS/TLS access to ${EFFECTIVE_BASE}" >&2
    fi
    exit 1
  fi
  HEALTH_SUMMARY="endpoint reachable (HTTP ${http_code})"
fi

# ── OMP file presence + provider-neutral role/tool-format check ──────────────
if [ ! -f "$OMP_MODELS_FILE" ]; then
  echo "ERROR: OMP model configuration not found at ${OMP_MODELS_FILE}" >&2
  exit 1
fi
if [ ! -f "$OMP_CONFIG_FILE" ]; then
  echo "ERROR: OMP settings configuration not found at ${OMP_CONFIG_FILE}" >&2
  exit 1
fi

# Validate the installed OMP model budgets as well as the provider response.
# This catches stale or hand-edited runtime files before dispatch.
omp_context=$(omp_yaml_get "$OMP_MODELS_FILE" "providers ${PROVIDER}" contextWindow)
omp_output=$(omp_yaml_get "$OMP_MODELS_FILE" "providers ${PROVIDER}" maxTokens)
if ! [[ "$omp_context" =~ ^[0-9]+$ && "$omp_output" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ${OMP_MODELS_FILE} must define numeric OMP fields contextWindow and maxTokens under providers.${PROVIDER}" >&2
  exit 1
fi
if [ "$omp_context" -lt "$REQUIRED" ]; then
  echo "ERROR: OMP contextWindow=${omp_context} is below the profile minimum ${REQUIRED}" >&2
  exit 1
fi
if [ "$omp_output" -gt "$MAX_OUTPUT" ]; then
  echo "ERROR: OMP maxTokens=${omp_output} exceeds the profile limit ${MAX_OUTPUT}" >&2
  exit 1
fi

omp_tool_format=$(omp_yaml_get --direct "$OMP_CONFIG_FILE" tools format)
if [ "$omp_tool_format" != "$TOOL_FORMAT" ]; then
  echo "ERROR: OMP tools.format must be '${TOOL_FORMAT}' for profile '${PROFILE}' in ${OMP_CONFIG_FILE} (got '${omp_tool_format:-missing}')" >&2
  exit 1
fi

for role in "${EXPECTED_ROLES[@]}"; do
  expected_model=""
  while IFS=$'\t' read -r mapped_role mapped_model; do
    if [ "$mapped_role" = "$role" ]; then
      expected_model="$mapped_model"
      break
    fi
  done <<<"$ROLE_MODELS"
  if [ -z "$expected_model" ]; then
    echo "ERROR: resolved profile '${PROFILE}' is missing the '${role}' role mapping" >&2
    exit 1
  fi
  expected="${PROVIDER}/${expected_model}"
  actual=$(omp_yaml_get --direct "$OMP_CONFIG_FILE" modelRoles "$role")
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: OMP role '${role}' must map to '${expected}' for profile '${PROFILE}' in ${OMP_CONFIG_FILE} (got '${actual:-missing}')" >&2
    exit 1
  fi
done

echo "OK: profile=${PROFILE} provider=${PROVIDER} ${HEALTH_SUMMARY}; OMP contextWindow=${omp_context}, maxTokens=${omp_output}, tools.format=${omp_tool_format} — po-agent dispatch is safe"
