#!/usr/bin/env bash
# Manage specs/<key>-<slug>/workflow-state.json for the PO-agent outer loop.
#
# Subcommands:
#   init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>
#       Create workflow-state.json with valid defaults. Errors if the file exists.
#   read <KEY>
#       Print the full JSON object to stdout, or "{}" if missing.
#   write <KEY> '<JSON>'
#       Validate then overwrite the file. updated_at is injected automatically.
#   patch <KEY> <JQ-PATH> <VALUE>
#       Apply a jq-style field update. JQ-PATH like .current_phase or .sub_tasks[0].status.
#       VALUE is a JSON literal: '"implement"', '3', 'true', '{...}'.
#   append-lesson <KEY> "<TEXT>"
#       Append {ts, text} to lessons_learned[].
#
# Spec-folder resolution mirrors plugins/makato-build/shared/build-log.sh:13-22
# (duplicated, not sourced — build-log.sh is a standalone script with no exported
# functions; that contract is intentional per AGENTS.md).
#
# Validation: python3 + jsonschema (inline heredoc), fail-open if jsonschema is
# not installed. Matches plugins/makato-plan/skills/issue-to-project/sync-process.md
# precedent.
set -euo pipefail

SUBCMD="${1:?subcommand required: init|read|write|patch|append-lesson}"
KEY="${2:?key required}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPECS_DIR="$REPO_ROOT/specs"
SCHEMA_PATH="$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json"

# ---------------------------------------------------------------------------
# Spec-folder resolution (duplicated from build-log.sh — intentional).
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

STATE_FILE="$SPEC_FOLDER/workflow-state.json"

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Python over `date +%N` because
# %N is broken on macOS.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Schema validation. Takes JSON string as $1, exits non-zero on failure.
# Fail-open if jsonschema is not installed (warn, exit 0).
# ---------------------------------------------------------------------------
_validate() {
  python3 -c '
import sys, json, pathlib
data_str    = sys.argv[1]
schema_path = sys.argv[2]
try:
    import jsonschema
except ImportError:
    sys.stderr.write("workflow-state: jsonschema not installed — skipping validation\n")
    sys.exit(0)
try:
    data = json.loads(data_str)
except json.JSONDecodeError as e:
    sys.stderr.write(f"workflow-state: JSON parse error: {e}\nHALT: MALFORMED_JSON\n")
    sys.exit(1)
try:
    schema = json.loads(pathlib.Path(schema_path).read_text())
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as e:
    sys.stderr.write(f"workflow-state: schema validation failed: {e.message}\nHALT: INVALID_STATE\n")
    sys.exit(1)
' "$1" "$SCHEMA_PATH"
}

# ---------------------------------------------------------------------------
# Atomic write: stage to tmp then mv. Prevents readers from seeing a partial
# file if the script is killed mid-write.
# ---------------------------------------------------------------------------
_atomic_write() {
  local content="$1"
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

case "$SUBCMD" in

  # -------------------------------------------------------------------------
  # init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>
  # -------------------------------------------------------------------------
  init)
    REPO="${3:?repo required (owner/name form)}"
    BRANCH="${4:?branch required}"
    ISSUE_NUMBER="${5:?issue_number required}"

    if [[ -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE already exists — use 'write' to overwrite" >&2
      exit 1
    fi

    NOW="$(_now)"
    mkdir -p "$SPEC_FOLDER"

    # Context-ceiling default — env var override, else 150000 (safe below the
    # observed 170 k degradation threshold for 200 k context models). See
    # GAP-004 / #30 extension and the field doc in workflow-state.schema.json.
    CTX_WARN="${MAKATO_CONTEXT_WARN_TOKENS:-150000}"

    INITIAL_JSON="$(jq -n \
      --arg repo "$REPO" \
      --arg branch "$BRANCH" \
      --argjson issue "$ISSUE_NUMBER" \
      --argjson ctx_warn "$CTX_WARN" \
      --arg now "$NOW" \
      '{
        repo: $repo,
        branch: $branch,
        worktree_path: null,
        worktree_retained: false,
        worktree_retain_reason: null,
        issue_number: $issue,
        sub_tasks: [],
        current_phase: null,
        resume_point: null,
        budget_consumed_tokens: 0,
        budget_limit_tokens: 500000,
        context_warn_tokens: $ctx_warn,
        outer_iteration: 0,
        halt_audit: [],
        human_review_cycles: 0,
        github_pr_number: null,
        lessons_learned: [],
        session_summary: null,
        session_count: 0,
        handoff_reason: null,
        restart_failed: false,
        created_at: $now,
        updated_at: $now
      }')"

    _validate "$INITIAL_JSON"
    _atomic_write "$INITIAL_JSON"
    echo "workflow-state: initialised $STATE_FILE" >&2
    ;;

  # -------------------------------------------------------------------------
  # read <KEY>
  # -------------------------------------------------------------------------
  read)
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "{}"
    fi
    ;;

  # -------------------------------------------------------------------------
  # write <KEY> '<JSON>'
  # -------------------------------------------------------------------------
  write)
    JSON_INPUT="${3:?json required}"
    NOW="$(_now)"

    PATCHED="$(jq --arg now "$NOW" '.updated_at = $now' <<<"$JSON_INPUT")"

    _validate "$PATCHED"
    mkdir -p "$SPEC_FOLDER"
    _atomic_write "$PATCHED"
    ;;

  # -------------------------------------------------------------------------
  # patch <KEY> <JQ-PATH> <VALUE>
  # -------------------------------------------------------------------------
  patch)
    JQ_PATH="${3:?jq-path required (e.g. .current_phase)}"
    VALUE="${4:?value required (JSON literal, e.g. '\"implement\"')}"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    PATCHED="$(jq \
      --argjson v "$VALUE" \
      --arg now "$NOW" \
      "$JQ_PATH = \$v | .updated_at = \$now" \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;

  # -------------------------------------------------------------------------
  # append-lesson <KEY> "<TEXT>"
  # -------------------------------------------------------------------------
  append-lesson)
    TEXT="${3:?text required}"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    PATCHED="$(jq \
      --arg ts "$NOW" \
      --arg text "$TEXT" \
      '.lessons_learned += [{ts: $ts, text: $text}] | .updated_at = $ts' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;

  *)
    echo "workflow-state: unknown subcommand '$SUBCMD'. Valid: init|read|write|patch|append-lesson" >&2
    exit 1
    ;;
esac
