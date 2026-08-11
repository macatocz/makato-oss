#!/usr/bin/env bash
# inject-otlp-keys.sh — Idempotent OTLP ingest key provisioner for Langfuse.
#
# Reads each project's OTLP ingest key from:
#   1. Environment variables (MAKATO_LANGFUSE_KEY / SAGIBEAST_LANGFUSE_KEY), or
#   2. The Langfuse Management API (requires LANGFUSE_ADMIN_SECRET_KEY)
#
# Then writes the resolved keys into the omp dispatch env file (.env.dispatch)
# and exports them as shell variables for the current session.
#
# IDEMPOTENCY: running this script multiple times is safe — it overwrites
# the key entries in .env.dispatch in place and never duplicates them.
#
# Usage:
#   bash scripts/inject-otlp-keys.sh
#   bash scripts/inject-otlp-keys.sh --env-file /path/to/custom.env
#   bash scripts/inject-otlp-keys.sh --dry-run   # print resolved keys, do not write
#
# Environment variables (supply via shell or .env):
#   LANGFUSE_HOST            — Langfuse base URL (default: http://localhost:3000)
#   LANGFUSE_ADMIN_SECRET_KEY — admin API key for the Management API
#   MAKATO_LANGFUSE_KEY      — pre-supplied key (skips API call for makato project)
#   SAGIBEAST_LANGFUSE_KEY   — pre-supplied key (skips API call for sagibeast project)
#   ENV_FILE                 — path to dispatch env file (default: .env.dispatch)
#
# CI dispatch note:
#   In CI pipelines, set MAKATO_LANGFUSE_KEY and SAGIBEAST_LANGFUSE_KEY as
#   secrets and the API call branch is skipped entirely — no admin key needed.
#
# Exit codes:
#   0 — keys injected (or --dry-run completed)
#   1 — fatal error (Langfuse unreachable, key resolution failed, write error)

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
ENV_FILE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --env-file)  ENV_FILE_ARG="$2"; shift 2 ;;
    *)           echo "[inject-otlp-keys] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Configuration ─────────────────────────────────────────────────────────────
LANGFUSE_HOST="${LANGFUSE_HOST:-http://localhost:3000}"
ADMIN_KEY="${LANGFUSE_ADMIN_SECRET_KEY:-}"
ENV_FILE="${ENV_FILE_ARG:-${ENV_FILE:-.env.dispatch}}"

MAKATO_KEY_ENV="${MAKATO_LANGFUSE_KEY:-}"
SAGIBEAST_KEY_ENV="${SAGIBEAST_LANGFUSE_KEY:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[inject-otlp-keys] $*"; }
warn() { echo "[inject-otlp-keys] WARN: $*" >&2; }
die()  { echo "[inject-otlp-keys] ERROR: $*" >&2; exit 1; }

# Fetch all projects via the Langfuse API and return the OTLP key for a named project.
# Args: <project-name>
# Returns: key on stdout; empty string if project not found.
_fetch_key_from_api() {
  local project_name="$1"

  if [[ -z "$ADMIN_KEY" ]]; then
    warn "LANGFUSE_ADMIN_SECRET_KEY not set; cannot fetch key for '${project_name}' from API."
    return 0
  fi

  # List projects — Langfuse Management API endpoint (v2+).
  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${ADMIN_KEY}" \
    "${LANGFUSE_HOST}/api/public/projects" 2>/dev/null) || {
    warn "Could not reach Langfuse API at ${LANGFUSE_HOST}"
    return 0
  }

  # Extract the public key for the matching project name.
  # jq returns empty string if no match.
  local key
  key=$(echo "$response" | jq -r --arg name "$project_name" \
    '.data[]? | select(.name == $name) | .publicKey // empty' 2>/dev/null || true)

  echo "$key"
}

# Create a Langfuse project via the Admin API and return its public OTLP key.
# Falls back gracefully when LANGFUSE_ADMIN_SECRET_KEY is unset or the API call fails.
# Args: <project-name>
# Returns: new project's public key on stdout; empty string on failure.
_create_langfuse_project() {
  local project_name="$1"

  if [[ -z "$ADMIN_KEY" ]]; then
    warn "LANGFUSE_ADMIN_SECRET_KEY not set; cannot auto-create project '${project_name}'."
    return 0
  fi

  local response
  response=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${project_name}\"}" \
    "${LANGFUSE_HOST}/api/admin/projects" 2>/dev/null) || {
    warn "Could not create project '${project_name}' via Admin API at ${LANGFUSE_HOST}/api/admin/projects"
    return 0
  }

  # Langfuse Admin API returns project data; extract public key.
  local key
  key=$(echo "$response" | jq -r '.data.publicKey // .publicKey // empty' 2>/dev/null || true)
  echo "$key"
}

