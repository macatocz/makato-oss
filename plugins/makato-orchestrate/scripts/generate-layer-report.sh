#!/usr/bin/env bash
# scripts/generate-layer-report.sh — HALT-by-layer aggregation across issues (#593).
#
# Reads `specs/*/orchestrate.jsonl` files and aggregates HALT events by the
# five harness layers (task-spec / context / environment / verification / state),
# then identifies the most frequent failure layer (bottleneck).
#
# Behaviour (issue #593 AC):
#   1. Accept an explicit issue list via positional args or `--issues "<n> …"`, OR
#      use `--last-n <N>` (default 20) to scan the N most-recently-modified
#      orchestrate.jsonl files when no explicit list is given.
#   2. Read `specs/*/orchestrate.jsonl` — parse lines with
#      `step:"halt" status:"error"` and extract `data.halt_code`.
#   3. Join each halt_code to its layer via a static associative array built
#      from the Task 1 mapping in halt-conditions.md. Unknown codes → "unknown".
#   4. Aggregate counts by layer; identify the layer with the highest count.
#   5. Emit JSON report to `.claude/state/layer-report-<run_id>.json`.
#      Prints the report path to stdout; one-line summary to stderr.
#
# Read-only contract (issue #593 AC-2): this script NEVER writes to
# workflow-state.json or orchestrate.jsonl. It reads per-issue audit and emits
# a derived artefact under .claude/state/. It is not a second source of truth.
#
# Exit codes: 0 on success; non-zero only on a fatal condition (SPECS_DIR
# unreadable, cannot write the report file, mutually exclusive flags used).
#
# Environment / test hooks:
#   MAKATO_LOOP_STATE_DIR        Override `.claude/state/` output location.
#   MAKATO_REPORT_SPECS_DIR      Override the specs/ directory (tests).
#
# Conventions: mirrors generate-run-report.sh (POSIX-ish bash,
# `set -euo pipefail`, python3 for timestamps, jq for JSON).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPECS_DIR="${MAKATO_REPORT_SPECS_DIR:-${SPECS_DIR:-$REPO_ROOT/specs}}"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"

_log() { echo "layer-report: $*" >&2; }

# ---------------------------------------------------------------------------
# _now — ISO-8601 UTC timestamp with millisecond precision.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# _run_id_slug — filesystem-safe UTC slug for the default report filename.
# ---------------------------------------------------------------------------
_run_id_slug() {
  python3 -c "from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))"
}

# ---------------------------------------------------------------------------
# Static layer mapping built from halt-conditions.md Task 1 assignments.
# Keys are the exact halt_code strings that appear in orchestrate.jsonl.
# Compound codes (HALT-008 with origin variants) are stored under the base
# code; the origin is tracked per-event if needed but for layer aggregation
# each HALT-008 event maps to the layer of its origin field when present
# (see _code_to_layer below).
# ---------------------------------------------------------------------------
declare -A LAYER_MAP=(
  ["HALT-000"]="environment"
  ["HALT-001"]="verification"
  ["HALT-002"]="verification"
  ["HALT-003"]="verification"
  ["HALT-004"]="verification"
  ["HALT-005"]="environment"
  ["HALT-006"]="task-spec"
  ["HALT-007"]="environment"
  ["HALT-007B"]="environment"
  ["HALT-008"]="state"          # default for outer_iteration origin
  ["HALT-009"]="environment"
  ["HALT-010"]="state"
  ["HALT-011"]="state"
  ["HALT-012"]="context"
  ["HALT-013"]="state"
  ["HALT-014"]="state"
  ["HALT-STRUCTURAL"]="verification"
  ["HALT-CH-001"]="context"
  ["HALT-CH-002"]="context"
  ["HALT-CH-003"]="context"
  ["HALT-CH-004"]="verification"
)

# HALT-008 has three origins with different layers.
declare -A HALT008_ORIGIN_LAYER=(
  ["outer_iteration"]="state"
  ["merge_conflict"]="environment"
  ["ci_failure"]="verification"
)

