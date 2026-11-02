#!/usr/bin/env bash
# Append a JSONL entry (or batch of entries) to the spec folder's build.jsonl.
# Resolves the spec folder by prefix-matching specs/<key>-*/ (makato-plan naming convention).
#
# Usage:
#   build-log.sh <key> '<json-object>'        # single entry (legacy)
#   build-log.sh <key> --batch < entries.ndjson  # batch mode (#118): NDJSON on stdin
# During durable review, exported MAKATO_REVIEW_LEDGER_STATE + WORKTREE_PATH route
# operational entries through review_loop operational-log, never canonical audit.
#
# Batch mode reads newline-delimited JSON entries from stdin and appends all of
# them in one shell invocation. Skills that emit 3-5 log rows per step can flush
# in one fork-exec instead of one per row — material at scale: a 10-task
# autonomous run across 12 skills was 50-150 fork-execs pre-#118.
#
# Worktree-awareness (#85): the JSONL audit trail lives in the MAIN checkout's
# specs/ directory, NOT in a per-run git worktree. specs/ is gitignored, so a
# fresh `git worktree add` creates a worktree without any specs/ content. If
# this script ran with `git rev-parse --show-toplevel` (CWD-relative) from
# inside a worktree, every JSONL entry would land in `<worktree>/specs/<key>/`
# — a directory that nobody else reads, splitting the audit trail across
# disconnected files. The fix derives REPO_ROOT from the COMMON git directory
# (`git rev-parse --git-common-dir`), which always points at the main repo's
# `.git` regardless of where the caller is running from. The worktree's `.git`
# is a *file* containing a `gitdir:` pointer to the common dir; only the main
# checkout has `.git` as a directory.
set -euo pipefail

_normalize_entry() {
  local entry="$1"
  python3 - "$entry" <<'PY'
import datetime
import json
import re
import sys

entry = sys.argv[1]
try:
    value = json.loads(entry)
except json.JSONDecodeError:
    raise SystemExit(2)
if not isinstance(value, dict):
    raise SystemExit(3)

timestamp = value.get("ts")
pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
if timestamp is not None and not (isinstance(timestamp, str) and pattern.fullmatch(timestamp)):
    now = datetime.datetime.now(datetime.timezone.utc)
    value["ts"] = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    print("build-log: repaired invalid ts; expected ISO-8601 milliseconds", file=sys.stderr)
# Keep Unicode line separators escaped for JSONL consumers using splitlines().
print(json.dumps(value, separators=(",", ":"), ensure_ascii=True))
PY
}

KEY="${1:?key required}"
ENTRY_OR_FLAG="${2:?json entry or --batch flag required}"

# Optional --trace-id <hex> flag: when present, the actual entry/flag is shifted
# to position 4, and TRACE_ID carries the 64-char sha256 hex digest that will be
# merged into each logged object. Fully backward-compatible — callers that omit
# --trace-id behave identically to before.
TRACE_ID=""
if [[ "$ENTRY_OR_FLAG" == "--trace-id" ]]; then
  TRACE_ID="${3:?--trace-id requires a hex value}"
  ENTRY_OR_FLAG="${4:?json entry or --batch flag required after --trace-id}"
fi

# Resolve the target repository explicitly when the suite is orchestrating a
# checkout from a different directory. This is intentionally opt-in so local
# callers retain the existing git-derived behaviour.
if [[ -n "${MAKATO_TARGET_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$MAKATO_TARGET_REPO_ROOT" 2>/dev/null && pwd -P)" || {
    echo "build-log: target repository root is not a directory: $MAKATO_TARGET_REPO_ROOT" >&2
    exit 1
  }
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "build-log: target repository root is not a git checkout: $REPO_ROOT" >&2
    exit 1
  }
else
  GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$GIT_COMMON_DIR" ]]; then
    # `--git-common-dir` may be relative to CWD; absolutise via the parent dir.
    REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
  else
    # Outside a git repo entirely — degrade to the legacy behaviour so the
    # script never crashes in test fixtures or scratch dirs.
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
SPECS_DIR="${MAKATO_SPECS_DIR:-$REPO_ROOT/specs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${MAKATO_REVIEW_LEDGER_STATE:-}" ]]; then
  # Resolve spec folder through the shared resolver. It supports the canonical
  # key-prefix shape, legacy exact folders, and numeric issue-to-slug lookup.
  SPEC_FOLDER=""
  RESOLVE_ERROR="$(mktemp "${TMPDIR:-/tmp}/makato-spec-resolve.XXXXXX")"
  trap 'rm -f "$RESOLVE_ERROR"' EXIT

  if [[ -d "$SPECS_DIR" ]] && SPEC_FOLDER="$(python3 "$HERE/spec_folder.py" "$REPO_ROOT" "$KEY" 2>"$RESOLVE_ERROR")"; then
    :
  else
    RESOLVE_STATUS=$?
    if [[ "$RESOLVE_STATUS" -eq 3 ]]; then
      cat "$RESOLVE_ERROR" >&2
      exit 2
    fi
    # Preserve the historical ability to create a first audit row before a
    # spec is materialized, but never shadow an existing issue-backed folder.
    SAFE_KEY="${KEY#\#}"
    SPEC_FOLDER="$SPECS_DIR/$SAFE_KEY"
  fi

  LOG_FILE="$SPEC_FOLDER/build.jsonl"
  mkdir -p "$(dirname "$LOG_FILE")"
