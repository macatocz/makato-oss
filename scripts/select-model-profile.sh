#!/usr/bin/env bash
# Safely install (or dry-run preview) a Makato model profile into OMP's
# runtime configuration. Never prints credential values — see
# config/model-profiles.yml and scripts/resolve-model-profile.py for the
# redaction contract this script depends on.
#
# Usage:
#   scripts/select-model-profile.sh <profile> [--dry-run]
#
# <profile> is one of the names declared in config/model-profiles.yml
# (openai | qwen-vllm | apple-ollama by default).
#
# --dry-run: validate the profile and print the OMP provider/role documents
#   that WOULD be installed, without touching ~/.omp/agent/*.yml and without
#   requiring any credential to be present. Safe to run in CI.
#
# Without --dry-run (a real install — "execution time"): validates the
#   profile, then — only if the profile declares a non-empty api_key_env —
#   requires that environment variable to be set. The credential VALUE is
#   substituted only at this step, written directly into the local
#   ~/.omp/agent/models.yml file; it is never echoed to stdout, stderr, or
#   any log.
#
# Env overrides: MODEL_PROFILES_FILE, OMP_MODELS_FILE, OMP_CONFIG_FILE,
#   MAKATO_PYTHON_BIN.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${REPO_ROOT}/scripts/resolve-model-profile.py"
PROFILES_FILE="${MODEL_PROFILES_FILE:-${REPO_ROOT}/config/model-profiles.yml}"
OMP_MODELS_FILE="${OMP_MODELS_FILE:-${HOME:-/root}/.omp/agent/models.yml}"
OMP_CONFIG_FILE="${OMP_CONFIG_FILE:-${HOME:-/root}/.omp/agent/config.yml}"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"

usage() {
  echo "Usage: $0 <profile> [--dry-run]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
PROFILE="$1"
shift

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      echo "ERROR: unknown argument '${arg}'" >&2
      usage
      ;;
  esac
done

if [ ! -f "$RESOLVER" ]; then
  echo "ERROR: resolver not found at ${RESOLVER}" >&2
  exit 1
fi

# Structural validation + document generation. resolve-model-profile.py never
# reads or prints credential values — errors here are always structural
# (unsupported profile, missing role, bad tool_format, malformed endpoint).
MODELS_DOC="$("$PYTHON_BIN" "$RESOLVER" "$PROFILE" --config "$PROFILES_FILE" --emit omp-models)"
CONFIG_DOC="$("$PYTHON_BIN" "$RESOLVER" "$PROFILE" --config "$PROFILES_FILE" --emit omp-config)"
SUMMARY_JSON="$("$PYTHON_BIN" "$RESOLVER" "$PROFILE" --config "$PROFILES_FILE" --emit summary)"

API_KEY_ENV="$(printf '%s' "$SUMMARY_JSON" | "$PYTHON_BIN" -c 'import json, sys; d = json.load(sys.stdin); print(d.get("api_key_env") or "")')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "# --- dry-run: ${OMP_MODELS_FILE} (not written) ---"
  printf '%s\n' "$MODELS_DOC"
  echo "# --- dry-run: ${OMP_CONFIG_FILE} (not written) ---"
  printf '%s\n' "$CONFIG_DOC"
  exit 0
fi

# Credentials are required only at execution time (this branch), never at
# --dry-run/parse time. Check presence via Python so the value itself is
# never interpolated into this shell script's process listing or history.
if [ -n "$API_KEY_ENV" ]; then
  if ! "$PYTHON_BIN" -c 'import os, sys; sys.exit(0 if os.environ.get(sys.argv[1]) else 1)' "$API_KEY_ENV"; then
    echo "ERROR: profile '${PROFILE}' requires credential env var ${API_KEY_ENV} to be set before install (value not shown)" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$OMP_MODELS_FILE")" "$(dirname "$OMP_CONFIG_FILE")"

if [ -n "$API_KEY_ENV" ]; then
  # Substitute the ${VAR} placeholder with the real value directly into the
  # file on disk — the value passes through this process's environment and a
  # short-lived Python subprocess only, never through stdout/stderr/logs.
  printf '%s\n' "$MODELS_DOC" | "$PYTHON_BIN" -c '
import os
import sys

key_name = sys.argv[1]
value = os.environ[key_name]
text = sys.stdin.read()
text = text.replace("${" + key_name + "}", value)
sys.stdout.write(text)
' "$API_KEY_ENV" > "$OMP_MODELS_FILE"
else
  printf '%s\n' "$MODELS_DOC" > "$OMP_MODELS_FILE"
fi
printf '%s\n' "$CONFIG_DOC" > "$OMP_CONFIG_FILE"
chmod 600 "$OMP_MODELS_FILE"

echo "OK: installed profile '${PROFILE}' -> ${OMP_MODELS_FILE}, ${OMP_CONFIG_FILE}"