# ---------------------------------------------------------------------------
# _code_to_layer <halt_code> [origin]
# Resolves a halt_code (+ optional origin for HALT-008) to its layer string.
# Codes not in the map → "unknown" (backward compat).
# ---------------------------------------------------------------------------
_code_to_layer() {
  local code="${1:-}"
  local origin="${2:-}"

  if [[ "$code" == "HALT-008" && -n "$origin" ]]; then
    local ol="${HALT008_ORIGIN_LAYER[$origin]:-}"
    if [[ -n "$ol" ]]; then
      echo "$ol"
      return
    fi
  fi

  local layer="${LAYER_MAP[$code]:-}"
  if [[ -n "$layer" ]]; then
    echo "$layer"
  else
    echo "unknown"
  fi
}

# --- Argument parsing -------------------------------------------------------
ISSUES=()
RUN_ID=""
LAST_N=20
EXPLICIT_ISSUES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issues)
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --issues requires a value"; exit 64; }
      # shellcheck disable=SC2206
      ISSUES+=($1)
      EXPLICIT_ISSUES=true
      shift
      ;;
    --last-n)
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --last-n requires a value"; exit 64; }
      [[ "$1" =~ ^[0-9]+$ ]] || { _log "ERROR — --last-n must be a positive integer; got '$1'"; exit 64; }
      LAST_N="$1"
      shift
      ;;
    --run-id)
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --run-id requires a value"; exit 64; }
      RUN_ID="$1"
      shift
      ;;
    --*)
      _log "ERROR — unknown flag: $1"; exit 64 ;;
    *)
      ISSUES+=("$1")
      EXPLICIT_ISSUES=true
      shift
      ;;
  esac
done

