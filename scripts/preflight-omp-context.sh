#!/usr/bin/env bash
# Verify the vLLM endpoint has a context window >= 65536 before dispatching the po-agent.
# Exits 0 with a confirmation line on pass; exits 1 with an actionable error on failure.
#
# Usage: VLLM_API_BASE=http://host:8100 scripts/preflight-omp-context.sh
# Defaults to http://localhost:8100 when VLLM_API_BASE is unset.

set -euo pipefail

REQUIRED=65536
MAX_OUTPUT=8192
BASE="${VLLM_API_BASE:-http://localhost:8100}"
MODELS_URL="${BASE}/v1/models"
CONFIG_FILE="infra/vllm-serve.yaml"
OMP_MODELS_FILE="${OMP_MODELS_FILE:-${HOME:-/root}/.omp/agent/models.yml}"
OMP_CONFIG_FILE="${OMP_CONFIG_FILE:-${HOME:-/root}/.omp/agent/config.yml}"

response=$(curl -sf --max-time 10 "$MODELS_URL" 2>&1) || {
  echo "ERROR: endpoint unreachable — ${MODELS_URL}" >&2
  echo "  Check that vllm.service is running: systemctl status vllm" >&2
  echo "  Required context_length: ${REQUIRED}" >&2
  exit 1
}

context_length=$(python3 - "$response" "$REQUIRED" <<'PYEOF'
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

if [ ! -f "$OMP_MODELS_FILE" ]; then
  echo "ERROR: OMP model configuration not found at ${OMP_MODELS_FILE}" >&2
  exit 1
fi
if [ ! -f "$OMP_CONFIG_FILE" ]; then
  echo "ERROR: OMP settings configuration not found at ${OMP_CONFIG_FILE}" >&2
  exit 1
fi

omp_context=$(sed -nE 's/^[[:space:]]*contextWindow:[[:space:]]*([0-9]+).*/\1/p' "$OMP_MODELS_FILE" | head -1)
omp_output=$(sed -nE 's/^[[:space:]]*maxTokens:[[:space:]]*([0-9]+).*/\1/p' "$OMP_MODELS_FILE" | head -1)

if [ -z "$omp_context" ] || [ -z "$omp_output" ]; then
  echo "ERROR: ${OMP_MODELS_FILE} must define OMP v18 fields contextWindow and maxTokens" >&2
  exit 1
fi
if [ "$omp_context" -lt "$REQUIRED" ]; then
  echo "ERROR: OMP contextWindow=${omp_context} is below ${REQUIRED}" >&2
  exit 1
fi
if [ "$omp_output" -gt "$MAX_OUTPUT" ]; then
  echo "ERROR: OMP maxTokens=${omp_output} exceeds the safe ${MAX_OUTPUT}-token output budget" >&2
  exit 1
fi

for role in default opus sonnet haiku smol slow plan; do
  role_model=$(sed -nE "s/^[[:space:]]*${role}:[[:space:]]*([^#[:space:]]+).*/\\1/p" "$OMP_CONFIG_FILE" | head -1)
  if [ "$role_model" != "local/open" ]; then
    echo "ERROR: OMP role ${role} must map to local/open in ${OMP_CONFIG_FILE} (got '${role_model:-missing}')" >&2
    exit 1
  fi
done

tool_format=$(sed -nE 's/^[[:space:]]*format:[[:space:]]*([^#[:space:]]+).*/\1/p' "$OMP_CONFIG_FILE" | head -1)
if [ "$tool_format" != "qwen3" ]; then
  echo "ERROR: OMP tools.format must be qwen3 in ${OMP_CONFIG_FILE} (got '${tool_format:-missing}')" >&2
  exit 1
fi

echo "OK: context_length=${context_length}; OMP contextWindow=${omp_context}, maxTokens=${omp_output}, roles=local/open, tools.format=${tool_format} — po-agent dispatch is safe"
