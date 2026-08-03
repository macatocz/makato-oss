#!/usr/bin/env bash
# scripts/generate-progress.sh — repo-wide PROGRESS.md roadmap from
# loop-status.json + GitHub epic issues (#601).
#
# Reads `.claude/state/loop-status.json` for operational status:
#   - active_workflow.issue (currently-running epic)
#   - queue[] (queued issue numbers)
# Falls back gracefully when the file is absent or unreadable.
#
# Queries GitHub via:
#   gh issue list --label type:epic --state all --json number,title,state,closedAt --limit 200
#
# Classifies each epic:
#   Done        — GitHub state = "CLOSED"
#   In Progress — number matches active_workflow.issue OR appears in queue[]
#   Not Started — open, not in loop queue
#
# Emits PROGRESS.md at the repo root (the directory from which the script is
# invoked). Sections: ## Done, ## In Progress, ## Not Started.
# Footer: _Last updated: <ISO8601 UTC>. Source: loop-status.json + GitHub issues._
#
# Never fatal: always exits 0. Writes warnings to stderr and includes a
# <!-- PROGRESS.md generation warning: <msg> --> comment at top of file when
# data is partial.
#
# Environment / test hooks:
#   MAKATO_LOOP_STATE_DIR   Override `.claude/state/` location (mirrors loop.sh).
#   MAKATO_PROGRESS_GH_OVERRIDE
#                           Tests only: path to a JSON file holding the pre-canned
#                           `gh issue list` result. When set, the script reads this
#                           file instead of invoking `gh`.
#   MAKATO_PROGRESS_OUT     Override output file path (tests only).
#
# Pattern-mirrors scripts/generate-run-report.sh for arg handling and output path.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
STATUS_FILE="$STATE_DIR/loop-status.json"
OUT_FILE="${MAKATO_PROGRESS_OUT:-$REPO_ROOT/PROGRESS.md}"

_log() { echo "generate-progress: $*" >&2; }

# ---------------------------------------------------------------------------
# _now — ISO-8601 UTC timestamp. Mirrors generate-run-report.sh / loop.sh.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')" 2>/dev/null \
  || date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
  || echo "1970-01-01T00:00:00.000Z"
}

# ---------------------------------------------------------------------------
# Read loop-status.json; emit active issue number and queue array (JSON).
# Falls back gracefully when file is absent or malformed.
# ---------------------------------------------------------------------------
WARN_MSGS=()
ACTIVE_ISSUE=""
QUEUE_JSON="[]"

if [[ -f "$STATUS_FILE" ]]; then
  ACTIVE_ISSUE="$(jq -r '.active_workflow.issue // empty' "$STATUS_FILE" 2>/dev/null || true)"
  QUEUE_JSON="$(jq -c '.queue // []' "$STATUS_FILE" 2>/dev/null || echo "[]")"
else
  WARN_MSGS+=("loop-status.json absent at $STATUS_FILE — in-progress classification unavailable")
  _log "WARN: loop-status.json not found at $STATUS_FILE — falling back to gh data only"
fi

# ---------------------------------------------------------------------------
# Fetch epic issues from GitHub (or override file in tests).
# Output: JSON array of {number, title, state, closedAt} objects.
# ---------------------------------------------------------------------------
EPICS_JSON="[]"
GH_FAILED=0

if [[ -n "${MAKATO_PROGRESS_GH_OVERRIDE:-}" ]]; then
  # Test hook: read from the pre-canned fixture file.
  if [[ -f "$MAKATO_PROGRESS_GH_OVERRIDE" ]]; then
    EPICS_JSON="$(cat "$MAKATO_PROGRESS_GH_OVERRIDE")"
  else
    _log "WARN: MAKATO_PROGRESS_GH_OVERRIDE set but file not found: $MAKATO_PROGRESS_GH_OVERRIDE"
    WARN_MSGS+=("MAKATO_PROGRESS_GH_OVERRIDE file not found: $MAKATO_PROGRESS_GH_OVERRIDE")
    GH_FAILED=1
  fi
elif command -v gh >/dev/null 2>&1; then
  # Real GitHub query.
  if ! EPICS_JSON="$(gh issue list \
    --label "type:epic" \
    --state all \
    --json number,title,state,closedAt \
    --limit 200 \
    2>/dev/null)"; then
    _log "WARN: gh issue list failed — PROGRESS.md will be written with a warning comment"
    WARN_MSGS+=("gh issue list failed — epic data unavailable")
    GH_FAILED=1
  fi