# --last-n and explicit issues are mutually exclusive.
if $EXPLICIT_ISSUES && [[ ${#ISSUES[@]} -gt 0 ]] && [[ "$LAST_N" != "20" ]]; then
  _log "ERROR — --last-n and explicit issue list are mutually exclusive"
  exit 64
fi

# ---------------------------------------------------------------------------
# Collect orchestrate.jsonl paths to scan.
# ---------------------------------------------------------------------------
declare -a JSONL_PATHS=()

if $EXPLICIT_ISSUES && [[ ${#ISSUES[@]} -gt 0 ]]; then
  # Explicit issue list: resolve per-issue orchestrate.jsonl.
  for issue in "${ISSUES[@]}"; do
    if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
      _log "WARN — skipping non-numeric issue token: '$issue'"
      continue
    fi
    if [[ ! -d "$SPECS_DIR" ]]; then
      _log "WARN — SPECS_DIR not found: $SPECS_DIR; skipping issue $issue"
      continue
    fi
    # Find orchestrate.jsonl under specs/*/  for any folder whose name starts
    # with the issue number (prefix match, mirrors loop.sh resolution).
    found_path="$(find "$SPECS_DIR" -maxdepth 2 -name "orchestrate.jsonl" \
      | while IFS= read -r p; do
          dir="$(basename "$(dirname "$p")")"
          if [[ "$dir" == "${issue}-"* || "$dir" == "$issue" ]]; then
            echo "$p"
            break
          fi
        done | head -1)"
    if [[ -n "$found_path" && -f "$found_path" ]]; then
      JSONL_PATHS+=("$found_path")
    else
      _log "WARN — no orchestrate.jsonl for issue $issue under $SPECS_DIR; skipping"
    fi
  done
else
  # --last-n mode: find all orchestrate.jsonl sorted by mtime (newest first).
  if [[ -d "$SPECS_DIR" ]]; then
    # Use python3 for portable mtime sort (macOS find -newer and BSD sort differ).
    mapfile -t JSONL_PATHS < <(python3 - "$SPECS_DIR" "$LAST_N" <<'PYEOF'
import sys, os, pathlib
specs = pathlib.Path(sys.argv[1])
n = int(sys.argv[2])
files = list(specs.glob("*/orchestrate.jsonl"))
files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
for f in files[:n]:
    print(f)
PYEOF
    ) || true
  fi
fi

# ---------------------------------------------------------------------------
# Layer count accumulators.
# ---------------------------------------------------------------------------
declare -A BY_LAYER=(
  ["task-spec"]=0
  ["context"]=0
  ["environment"]=0
  ["verification"]=0
  ["state"]=0
  ["unknown"]=0
)
HALT_EVENTS=0
ISSUES_SCANNED=0

for jsonl_path in "${JSONL_PATHS[@]}"; do
  [[ -f "$jsonl_path" ]] || continue
  ISSUES_SCANNED=$((ISSUES_SCANNED + 1))

  # Parse halt events: lines with step:"halt" status:"error"
  while IFS= read -r line; do
    # Check step and status fields.
    step_val="$(echo "$line" | jq -r '.step // empty' 2>/dev/null || true)"
    status_val="$(echo "$line" | jq -r '.status // empty' 2>/dev/null || true)"
    [[ "$step_val" == "halt" && "$status_val" == "error" ]] || continue

    halt_code="$(echo "$line" | jq -r '.data.halt_code // empty' 2>/dev/null || true)"
    [[ -n "$halt_code" ]] || continue

    # For HALT-008, extract origin to resolve the correct layer.
    origin_val="$(echo "$line" | jq -r '.data.origin // empty' 2>/dev/null || true)"
    layer="$(_code_to_layer "$halt_code" "$origin_val")"

    BY_LAYER["$layer"]=$((${BY_LAYER["$layer"]:-0} + 1))
    HALT_EVENTS=$((HALT_EVENTS + 1))
  done < "$jsonl_path"
done

# ---------------------------------------------------------------------------
# Identify bottleneck layer (highest count, excluding "unknown").
# On a tie, the first encountered in the layer ordering wins.
# When halt_events == 0, bottleneck is null.
# ---------------------------------------------------------------------------
BOTTLENECK_LAYER="null"
BOTTLENECK_COUNT=0

for layer in task-spec context environment verification state; do
  cnt="${BY_LAYER[$layer]:-0}"
  if [[ "$cnt" -gt "$BOTTLENECK_COUNT" ]]; then
    BOTTLENECK_LAYER="$layer"
    BOTTLENECK_COUNT="$cnt"
  fi
done

# If zero real events found, leave bottleneck as null.
if [[ "$HALT_EVENTS" -eq 0 ]]; then
  BOTTLENECK_LAYER="null"
  BOTTLENECK_COUNT=0
fi

# ---------------------------------------------------------------------------
# Assemble + write the report envelope.
# ---------------------------------------------------------------------------
RUN_ID="${RUN_ID:-$(_run_id_slug)}"
GENERATED_AT="$(_now)"

# Build by_layer JSON object.
BY_LAYER_JSON="$(jq -n \
  --argjson ts "${BY_LAYER[task-spec]:-0}" \
  --argjson ct "${BY_LAYER[context]:-0}" \
  --argjson en "${BY_LAYER[environment]:-0}" \
  --argjson ve "${BY_LAYER[verification]:-0}" \
  --argjson st "${BY_LAYER[state]:-0}" \
  --argjson un "${BY_LAYER[unknown]:-0}" \
  '{"task-spec":$ts,"context":$ct,"environment":$en,"verification":$ve,"state":$st,"unknown":$un}')"

# Build full report.
if [[ "$BOTTLENECK_LAYER" == "null" ]]; then
  BOTTLENECK_LAYER_JSON="null"
else
  BOTTLENECK_LAYER_JSON="\"$BOTTLENECK_LAYER\""
fi

report="$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg gen "$GENERATED_AT" \
  --argjson scanned "$ISSUES_SCANNED" \
  --argjson events "$HALT_EVENTS" \
  --argjson by_layer "$BY_LAYER_JSON" \
  --argjson bottleneck "$BOTTLENECK_LAYER_JSON" \
  --argjson bcount "$BOTTLENECK_COUNT" \
  '{
    run_id: $run_id,
    generated_at: $gen,
    issues_scanned: $scanned,
    halt_events_found: $events,
    by_layer: $by_layer,
    bottleneck_layer: $bottleneck,
    bottleneck_count: $bcount
  }')"

mkdir -p "$STATE_DIR" || { _log "ERROR — cannot create state dir: $STATE_DIR"; exit 1; }
report_path="$STATE_DIR/layer-report-${RUN_ID}.json"

# Atomic write (same-dir mktemp → rename) — same pattern as generate-run-report.sh.
tmp="$(mktemp "${report_path}.XXXXXX")" || { _log "ERROR — cannot write report"; exit 1; }
printf '%s\n' "$report" >"$tmp"
mv -f "$tmp" "$report_path"

# One-line operator summary to stderr; report path to stdout for capture.
_log "run ${RUN_ID}: scanned ${ISSUES_SCANNED} issues, ${HALT_EVENTS} halt events, bottleneck: ${BOTTLENECK_LAYER} (${BOTTLENECK_COUNT}) → ${report_path}"
printf '%s\n' "$report_path"
