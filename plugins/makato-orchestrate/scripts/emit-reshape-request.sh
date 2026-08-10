#!/usr/bin/env bash
# emit-reshape-request.sh — emit specs/<key>-<slug>/reshape-request.json after a
# structural HALT fires on a PO-agent run (#349).
#
# Usage:
#   emit-reshape-request.sh <KEY> <ISSUE_NUMBER>
#
#   KEY          composite key (e.g. "349-makato-orchestrate-serialize-structural")
#   ISSUE_NUMBER GitHub issue number (e.g. 349)
#
# What it does:
#   1. Reads workflow-state-<ISSUE_NUMBER>.json via shared/workflow-state.sh read.
#   2. Derives issue_slug from KEY (strips leading "<number>-" prefix).
#   3. Filters halt_audit[] to structural entries only.
#   4. Filters lessons_learned[] to entries with trigger == "halt".
#   5. Extracts CRITICAL errors from the last sub_tasks[] entry with agent_result.
#   6. Counts reshape_cycles from any prior reshape-request.json in the spec folder.
#   7. Emits JSON to specs/<key>-<slug>/reshape-request.json atomically.
#   8. Validates output against emit-reshape-request.schema.json.
#   9. Appends step:"emit-reshape-request" entry to orchestrate.jsonl.
#
# Structural HALT codes: HALT-003, HALT-STRUCTURAL, HALT-010,
# and HALT-008 ONLY when data.origin == "outer_iteration".
#
# Test hooks (all optional):
#   MAKATO_EMIT_RESHAPE_SPECS_DIR   override specs/ root (tests)
#
# Exit codes:
#   0  success
#   1  error (missing args, missing state file, validation failure)
set -euo pipefail

KEY="${1:?key required (e.g. 349-makato-orchestrate-serialize-structural)}"
ISSUE_NUMBER="${2:?issue_number required (e.g. 349)}"