fi

_append_entry() {
  if [[ -n "${MAKATO_REVIEW_LEDGER_STATE:-}" ]]; then
    # The own-install ledger command validates frozen roots before private writes.
    python3 "$HERE/review_loop.py" operational-log \
      --state "$MAKATO_REVIEW_LEDGER_STATE" --worktree "${WORKTREE_PATH:?review worktree required}" \
      --entry "$1" >/dev/null
  else
    printf '%s\n' "$1" >> "$LOG_FILE"
  fi
}

# --- Model auto-injection (S4) ---
# On session start, cache the model value. On subsequent calls, inject it
# if absent. This eliminates hardcoded "model":"sonnet" from agent templates.
MODEL_CACHE_KEY="$(printf '%s%s' "$REPO_ROOT" "$KEY" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s%s' "$REPO_ROOT" "$KEY" | md5 2>/dev/null || echo "default")"
MODEL_CACHE_FILE="/tmp/makato-log-model-${MODEL_CACHE_KEY}"

_inject_model() {
  local entry="$1"
  # If entry already has a model field, check if this is a session start to cache it
  local has_model
  has_model="$(jq -r 'if .model then "yes" else "no" end' 2>/dev/null <<<"$entry" || echo "no")"
  local step status
  step="$(jq -r '.step // ""' 2>/dev/null <<<"$entry" || echo "")"
  status="$(jq -r '.status // ""' 2>/dev/null <<<"$entry" || echo "")"

  if [[ "$has_model" == "yes" ]]; then
    # Cache model on session start
    if [[ "$step" == "session" && "$status" == "start" ]]; then
      jq -r '.model' <<<"$entry" > "$MODEL_CACHE_FILE" 2>/dev/null || true
    fi
    printf '%s' "$entry"
  else
    # Inject cached model if available
    if [[ -f "$MODEL_CACHE_FILE" ]]; then
      local cached_model
      cached_model="$(cat "$MODEL_CACHE_FILE" 2>/dev/null || echo "")"
      if [[ -n "$cached_model" ]]; then
        jq -ac --arg m "$cached_model" '. + {model: $m}' <<<"$entry" 2>/dev/null || printf '%s' "$entry"
        return
      fi
    fi
    printf '%s' "$entry"
  fi
}

# Batch mode: read NDJSON entries from stdin, append them all. Lines that are
# blank or do not parse as JSON are skipped silently (the audit trail must not
# fail because a caller emitted a stray newline). This preserves the "logging
# never crashes" invariant the legacy single-entry mode also guarantees.
if [[ "$ENTRY_OR_FLAG" == "--batch" ]]; then
  while IFS= read -r line; do
    # Skip blank lines.
    [[ -z "$line" ]] && continue
    # Skip lines that don't parse as JSON objects. `jq -e .` exits non-zero on
    # parse failure; redirect stderr so a malformed line doesn't pollute the
    # caller's stderr.
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      continue
    fi
    if ! line="$(_normalize_entry "$line")"; then
      continue
    fi
    # Merge issue_trace_id when --trace-id was supplied.
    if [[ -n "$TRACE_ID" ]]; then
      line="$(jq -ac --arg tid "$TRACE_ID" '. + {issue_trace_id: $tid}' <<<"$line")"
    fi
    _append_entry "$line"
  done
  exit 0
fi

# Single-entry mode: normalize each object to one physical line and repair
# malformed timestamps, then merge issue_trace_id when supplied.
ENTRY_OR_FLAG="$(_normalize_entry "$ENTRY_OR_FLAG")" || exit $?
if [[ -n "$TRACE_ID" ]]; then
  ENTRY_OR_FLAG="$(jq -ac --arg tid "$TRACE_ID" '. + {issue_trace_id: $tid}' <<<"$ENTRY_OR_FLAG")"
fi
# Auto-inject model field (S4)
ENTRY_OR_FLAG="$(_inject_model "$ENTRY_OR_FLAG")"
_append_entry "$ENTRY_OR_FLAG"
