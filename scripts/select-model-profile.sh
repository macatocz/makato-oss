#!/usr/bin/env bash
# Merge a Makato model profile, plus the shared agent-role overrides from
# config/agent-roles.yml, into OMP's runtime configuration — or preview what
# would be merged. Never prints a credential value or the content of an
# existing OMP file; scripts/resolve-model-profile.py validates and merges.
#
# Usage:
#   scripts/select-model-profile.sh <profile> [--dry-run]
#   scripts/select-model-profile.sh --agents-only [--dry-run]
#
# <profile> is one of the names declared in config/model-profiles.yml
# (openai | qwen-vllm | apple-ollama by default). Installing it updates only
# the canonical modelRoles keys, tools.format and the makato agent keys of
# task.agentModelOverrides in ~/.omp/agent/config.yml, and only
# providers.<provider>.{baseUrl,apiKey,models} in ~/.omp/agent/models.yml.
# Custom roles, other agents' overrides, other providers and every other
# setting are kept; YAML comments in a merged file are not. Both files are
# validated before either is written. Merging into an existing file needs
# PyYAML in MAKATO_PYTHON_BIN.
#
# --agents-only: merge only the agent → "@<role>" overrides into config.yml,
#   for users who pick each role's model in OMP /model → Roles themselves.
#   Leaves modelRoles, tools and models.yml alone and needs no credential.
#
# --dry-run: validate and print only the fragments that would be merged,
#   reading and writing neither OMP file and requiring no credential. Safe to
#   run in CI.
#
# A real profile install requires the profile's api_key_env (if any) to be
# set before any file is touched. Its VALUE is read only at write time and
# goes straight into models.yml (mode 600) — never to stdout, stderr or logs.
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
  echo "       $0 --agents-only [--dry-run]" >&2
  exit 2
}

PROFILE=""
AGENTS_ONLY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --agents-only)
      AGENTS_ONLY=1
      ;;
    -*)
      echo "ERROR: unknown argument '${arg}'" >&2
      usage
      ;;
    *)
      if [ -n "$PROFILE" ]; then
        echo "ERROR: unexpected argument '${arg}'" >&2
        usage
      fi
      PROFILE="$arg"
      ;;
  esac
done

if [ "$AGENTS_ONLY" -eq 1 ] && [ -n "$PROFILE" ]; then
  echo "ERROR: --agents-only takes no profile" >&2
  usage
fi
if [ "$AGENTS_ONLY" -eq 0 ] && [ -z "$PROFILE" ]; then
  usage
fi

if [ ! -f "$RESOLVER" ]; then
  echo "ERROR: resolver not found at ${RESOLVER}" >&2
  exit 1
fi

MERGE_ARGS=(--merge --omp-config "$OMP_CONFIG_FILE")
if [ -n "$PROFILE" ]; then
  MERGE_ARGS=("$PROFILE" --config "$PROFILES_FILE" --omp-models "$OMP_MODELS_FILE" "${MERGE_ARGS[@]}")
fi
if [ "$DRY_RUN" -eq 1 ]; then
  MERGE_ARGS+=(--dry-run)
fi

exec "$PYTHON_BIN" "$RESOLVER" "${MERGE_ARGS[@]}"
