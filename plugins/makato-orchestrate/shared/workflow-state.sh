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
#   append-lesson <KEY> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]
#       Append {ts, cycle, trigger, description, files_affected} to lessons_learned[].
#       CYCLE: outer_iteration integer ≥ 0.
#       TRIGGER: ci_failure|halt|review_comment|sensor|merge_conflict (schema enum).
#       DESCRIPTION: ≤ 200 chars (auto-truncated with '…').
#       FILE…: zero or more repo-relative paths (variadic).
#   recall-lessons <REPO> [N]
#       Print the top-N most recent lessons across every specs/*/workflow-state.json
#       whose .repo == REPO (default N=3). Output is a JSON array of lesson items,
#       newest first. Used by the PO-agent at session start (GAP-015 / #37 AC3) to
#       inject prior lessons into the coder dispatch bundle.
#   summarise-lessons <KEY>
#       Write specs/<key>-<slug>/lessons-YYYYMMDD.md from lessons_learned[]. Used by
#       the PO-agent at terminal states (success and HALT) per GAP-015 / #37 AC4.
#       Idempotent: re-running on the same day overwrites the file in place.
#
# Spec-folder resolution mirrors plugins/makato-build/shared/build-log.sh:13-22
# (duplicated, not sourced — build-log.sh is a standalone script with no exported
# functions; that contract is intentional per AGENTS.md).
#
# Validation: python3 + jsonschema (inline heredoc), fail-open if jsonschema is
# not installed. Matches plugins/makato-plan/skills/issue-to-project/sync-process.md
# precedent.
set -euo pipefail

