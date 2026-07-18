#!/usr/bin/env bash
# scripts/generate-run-report.sh — per-issue final-envelope aggregation (#448).
#
# The autonomous `loop` (scripts/loop.sh) dispatches board items serially and
# deliberately discards each PO-agent subprocess exit code (loop.sh cmd_run:
# "we ignore the PO-agent's exit code — it writes its own HALT audit to
# workflow-state.json"). The loop re-derives ground truth from
# `current_phase`, but nothing aggregates the per-issue terminal states into a
# single run-level report. An overnight multi-issue run therefore leaves the
# operator to hand-reconstruct "what shipped vs what escalated" from N separate
# workflow-state files. This script closes that gap.
#
# Behaviour (issue #448):
#   1. Accept a space-separated list of issue numbers as positional args, or
#      via a repeatable `--issues "<n> <n> …"` flag (both may be combined).
#   2. For each issue, locate `specs/*/workflow-state-<issue>.json` (the
#      per-issue state file — #173) under SPECS_DIR and read, READ-ONLY:
#        - current_phase       (terminal-state confirmation; "done" ⇒ merged)
#        - github_pr_number    (populated once build-create-pr merged the PR)
#        - halt_audit[-1]       (last HALT entry — carries `code` and `origin`)
#   3. Classify each issue's verdict:
#        - "merged"  — github_pr_number is a positive integer
#        - "halted"  — no PR number but halt_audit has ≥1 entry
#        - "unknown" — neither (missing/incomplete state, or still mid-run)
#   4. Emit a run report JSON to `.claude/state/run-report-<run_id>.json`
#      (run_id defaults to a UTC timestamp slug; override with --run-id).
#      Report shape:
#        {
#          "run_id": "<slug>",
#          "generated_at": "<iso8601>",
#          "issue_count": <n>,
#          "issues": [
#            {"issue": <n>, "verdict": "merged"|"halted"|"unknown",
#             "pr_number": <n|null>, "halt_code": <str|null>,
#             "halt_origin": <str|null>, "ts": <iso8601|null>}
#          ]
#        }
#      Prints the report path to stdout (so a caller can capture it) and a
#      one-line human summary to stderr.
#
# Read-only contract (issue #448 AC-3): this script NEVER writes to
# workflow-state.json or orchestrate.jsonl. It reads per-issue state and emits
# a derived artefact under .claude/state/. It is not a second source of truth.
#
# Exit codes: 0 on success (including a missing workflow-state for a given
# issue → that issue gets verdict:"unknown", not an error); non-zero only on a
# fatal condition (SPECS_DIR unreadable, cannot write the report file).
#
# Environment / test hooks:
#   MAKATO_LOOP_STATE_DIR        Override `.claude/state/` output location.
#                                Mirrors loop.sh so tests share one override.
#   MAKATO_REPORT_SPECS_DIR      Override the specs/ directory (tests).
#
# Conventions: matches scripts/loop.sh / promote-ready.sh (POSIX-ish bash,
# `set -euo pipefail`, python3 for the ISO-8601 timestamp, jq for JSON).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPECS_DIR="${MAKATO_REPORT_SPECS_DIR:-${SPECS_DIR:-$REPO_ROOT/specs}}"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"

_log() { echo "run-report: $*" >&2; }

# ---------------------------------------------------------------------------
# _now — ISO-8601 UTC timestamp with millisecond precision. Same helper body
# as loop.sh `_now` so report timestamps match the loop's audit format.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# _run_id_slug — filesystem-safe UTC slug for the default report filename,
# e.g. 20260717T170532Z. Derived from the same clock as _now.
# ---------------------------------------------------------------------------
_run_id_slug() {
  python3 -c "from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))"
}

# --- Argument parsing ------------------------------------------------------
ISSUES=()
RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issues)
      # Space-separated list in one argument; split on whitespace.
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --issues requires a value"; exit 64; }
      # shellcheck disable=SC2206  # deliberate word-split on the space list
      ISSUES+=($1)
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
      shift
      ;;
  esac
done

