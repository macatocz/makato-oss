#!/usr/bin/env bash
# Optional-service preflight (local-openai-gpt-macos-compatibility, Task 5).
#
# Checks Playwright MCP, Langfuse OTLP, Postgres, Temporal, and Sagibeast/
# testbox connectivity. Every service is explicit PASS/SKIP/WARN — an
# unconfigured or unreachable optional service is NEVER reported as silently
# healthy, and this script never treats an optional service as a hard
# failure: it always exits 0 unless a dependency (bash/python3) is missing.
# Endpoints are labelled local vs remote; any credential embedded in a
# connection string is redacted before being printed.
#
# Usage:
#   scripts/preflight-optional-services.sh
#
# Env inputs (all optional — unset means SKIP for that service):
#   PLAYWRIGHT_MCP_CONFIG   — path to the Playwright MCP .mcp.json (default:
#                             plugins/makato-ux/.mcp.json)
#   LANGFUSE_OTLP_ENDPOINT  — Langfuse OTLP/HTTP ingestion URL (see
#                             infra/docker-compose.langfuse.yml)
#   LANGFUSE_DATABASE_URL / POSTGRES_URL — Postgres DSN (either name accepted;
#                             POSTGRES_URL takes precedence when both are set)
#   TEMPORAL_ADDRESS       — Temporal frontend address, host:port form
#   SAGIBEAST_SSH_HOST     — SSH config Host alias for the Sagibeast testbox
#                             (default: sagibeast.testbox)
#   SAGIBEAST_SSH_CONFIG   — path to an alternate ssh_config file (`ssh -F`)
#                             to resolve SAGIBEAST_SSH_HOST against, instead
#                             of the user's default ~/.ssh/config
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"

PASS=0
SKIP=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }
warn() { WARN=$((WARN + 1)); echo "WARN: $1"; }

# Redact userinfo (user:pass@) from a connection string before printing.
redact_url() {
  printf '%s' "$1" | sed -E 's#//[^/@[:space:]]+@#//[REDACTED]@#'
}

classify_host() {
  case "$1" in
    localhost|127.0.0.1|::1|"") echo "local" ;;
    *) echo "remote" ;;
  esac
}