# Write or overwrite a KEY=VALUE pair in the env file.
# Preserves all other lines; replaces the existing line if the key already exists.
_upsert_env_var() {
  local file="$1" key="$2" value="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] would write ${key}=<redacted> to ${file}"
    return
  fi

  mkdir -p "$(dirname "$file")"

  if [[ -f "$file" ]] && grep -q "^${key}=" "$file" 2>/dev/null; then
    # Key exists — overwrite in place using portable sed.
    local tmp
    tmp=$(mktemp)
    sed "s|^${key}=.*|${key}=${value}|" "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    # Key absent — append.
    echo "${key}=${value}" >> "$file"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Resolving OTLP ingest keys (host: ${LANGFUSE_HOST})"

# ── makato project key ────────────────────────────────────────────────────────
MAKATO_KEY=""
if [[ -n "$MAKATO_KEY_ENV" ]]; then
  MAKATO_KEY="$MAKATO_KEY_ENV"
  log "makato key: using pre-supplied env var (MAKATO_LANGFUSE_KEY)"
else
  log "makato key: fetching from Langfuse API..."
  MAKATO_KEY="$(_fetch_key_from_api "makato")"
  if [[ -z "$MAKATO_KEY" ]]; then
    die "Could not resolve OTLP key for 'makato' project. Set MAKATO_LANGFUSE_KEY or ensure the project exists in Langfuse."
  fi
  log "makato key: resolved from API"
fi

# ── sagibeast project key ─────────────────────────────────────────────────────
SAGIBEAST_KEY=""
if [[ -n "$SAGIBEAST_KEY_ENV" ]]; then
  SAGIBEAST_KEY="$SAGIBEAST_KEY_ENV"
  log "sagibeast key: using pre-supplied env var (SAGIBEAST_LANGFUSE_KEY)"
else
  log "sagibeast key: fetching from Langfuse API..."
  SAGIBEAST_KEY="$(_fetch_key_from_api "sagibeast")"
  if [[ -z "$SAGIBEAST_KEY" ]]; then
    log "sagibeast key: project not found — creating via Langfuse Admin API..."
    SAGIBEAST_KEY="$(_create_langfuse_project "sagibeast")"
  fi
  if [[ -z "$SAGIBEAST_KEY" ]]; then
    die "Could not resolve OTLP key for 'sagibeast' project. Set SAGIBEAST_LANGFUSE_KEY or ensure LANGFUSE_ADMIN_SECRET_KEY is set to allow automatic project creation."
  fi
  log "sagibeast key: resolved (fetched or created)"
fi

# ── Inject into dispatch env ──────────────────────────────────────────────────
log "Injecting keys into ${ENV_FILE}"
_upsert_env_var "$ENV_FILE" "MAKATO_LANGFUSE_KEY"    "$MAKATO_KEY"
_upsert_env_var "$ENV_FILE" "SAGIBEAST_LANGFUSE_KEY" "$SAGIBEAST_KEY"
_upsert_env_var "$ENV_FILE" "LANGFUSE_OTLP_ENDPOINT" "${LANGFUSE_HOST}/api/public/otel/v1/traces"

# ── Export for the current shell session ─────────────────────────────────────
# Callers that source this script (. scripts/inject-otlp-keys.sh) get the
# variables exported immediately without needing to re-read the env file.
export MAKATO_LANGFUSE_KEY="$MAKATO_KEY"
export SAGIBEAST_LANGFUSE_KEY="$SAGIBEAST_KEY"
export LANGFUSE_OTLP_ENDPOINT="${LANGFUSE_HOST}/api/public/otel/v1/traces"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run complete — no files written."
else
  log "Done. Keys written to ${ENV_FILE}."
  log "  MAKATO_LANGFUSE_KEY    = ${MAKATO_KEY:0:8}... (${#MAKATO_KEY} chars)"
  log "  SAGIBEAST_LANGFUSE_KEY = ${SAGIBEAST_KEY:0:8}... (${#SAGIBEAST_KEY} chars)"
  log "  LANGFUSE_OTLP_ENDPOINT = ${LANGFUSE_OTLP_ENDPOINT}"
fi
