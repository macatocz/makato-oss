#!/usr/bin/env bash
# Verify the vLLM endpoint has a context window >= 65536 before dispatching the po-agent.
# Exits 0 with a confirmation line on pass; exits 1 with an actionable error on failure.
#
# Usage: VLLM_API_BASE=http://host:8100 scripts/preflight-omp-context.sh
# Defaults to http://localhost:8100 when VLLM_API_BASE is unset.

set -euo pipefail

REQUIRED=65536
BASE="${VLLM_API_BASE:-http://localhost:8100}"
MODELS_URL="${BASE}/v1/models"
CONFIG_FILE="infra/vllm-serve.yaml"

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

if [ "$context_length" -ge "$REQUIRED" ]; then
  echo "OK: context_length=${context_length} >= ${REQUIRED} — po-agent dispatch is safe"
  exit 0
else
  echo "ERROR: context_length=${context_length} is below the required minimum of ${REQUIRED}" >&2
  echo "  Fix: set max_model_len: ${REQUIRED} (or higher) in ${CONFIG_FILE}" >&2
  echo "  Then restart the service: sudo systemctl restart vllm" >&2
  exit 1
fi