SUBCMD="${1:?subcommand required: init|read|write|patch|append-lesson|append-halt|recall-lessons|summarise-lessons}"
# recall-lessons takes REPO as positional #2 (not KEY) — every other subcommand
# takes KEY. Resolve generically and have each subcommand re-bind the variable.
ARG2="${2:?second arg required (KEY for most subcommands, REPO for recall-lessons)}"
KEY="$ARG2"

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
        merge_conflict_cycles: 0,
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
  # append-lesson <KEY> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]
  #
  # Schema (GAP-015 / #37): {ts, cycle, trigger, description, files_affected}.
  # The helper:
  #   - injects ts automatically (caller never supplies it)
  #   - truncates description at 200 chars with '…' suffix (schema cap)
  #   - accepts zero or more files_affected as variadic positional args
  # -------------------------------------------------------------------------
  append-lesson)
    CYCLE="${3:?cycle required (integer ≥ 0)}"
    TRIGGER="${4:?trigger required (ci_failure|halt|review_comment|sensor|merge_conflict)}"
    DESCRIPTION="${5:?description required (≤ 200 chars)}"
    shift 5 || true
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    # Cycle must be a non-negative integer literal — refuse jq-injection via
    # a regex gate so we can pass it as a numeric argjson.
    if [[ ! "$CYCLE" =~ ^[0-9]+$ ]]; then
      echo "workflow-state: cycle must be a non-negative integer (got '$CYCLE')" >&2
      exit 1
    fi

    # Trigger enum must match the schema. Validate at the shell level too so
    # the guard holds even when jsonschema is not installed (validation is
    # fail-open in that case — see _validate).
    if [[ ! "$TRIGGER" =~ ^(ci_failure|halt|review_comment|sensor|merge_conflict)$ ]]; then
      echo "workflow-state: trigger must be one of ci_failure|halt|review_comment|sensor|merge_conflict (got '$TRIGGER')" >&2
      exit 1
    fi

    # Truncate at 200 chars (the schema's maxLength). Append a '…' suffix when
    # the input exceeds the cap so the audit trail shows truncation occurred.
    if (( ${#DESCRIPTION} > 200 )); then
      DESCRIPTION="${DESCRIPTION:0:199}…"
    fi

    # Build files_affected JSON array from the remaining variadic args.
    FILES_JSON='[]'
    if (( $# > 0 )); then
      FILES_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    fi

    PATCHED="$(jq \
      --arg ts "$NOW" \
      --argjson cycle "$CYCLE" \
      --arg trigger "$TRIGGER" \
      --arg description "$DESCRIPTION" \
      --argjson files "$FILES_JSON" \
      '.lessons_learned += [{
         ts: $ts,
         cycle: $cycle,
         trigger: $trigger,
         description: $description,
         files_affected: $files
       }] | .updated_at = $ts' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;

  # -------------------------------------------------------------------------
  # append-halt <KEY> <CODE> <JSON-DATA>
  #
  # Schema: {code, ts, data}. The helper:
  #   - injects ts automatically (caller never supplies it)
  #   - validates CODE matches the documented HALT code shape (HALT-NNN,
  #     HALT-NNN[A-Z], HALT-STRUCTURAL, or HALT-000)
  #   - validates JSON-DATA is a JSON object (refuses arrays, scalars, malformed)
  #   - merges via `+ [new]` to preserve immutable append-only semantics
  #
  # Replaces the open-coded `_append_halt_audit()` pattern in
  # context-handoff.sh and the inline patch sites in po-agent.md.
  # -------------------------------------------------------------------------
  append-halt)
    CODE="${3:?halt code required (e.g. HALT-007, HALT-007B, HALT-STRUCTURAL)}"
    if [[ $# -lt 4 ]]; then
      echo "workflow-state: halt data required (JSON object; use '{}' for an empty payload)" >&2
      exit 1
    fi
    DATA="$4"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    # Validate CODE shape: HALT-NNN, HALT-NNN[A-Z] (e.g. HALT-007B),
    # HALT-STRUCTURAL, or HALT-000. The shape is documented in
    # plugins/makato-orchestrate/halt-conditions.md.
    if [[ ! "$CODE" =~ ^HALT-([0-9]{3}[A-Z]?|STRUCTURAL)$ ]]; then
      echo "workflow-state: halt code must match HALT-NNN, HALT-NNN[A-Z], or HALT-STRUCTURAL (got '$CODE')" >&2
      exit 1
    fi

    # Validate DATA is a JSON object. Refuse arrays, scalars, malformed.
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$DATA"; then
      echo "workflow-state: halt data must be a JSON object (got: $DATA)" >&2
      exit 1
    fi

    PATCHED="$(jq \
      --arg code "$CODE" \
      --arg ts "$NOW" \
      --argjson data "$DATA" \
      '.halt_audit += [{
         code: $code,
         ts: $ts,
         data: $data
       }] | .updated_at = $ts' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;
  #
  # Aggregate lessons across every specs/*/workflow-state.json whose .repo
  # matches REPO. Print the top-N (default 3) most recent lessons as a JSON
  # array, sorted by (cycle DESC, ts DESC). Used by the PO-agent at session
  # start (GAP-015 / #37 AC3) to inject warm-start context.
  #
  # ARG2 was bound to KEY at the top of the script — for this subcommand it
  # holds REPO. We do not touch SPEC_FOLDER / STATE_FILE here.
  # -------------------------------------------------------------------------
  recall-lessons)
    REPO="$ARG2"
    LIMIT="${3:-3}"

    if [[ ! "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then
      echo "workflow-state: recall-lessons N must be a positive integer (got '$LIMIT')" >&2
      exit 1
    fi

    if [[ ! -d "$SPECS_DIR" ]]; then
      echo '[]'
      exit 0
    fi

    # Find every workflow-state.json under specs/, filter by .repo == REPO,
    # flatten .lessons_learned[] across the matching states, sort newest first.
    # Pass all paths to a single `jq -s` invocation (slurps the parsed payloads
    # into one array) — O(1) jq forks instead of O(N) under xargs -I{}.
    find "$SPECS_DIR" -mindepth 2 -maxdepth 2 -type f -name workflow-state.json -print0 2>/dev/null |
      xargs -0 jq -s --arg repo "$REPO" --argjson n "$LIMIT" \
        '[.[] | select(.repo == $repo) | (.lessons_learned // [])[]]
         | sort_by([.cycle, .ts]) | reverse | .[0:$n]' \
        2>/dev/null
    ;;

  # -------------------------------------------------------------------------
  # summarise-lessons <KEY>
  #
  # Render lessons_learned[] as specs/<key>-<slug>/lessons-YYYYMMDD.md per
  # GAP-015 / #37 AC4. Idempotent: a second call on the same day overwrites.
  # No-op (and zero-row file with a stub header) when lessons_learned is empty
  # — the file's existence is the audit signal.
  # -------------------------------------------------------------------------
  summarise-lessons)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — nothing to summarise" >&2
      exit 1
    fi

    DATE_STAMP="$(date -u +%Y%m%d)"
    LESSONS_FILE="$SPEC_FOLDER/lessons-${DATE_STAMP}.md"
    REPO="$(jq -r '.repo' "$STATE_FILE")"
    ISSUE="$(jq -r '.issue_number' "$STATE_FILE")"
    BRANCH="$(jq -r '.branch' "$STATE_FILE")"

    {
      echo "# Lessons learned — ${KEY} (${DATE_STAMP})"
      echo
      echo "- **Repo**: \`${REPO}\`"
      echo "- **Issue**: #${ISSUE}"
      echo "- **Branch**: \`${BRANCH}\`"
      echo "- **Source**: \`specs/${SPEC_FOLDER##*/}/workflow-state.json\`"
      echo
      LESSON_COUNT="$(jq '.lessons_learned | length' "$STATE_FILE")"
      if (( LESSON_COUNT == 0 )); then
        echo "_No lessons recorded for this run._"
      else
        echo "## Lessons (${LESSON_COUNT}, newest first)"
        echo
        jq -r '
          .lessons_learned
          | sort_by([.cycle, .ts])
          | reverse
          | .[]
          | "### Cycle \(.cycle) — \(.trigger) — \(.ts)\n\n\(.description)\n" +
            (if (.files_affected | length) > 0
               then "\n**Files**: " + (.files_affected | map("`" + . + "`") | join(", ")) + "\n"
               else "" end)
        ' "$STATE_FILE"
      fi
    } > "$LESSONS_FILE"

    echo "$LESSONS_FILE"
    ;;

  *)
    echo "workflow-state: unknown subcommand '$SUBCMD'. Valid: init|read|write|patch|append-lesson|append-halt|recall-lessons|summarise-lessons" >&2
    exit 1
    ;;
esac
