#!/usr/bin/env bash
# Gate 6 provider-aware runtime preflight (local-openai-gpt-macos-compatibility,
# Task 5). This is the single command build-verify's Gate 6 (Step 8b) runs
# for this story via the plan's `## Runtime verification` section:
#
#   MAKATO_MODEL_PROFILE=openai bash scripts/preflight-model-runtime.sh
#
# Resolves MAKATO_MODEL_PROFILE (default: qwen-vllm — the checked-in
# credential-free local-vLLM default, preserved unchanged when the variable
# is unset), validates the profile structurally via
# scripts/resolve-model-profile.py, then delegates the endpoint/auth/tool
# compatibility probe to scripts/preflight-omp-context.sh.
#
# Exits nonzero with an actionable stderr message for: a malformed/
# unsupported profile, a missing required credential, an unreachable
# required provider endpoint, or a tool-format/OMP-role mismatch.
#
# Optional services (Playwright MCP, Langfuse, Postgres, Temporal,
# Sagibeast/testbox) are reported via scripts/preflight-optional-services.sh
# for visibility only — an unhealthy optional service is always PASS/SKIP/
# WARN, NEVER silently healthy, and NEVER affects this script's exit code.
#
# Usage:
#   scripts/preflight-model-runtime.sh
#   MAKATO_MODEL_PROFILE=openai scripts/preflight-model-runtime.sh
#   MAKATO_SKIP_OPTIONAL_PREFLIGHT=1 scripts/preflight-model-runtime.sh   # required checks only
#
# Env overrides: MAKATO_MODEL_PROFILE, MODEL_PROFILES_FILE, OMP_MODELS_FILE,
#   OMP_CONFIG_FILE, MAKATO_PYTHON_BIN, MAKATO_SKIP_OPTIONAL_PREFLIGHT.
#
# Exit codes: 0 required provider checks pass; 1 a required check failed or
# a script dependency is missing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${REPO_ROOT}/scripts/resolve-model-profile.py"
PROFILES_FILE="${MODEL_PROFILES_FILE:-${REPO_ROOT}/config/model-profiles.yml}"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"
CONTEXT_PREFLIGHT="${REPO_ROOT}/scripts/preflight-omp-context.sh"
OPTIONAL_PREFLIGHT="${REPO_ROOT}/scripts/preflight-optional-services.sh"

MAKATO_MODEL_PROFILE="${MAKATO_MODEL_PROFILE:-qwen-vllm}"
PROFILE="$MAKATO_MODEL_PROFILE"

if [ ! -f "$RESOLVER" ]; then
  echo "ERROR: profile resolver not found at ${RESOLVER}" >&2
  exit 1
fi
if [ ! -f "$PROFILES_FILE" ]; then
  echo "ERROR: model-profiles.yml not found at ${PROFILES_FILE}" >&2
  exit 1
fi
if [ ! -f "$CONTEXT_PREFLIGHT" ]; then
  echo "ERROR: required provider probe not found at ${CONTEXT_PREFLIGHT}" >&2
  exit 1
fi

echo "=== Gate 6: model-runtime preflight (profile=${PROFILE}) ==="

# Structural validation first — a malformed/unsupported profile fails fast
# with an actionable message (from the resolver's own stderr) before any
# network probe is attempted.
if ! "$PYTHON_BIN" "$RESOLVER" "$PROFILE" --config "$PROFILES_FILE" --emit summary >/dev/null; then
  echo "ERROR: profile '${PROFILE}' failed structural validation — see resolver output above" >&2
  exit 1
fi

REQUIRED_STATUS=0
MAKATO_MODEL_PROFILE="$PROFILE" MODEL_PROFILES_FILE="$PROFILES_FILE" MAKATO_PYTHON_BIN="$PYTHON_BIN" \
  bash "$CONTEXT_PREFLIGHT" || REQUIRED_STATUS=$?

if [ "$REQUIRED_STATUS" -ne 0 ]; then
  echo "ERROR: Gate 6 required provider probe failed for profile '${PROFILE}' (see above)" >&2
fi

if [ "${MAKATO_SKIP_OPTIONAL_PREFLIGHT:-0}" != "1" ] && [ -f "$OPTIONAL_PREFLIGHT" ]; then
  echo ""
  echo "=== Gate 6: optional-service checks (advisory — never block) ==="
  bash "$OPTIONAL_PREFLIGHT" || true
fi

if [ "$REQUIRED_STATUS" -ne 0 ]; then
  exit 1
fi

echo ""
echo "OK: Gate 6 model-runtime preflight passed for profile '${PROFILE}'"