# ---------------------------------------------------------------------------
# Validate ISSUE_NUMBER is a positive integer.
# ---------------------------------------------------------------------------
if [[ ! "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "emit-reshape-request: ISSUE_NUMBER must be a positive integer (got '$ISSUE_NUMBER')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve repo root via --git-common-dir so the script works from a worktree.
# Mirrors the pattern in workflow-state.sh and build-log.sh.
# ---------------------------------------------------------------------------
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

SPECS_DIR="${MAKATO_EMIT_RESHAPE_SPECS_DIR:-$REPO_ROOT/specs}"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
SCHEMA="$REPO_ROOT/plugins/makato-orchestrate/scripts/emit-reshape-request.schema.json"

# ---------------------------------------------------------------------------
# Resolve spec folder: find specs/<KEY>-*/ then fall back to specs/<KEY>/.
# ---------------------------------------------------------------------------
SPEC_FOLDER=""
if [[ -d "$SPECS_DIR" ]]; then
  SPEC_FOLDER="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${KEY}-*" | head -1)"
fi
if [[ -z "$SPEC_FOLDER" ]] && [[ -d "$SPECS_DIR/$KEY" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi
if [[ -z "$SPEC_FOLDER" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Matches house style.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Read workflow-state. When MAKATO_EMIT_RESHAPE_SPECS_DIR is set (test mode),
# read the file directly from the resolved SPEC_FOLDER so the test override
# applies to both reading and writing. In production the two paths are
# equivalent — workflow-state.sh read also resolves via git-common-dir and
# outputs `{}` when the file is missing.
# ---------------------------------------------------------------------------
STATE_FILE="$SPEC_FOLDER/workflow-state-${ISSUE_NUMBER}.json"
if [[ -f "$STATE_FILE" ]]; then
  STATE_JSON="$(cat "$STATE_FILE")"
else
  # Fallback to workflow-state.sh read for production callers (resolves legacy
  # migration, backward-compat promotion, etc.).
  STATE_JSON="$("$WS" read "$KEY" "$ISSUE_NUMBER" 2>/dev/null)"
fi
if [[ "$STATE_JSON" == "{}" ]] || [[ -z "$STATE_JSON" ]]; then
  echo "emit-reshape-request: workflow-state-${ISSUE_NUMBER}.json not found for KEY=$KEY" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Derive issue_slug: strip leading "<number>-" prefix from KEY.
# e.g. "349-makato-orchestrate-serialize-structural" -> "makato-orchestrate-serialize-structural"
# ---------------------------------------------------------------------------
ISSUE_SLUG="${KEY#*-}"

# ---------------------------------------------------------------------------
# Count structural_halt_cycles from halt_audit[]:
# Structural codes: HALT-003, HALT-STRUCTURAL, HALT-010,
# HALT-008 ONLY when data.origin == "outer_iteration"
# ---------------------------------------------------------------------------
STRUCTURAL_HALT_CYCLES="$(jq '
  [.halt_audit[] | select(
    .code == "HALT-003" or
    .code == "HALT-STRUCTURAL" or
    .code == "HALT-010" or
    (.code == "HALT-008" and .data.origin == "outer_iteration")
  )] | length
' <<<"$STATE_JSON")"

# ---------------------------------------------------------------------------
# Build halt_history array (structural entries only).
# ---------------------------------------------------------------------------
HALT_HISTORY="$(jq '[.halt_audit[] | select(
  .code == "HALT-003" or
  .code == "HALT-STRUCTURAL" or
  .code == "HALT-010" or
  (.code == "HALT-008" and .data.origin == "outer_iteration")
)]' <<<"$STATE_JSON")"

# ---------------------------------------------------------------------------
# Build lessons_trail array: only lessons with trigger == "halt".
# ---------------------------------------------------------------------------
LESSONS_TRAIL="$(jq '[.lessons_learned[] | select(.trigger == "halt")]' <<<"$STATE_JSON")"

# ---------------------------------------------------------------------------
# Extract CRITICAL errors from the last sub_tasks[] entry with a non-null
# agent_result. Keep only strings containing "CRITICAL" (case-insensitive).
# ---------------------------------------------------------------------------
LAST_CRITICAL_ERRORS="$(jq '[
  (.sub_tasks | reverse | map(select(.agent_result != null)) | .[0] |
   .agent_result.errors // [])
  | .[]
  | select(test("CRITICAL"; "i"))
] | if length == 0 then empty else . end' <<<"$STATE_JSON" 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Count reshape_cycles from any prior reshape-request.json in spec folder.
# If none exists: 0. If exists: read .reshape_cycles + 1.
# ---------------------------------------------------------------------------
PRIOR_RESHAPE="$SPEC_FOLDER/reshape-request.json"
RESHAPE_CYCLES=0
if [[ -f "$PRIOR_RESHAPE" ]]; then
  PRIOR_CYCLES="$(jq '.reshape_cycles // 0' "$PRIOR_RESHAPE" 2>/dev/null || echo "0")"
  RESHAPE_CYCLES=$(( PRIOR_CYCLES + 1 ))
fi

# ---------------------------------------------------------------------------
# Build the JSON output.
# ---------------------------------------------------------------------------
NOW="$(_now)"

OUTPUT="$(jq -n \
  --arg schema_version "v1" \
  --arg issue_key "$KEY" \
  --argjson issue_number "$ISSUE_NUMBER" \
  --arg issue_slug "$ISSUE_SLUG" \
  --argjson structural_halt_cycles "$STRUCTURAL_HALT_CYCLES" \
  --argjson reshape_cycles "$RESHAPE_CYCLES" \
  --argjson halt_history "$HALT_HISTORY" \
  --argjson lessons_trail "$LESSONS_TRAIL" \
  --arg emitted_at "$NOW" \
  '{
    schema_version: $schema_version,
    issue_key: $issue_key,
    issue_number: $issue_number,
    issue_slug: $issue_slug,
    structural_halt_cycles: $structural_halt_cycles,
    reshape_cycles: $reshape_cycles,
    halt_history: $halt_history,
    lessons_trail: $lessons_trail,
    emitted_at: $emitted_at
  }')"

# Conditionally add last_critical_errors only when non-empty.
if [[ -n "$LAST_CRITICAL_ERRORS" ]]; then
  OUTPUT="$(jq --argjson errors "$LAST_CRITICAL_ERRORS" \
    '. + {last_critical_errors: $errors}' <<<"$OUTPUT")"
fi

# ---------------------------------------------------------------------------
# Validate against schema.
# ---------------------------------------------------------------------------
python3 -c '
import sys, json, pathlib
data_str    = sys.argv[1]
schema_path = sys.argv[2]
try:
    import jsonschema
except ImportError:
    sys.stderr.write(
        "emit-reshape-request: WARN — jsonschema not installed; "
        "degraded: schema-unvalidated (install jsonschema to enable full validation)\n"
    )
    sys.exit(0)
try:
    data = json.loads(data_str)
except json.JSONDecodeError as e:
    sys.stderr.write(f"emit-reshape-request: JSON parse error: {e}\n")
    sys.exit(1)
try:
    schema = json.loads(pathlib.Path(schema_path).read_text())
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as e:
    sys.stderr.write(f"emit-reshape-request: schema validation failed: {e.message}\n")
    sys.exit(1)
' "$OUTPUT" "$SCHEMA" || exit 1

# ---------------------------------------------------------------------------
# Atomic write: stage to .tmp then mv.
# ---------------------------------------------------------------------------
mkdir -p "$SPEC_FOLDER"
TMP_FILE="$(mktemp "${PRIOR_RESHAPE}.XXXXXX")"
printf '%s\n' "$OUTPUT" > "$TMP_FILE"
mv "$TMP_FILE" "$PRIOR_RESHAPE"

echo "emit-reshape-request: wrote $PRIOR_RESHAPE" >&2

# ---------------------------------------------------------------------------
# Append orchestrate.jsonl entry via build-log.sh.
# ---------------------------------------------------------------------------
LOG_ENTRY="$(jq -n \
  --arg ts "$NOW" \
  --arg story "$KEY" \
  --argjson issue "$ISSUE_NUMBER" \
  --argjson structural_halt_cycles "$STRUCTURAL_HALT_CYCLES" \
  '{
    ts: $ts,
    skill: "emit-reshape-request",
    story: $story,
    step: "emit-reshape-request",
    status: "ok",
    data: {
      issue_number: $issue,
      structural_halt_cycles: $structural_halt_cycles
    }
  }')"

# build-log.sh writes to build.jsonl; orchestrate uses the same helper
# but the log file is effectively named orchestrate.jsonl by convention.
# Since build-log.sh writes to build.jsonl, we append to orchestrate.jsonl
# directly here to honour the "step:emit-reshape-request in orchestrate.jsonl" requirement.
ORCHESTRATE_LOG="$SPEC_FOLDER/orchestrate.jsonl"
mkdir -p "$(dirname "$ORCHESTRATE_LOG")"
printf '%s\n' "$LOG_ENTRY" >> "$ORCHESTRATE_LOG"

exit 0