# SPECS_DIR must be readable to resolve any issue; a missing dir is only fatal
# when issues were requested (an empty run legitimately has no specs to read).
if [[ "${#ISSUES[@]}" -gt 0 && ! -d "$SPECS_DIR" ]]; then
  _log "ERROR — SPECS_DIR not found or unreadable: $SPECS_DIR"
  exit 1
fi

RUN_ID="${RUN_ID:-$(_run_id_slug)}"
GENERATED_AT="$(_now)"

# ---------------------------------------------------------------------------
# _find_state_file <issue> — path to specs/*/workflow-state-<issue>.json, or
# empty if none. Mirrors loop.sh's `find … -maxdepth 2 -name
# workflow-state-<issue>.json` per-issue-state resolution (#173).
# ---------------------------------------------------------------------------
_find_state_file() {
  local issue="$1"
  [[ -d "$SPECS_DIR" ]] || return 0
  find "$SPECS_DIR" -maxdepth 2 -name "workflow-state-${issue}.json" 2>/dev/null | head -1
}

# --- Build one report entry per issue --------------------------------------
# Each entry is assembled by jq from the state file (or synthesised as
# verdict:"unknown" when the file is missing / unparseable). Collected into a
# JSON array, then wrapped in the report envelope.
entries="[]"
for issue in "${ISSUES[@]}"; do
  # Skip anything that is not a bare integer — the caller controls the list,
  # but a stray token must not crash the run.
  if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    _log "WARN — skipping non-numeric issue token: '$issue'"
    continue
  fi

  state_file="$(_find_state_file "$issue")"
  entry=""
  if [[ -n "$state_file" && -f "$state_file" ]]; then
    # Read-only jq: derive verdict + fields from the per-issue state. A
    # parse failure (malformed file) falls through to the unknown synthesis.
    entry="$(jq -c --argjson issue "$issue" '
      (.github_pr_number // null) as $pr
      | (.halt_audit // []) as $ha
      | ($ha | if length > 0 then .[-1] else null end) as $last
      | {
          issue: $issue,
          verdict: (
            if ($pr != null and ($pr | type) == "number") then "merged"
            elif ($last != null) then "halted"
            else "unknown" end
          ),
          pr_number: $pr,
          halt_code: ($last.code // null),
          halt_origin: ($last.origin // null),
          ts: ($last.ts // .updated_at // null)
        }
    ' "$state_file" 2>/dev/null || true)"
  fi

  if [[ -z "$entry" ]]; then
    # Missing or unparseable state → unknown verdict (AC: not an error).
    entry="$(jq -nc --argjson issue "$issue" '{
      issue: $issue, verdict: "unknown", pr_number: null,
      halt_code: null, halt_origin: null, ts: null
    }')"
  fi

  entries="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$entries")"
done

# --- Assemble + write the report envelope ----------------------------------
report="$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg gen "$GENERATED_AT" \
  --argjson issues "$entries" \
  '{
    run_id: $run_id,
    generated_at: $gen,
    issue_count: ($issues | length),
    issues: $issues
  }')"

mkdir -p "$STATE_DIR" || { _log "ERROR — cannot create state dir: $STATE_DIR"; exit 1; }
report_path="$STATE_DIR/run-report-${RUN_ID}.json"

# Atomic write (same-dir mktemp → rename) so a concurrent reader never sees a
# torn file — matches loop.sh `_write_status`.
tmp="$(mktemp "${report_path}.XXXXXX")" || { _log "ERROR — cannot write report"; exit 1; }
printf '%s\n' "$report" >"$tmp"
mv -f "$tmp" "$report_path"

# One-line operator summary to stderr; report path to stdout for capture.
merged_n="$(jq '[.issues[] | select(.verdict == "merged")] | length' <<<"$report")"
halted_n="$(jq '[.issues[] | select(.verdict == "halted")] | length' <<<"$report")"
unknown_n="$(jq '[.issues[] | select(.verdict == "unknown")] | length' <<<"$report")"
_log "run ${RUN_ID}: ${merged_n} merged, ${halted_n} halted, ${unknown_n} unknown → ${report_path}"
printf '%s\n' "$report_path"
