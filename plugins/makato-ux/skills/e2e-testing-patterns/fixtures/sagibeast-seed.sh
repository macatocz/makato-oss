#!/usr/bin/env bash
# sagibeast-seed.sh — Reset and seed the sagibeast dev DB to a reproducible fixture state.
#
# Idempotent: subsequent calls produce the same seeded state.
#
# Usage:
#   bash sagibeast-seed.sh
#   SAGIBEAST_DB_URL=postgresql://user:pass@host:5432/mydb bash sagibeast-seed.sh
#
# Env vars:
#   SAGIBEAST_DB_URL  PostgreSQL connection URL
#                     (default: postgresql://localhost:5432/sagibeast_dev)
#
# Exit codes:
#   0  Success — DB seeded
#   1  Connection failure or seed error
#
# JSONL audit entries are emitted to stderr for integration with build.jsonl.

set -euo pipefail

DB_URL="${SAGIBEAST_DB_URL:-postgresql://localhost:5432/sagibeast_dev}"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

log() {
    echo "[sagibeast-seed] $*" >&2
}

emit_jsonl() {
    local status="$1" msg="$2"
    echo "{\"ts\":\"$TS\",\"skill\":\"sagibeast-seed\",\"step\":\"$status\",\"status\":\"$status\",\"data\":{\"msg\":\"$msg\",\"db_url_redacted\":\"$(echo "$DB_URL" | sed 's|//.*@|//<redacted>@|')\"}}" >&2
}

emit_jsonl "start" "seed script started"

# ── Connectivity check ───────────────────────────────────────────────────────
log "Checking connectivity to: $(echo "$DB_URL" | sed 's|//.*@|//<redacted>@|')"
if ! psql "$DB_URL" --no-psqlrc -c "SELECT 1" >/dev/null 2>&1; then
    emit_jsonl "error" "cannot connect to DB"
    log "ERROR: Cannot connect to $DB_URL — check that the sagibeast dev stack is running (requires #10)"
    exit 1
fi
log "Connectivity OK"

# ── Idempotent seed ──────────────────────────────────────────────────────────
# Creates (or replaces) an e2e fixture table so Playwright specs can assert
# against a known, stable record set without depending on live business data.
psql "$DB_URL" --no-psqlrc <<'SQL'
-- Idempotent: safe to run multiple times; always produces the same table state.
DROP TABLE IF EXISTS sagibeast_e2e_fixtures CASCADE;

CREATE TABLE sagibeast_e2e_fixtures (
    id        SERIAL      PRIMARY KEY,
    name      TEXT        NOT NULL,
    value     TEXT,
    seeded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO sagibeast_e2e_fixtures (name, value) VALUES
    ('smoke-record-1', 'fixture-alpha'),
    ('smoke-record-2', 'fixture-beta'),
    ('smoke-record-3', 'fixture-gamma');
SQL

ROW_COUNT="$(psql "$DB_URL" --no-psqlrc -t -c "SELECT COUNT(*) FROM sagibeast_e2e_fixtures;" | tr -d ' \n')"
emit_jsonl "ok" "DB seeded successfully — ${ROW_COUNT} fixture rows"
log "Done — ${ROW_COUNT} fixture rows in sagibeast_e2e_fixtures"