tcp_reachable() {
  # $1=host $2=port $3=timeout(s). Use Python's portable socket API because
  # stock macOS does not provide GNU timeout(1).
  local host="$1" port="$2" timeout_seconds="${3:-5}"
  "$PYTHON_BIN" - "$host" "$port" "$timeout_seconds" <<'PY'
import socket
import sys

host, port, timeout_seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    with socket.create_connection((host, port), timeout=timeout_seconds):
        pass
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

# ── 1. Playwright MCP ──────────────────────────────────────────────────────
MCP_CONFIG="${PLAYWRIGHT_MCP_CONFIG:-${REPO_ROOT}/plugins/makato-ux/.mcp.json}"
if [ ! -f "$MCP_CONFIG" ]; then
  skip "Playwright MCP — config not found at ${MCP_CONFIG} (local, stdio subprocess)"
elif ! "$PYTHON_BIN" -c 'import json,sys; json.load(open(sys.argv[1]))' "$MCP_CONFIG" >/dev/null 2>&1; then
  warn "Playwright MCP — ${MCP_CONFIG} is not valid JSON (local, stdio subprocess)"
elif ! command -v npx >/dev/null 2>&1; then
  warn "Playwright MCP — npx not found on PATH; install Node.js (local, stdio subprocess)"
else
  pass "Playwright MCP — config valid, npx available (local, stdio subprocess)"
fi

# ── 2. Langfuse OTLP ────────────────────────────────────────────────────────
if [ -z "${LANGFUSE_OTLP_ENDPOINT:-}" ]; then
  skip "Langfuse OTLP — LANGFUSE_OTLP_ENDPOINT not set (see infra/docker-compose.langfuse.yml)"
else
  ENDPOINT="$LANGFUSE_OTLP_ENDPOINT"
  HOST="$("$PYTHON_BIN" -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).hostname or "")' "$ENDPOINT")"
  LOCATION="$(classify_host "$HOST")"
  # curl's -w '%{http_code}' already prints "000" on a connection-level
  # failure; the fallback only covers curl producing no output at all.
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT" 2>/dev/null) || true
  [ -z "$http_code" ] && http_code="000"
  if [ "$http_code" = "000" ]; then
    warn "Langfuse OTLP — $(redact_url "$ENDPOINT") unreachable (${LOCATION})"
  else
    pass "Langfuse OTLP — $(redact_url "$ENDPOINT") reachable (${LOCATION}, HTTP ${http_code})"
  fi
fi

# ── 3. Postgres ──────────────────────────────────────────────────────────────
PG_URL="${POSTGRES_URL:-${LANGFUSE_DATABASE_URL:-}}"
if [ -z "$PG_URL" ]; then
  skip "Postgres — POSTGRES_URL/LANGFUSE_DATABASE_URL not set"
else
  read -r PG_HOST PG_PORT <<<"$("$PYTHON_BIN" -c '
import sys, urllib.parse as u
p = u.urlparse(sys.argv[1])
print(p.hostname or "", p.port or 5432)
' "$PG_URL")"
  LOCATION="$(classify_host "$PG_HOST")"
  if [ -z "$PG_HOST" ]; then
    warn "Postgres — $(redact_url "$PG_URL") could not be parsed"
  elif tcp_reachable "$PG_HOST" "$PG_PORT" 5; then
    pass "Postgres — $(redact_url "$PG_URL") reachable (${LOCATION}, ${PG_HOST}:${PG_PORT})"
  else
    warn "Postgres — $(redact_url "$PG_URL") unreachable (${LOCATION}, ${PG_HOST}:${PG_PORT})"
  fi
fi

# ── 4. Temporal ──────────────────────────────────────────────────────────────
if [ -z "${TEMPORAL_ADDRESS:-}" ]; then
  skip "Temporal — TEMPORAL_ADDRESS not set (e.g. localhost:7233)"
else
  TEMPORAL_HOST="${TEMPORAL_ADDRESS%%:*}"
  TEMPORAL_PORT="${TEMPORAL_ADDRESS##*:}"
  LOCATION="$(classify_host "$TEMPORAL_HOST")"
  if [ "$TEMPORAL_HOST" = "$TEMPORAL_ADDRESS" ] || [ -z "$TEMPORAL_PORT" ]; then
    warn "Temporal — TEMPORAL_ADDRESS='${TEMPORAL_ADDRESS}' must be host:port"
  elif tcp_reachable "$TEMPORAL_HOST" "$TEMPORAL_PORT" 5; then
    pass "Temporal — ${TEMPORAL_ADDRESS} reachable (${LOCATION})"
  else
    warn "Temporal — ${TEMPORAL_ADDRESS} unreachable (${LOCATION})"
  fi
fi

# ── 5. Sagibeast / testbox ────────────────────────────────────────────────────
SAGIBEAST_HOST="${SAGIBEAST_SSH_HOST:-sagibeast.testbox}"
SSH_CONFIG_ARGS=()
[ -n "${SAGIBEAST_SSH_CONFIG:-}" ] && SSH_CONFIG_ARGS=(-F "$SAGIBEAST_SSH_CONFIG")
if ! command -v ssh >/dev/null 2>&1; then
  skip "Sagibeast/testbox — ssh not found on PATH"
else
  # `ssh -G <host>` always prints a `hostname` line even for a host with no
  # matching Host block — it defaults to the literal argument. An explicit
  # Host alias is only really configured when its resolved hostname differs
  # from the input (e.g. a `HostName 127.0.0.1` override), so compare the two
  # instead of merely checking the line is present.
  RESOLVED_HOSTNAME="$(ssh "${SSH_CONFIG_ARGS[@]}" -G "$SAGIBEAST_HOST" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"
  if [ -z "$RESOLVED_HOSTNAME" ] || [ "$RESOLVED_HOSTNAME" = "$SAGIBEAST_HOST" ]; then
    skip "Sagibeast/testbox — no SSH Host alias '${SAGIBEAST_HOST}' configured in ~/.ssh/config"
  elif ssh "${SSH_CONFIG_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SAGIBEAST_HOST" true >/dev/null 2>&1; then
    pass "Sagibeast/testbox — ssh ${SAGIBEAST_HOST} reachable (remote)"
  else
    warn "Sagibeast/testbox — ssh ${SAGIBEAST_HOST} configured but unreachable (remote)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Optional services: ${PASS} passed, ${SKIP} skipped, ${WARN} warned (advisory — never blocks Gate 6)"
exit 0