else
  _log "WARN: gh CLI not found — PROGRESS.md will be written with a warning comment"
  WARN_MSGS+=("gh CLI not available — epic data unavailable")
  GH_FAILED=1
fi

# Validate that EPICS_JSON is a JSON array; degrade gracefully on parse failure.
if [[ $GH_FAILED -eq 0 ]]; then
  if ! jq -e 'type == "array"' <<<"$EPICS_JSON" >/dev/null 2>&1; then
    _log "WARN: gh output is not a JSON array — treating as empty"
    WARN_MSGS+=("gh issue list output was not a JSON array")
    EPICS_JSON="[]"
  fi
fi

# ---------------------------------------------------------------------------
# Classify each epic into Done / In Progress / Not Started.
# ---------------------------------------------------------------------------
# Build a bash-side set for in-progress: active_workflow.issue + queue[].
IN_PROGRESS_NUMBERS=()
if [[ -n "$ACTIVE_ISSUE" && "$ACTIVE_ISSUE" =~ ^[0-9]+$ ]]; then
  IN_PROGRESS_NUMBERS+=("$ACTIVE_ISSUE")
fi
# Read queue array — it is an array of issue numbers (integers) in loop-status.
while IFS= read -r qnum; do
  [[ -n "$qnum" && "$qnum" =~ ^[0-9]+$ ]] || continue
  IN_PROGRESS_NUMBERS+=("$qnum")
done < <(jq -r '.[]' <<<"$QUEUE_JSON" 2>/dev/null || true)

_is_in_progress() {
  local n="$1"
  for ip in "${IN_PROGRESS_NUMBERS[@]+"${IN_PROGRESS_NUMBERS[@]}"}"; do
    [[ "$ip" == "$n" ]] && return 0
  done
  return 1
}

DONE_ENTRIES=()
IN_PROGRESS_ENTRIES=()
NOT_STARTED_ENTRIES=()

while IFS= read -r epic; do
  num="$(jq -r '.number' <<<"$epic")"
  title="$(jq -r '.title' <<<"$epic")"
  state="$(jq -r '.state' <<<"$epic")"   # "OPEN" or "CLOSED"
  # Sanitize title for Markdown: escape leading # to prevent heading
  safe_title="${title//\\/\\\\}"

  if [[ "$state" == "CLOSED" ]]; then
    DONE_ENTRIES+=("- **[${safe_title}](#${num})** (#${num})")
  elif _is_in_progress "$num"; then
    IN_PROGRESS_ENTRIES+=("- **[${safe_title}](#${num})** (#${num})")
  else
    NOT_STARTED_ENTRIES+=("- **[${safe_title}](#${num})** (#${num})")
  fi
done < <(jq -c '.[]' <<<"$EPICS_JSON" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Build and write PROGRESS.md — always exits 0.
# ---------------------------------------------------------------------------
GENERATED_AT="$(_now)"

{
  # Warning comment at top when data is partial.
  for wmsg in "${WARN_MSGS[@]+"${WARN_MSGS[@]}"}"; do
    printf '<!-- PROGRESS.md generation warning: %s -->\n' "$wmsg"
  done

  printf '# Roadmap Progress\n\n'

  printf '## In Progress\n\n'
  if [[ ${#IN_PROGRESS_ENTRIES[@]} -gt 0 ]]; then
    for entry in "${IN_PROGRESS_ENTRIES[@]}"; do
      printf '%s\n' "$entry"
    done
  else
    printf '_No epics currently in progress._\n'
  fi
  printf '\n'

  printf '## Not Started\n\n'
  if [[ ${#NOT_STARTED_ENTRIES[@]} -gt 0 ]]; then
    for entry in "${NOT_STARTED_ENTRIES[@]}"; do
      printf '%s\n' "$entry"
    done
  else
    printf '_No open epics outside the loop queue._\n'
  fi
  printf '\n'

  printf '## Done\n\n'
  if [[ ${#DONE_ENTRIES[@]} -gt 0 ]]; then
    for entry in "${DONE_ENTRIES[@]}"; do
      printf '%s\n' "$entry"
    done
  else
    printf '_No closed epics found._\n'
  fi
  printf '\n'

  printf '%s\n' '---'
  printf '_Last updated: %s. Source: loop-status.json + GitHub issues._\n' "$GENERATED_AT"
} >"$OUT_FILE"

_log "PROGRESS.md written to $OUT_FILE (done=${#DONE_ENTRIES[@]}, in-progress=${#IN_PROGRESS_ENTRIES[@]}, not-started=${#NOT_STARTED_ENTRIES[@]})"
exit 0
