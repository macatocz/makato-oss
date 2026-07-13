#!/usr/bin/env bash
# Manage specs/<key>-<slug>/workflow-state-<issue>.json for the PO-agent outer loop.
#
# Per-issue file layout — see #173. Multiple GitHub issues can share a single
# story-level spec folder (e.g. `specs/agent-skill-routing/` covers #143–#147).
# Each issue owns its own `workflow-state-<issue>.json`; `init` on a second
# issue no longer clobbers a prior issue's audit trail.
#
# Subcommands:
#   init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>
#       Create workflow-state-<ISSUE_NUMBER>.json with valid defaults. Errors if it exists.
#   read <KEY> <ISSUE_NUMBER>
#       Print the full JSON object to stdout, or "{}" if missing.
#   write <KEY> <ISSUE_NUMBER> '<JSON>'
#       Validate then overwrite the file. updated_at is injected automatically.
#   patch <KEY> <ISSUE_NUMBER> <JQ-PATH> <VALUE>
#       Apply a jq-style field update. JQ-PATH like .current_phase or .sub_tasks[0].status.
#       VALUE is a JSON literal: '"implement"', '3', 'true', '{...}'.
#   append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]
#       Append {ts, cycle, trigger, description, files_affected} to lessons_learned[].
#       CYCLE: outer_iteration integer ≥ 0.
#       TRIGGER: ci_failure|halt|review_comment|sensor|merge_conflict (schema enum).
#       DESCRIPTION: ≤ 200 chars (auto-truncated with '…').
#       FILE…: zero or more repo-relative paths (variadic).
#   append-halt <KEY> <ISSUE_NUMBER> <CODE> <JSON-DATA>
#       Append {code, ts, data} to halt_audit[].
#   recall-lessons <REPO> [N]
#       Print the top-N most recent lessons across every
#       specs/*/workflow-state-*.json whose .repo == REPO (default N=3). Output is
#       a JSON array of lesson items, newest first. Used by the PO-agent at
#       session start (GAP-015 / #37 AC3) to inject prior lessons into the coder
#       dispatch bundle. Signature unchanged — the aggregator glob widened.
#   summarise-lessons <KEY> <ISSUE_NUMBER>
#       Write specs/<key>-<slug>/lessons-YYYYMMDD.md from lessons_learned[]. Used by
#       the PO-agent at terminal states (success and HALT) per GAP-015 / #37 AC4.
#       Idempotent: re-running on the same day overwrites the file in place.
#
# Backward compatibility: on the first read/mutate for a given (KEY, ISSUE_NUMBER),
# if a legacy specs/<KEY>/workflow-state.json exists and the per-issue file does
# not, it is promoted in place via `mv` to workflow-state-<its own .issue_number>.json.
# The promotion is atomic and idempotent — a second reader that arrives after the
# rename falls through to the renamed file cleanly. Issue mismatch (caller-supplied
# ISSUE_NUMBER != legacy file's own field) still migrates the legacy file to its
# correct name and the caller receives the {} / on-disk read as appropriate.
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

# Resolve to the MAIN checkout's repo root — NOT the per-run worktree. The
# entire autonomous run lives in a git worktree (NEVER 10), and specs/ is
# gitignored, so a fresh `git worktree add` has no specs/ content. A bare
# `git rev-parse --show-toplevel` here would resolve state files under the
# worktree copy of specs/, while the sibling build-log.sh (which uses
# --git-common-dir) writes build.jsonl under the main checkout — splitting the
# state and audit trail across two disconnected trees (#282). Mirror
# build-log.sh:34-42 exactly: derive REPO_ROOT from the COMMON git dir, which
# always points at the main repo's .git regardless of the caller's CWD.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  # `--git-common-dir` may be relative to CWD; absolutise via the parent dir.
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  # Outside a git repo entirely — degrade to the legacy behaviour so the
  # script never crashes in test fixtures or scratch dirs.
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
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

# STATE_FILE is now issue-scoped and populated per-subcommand once ISSUE_NUMBER
# is validated. Recall-lessons never sets it — it iterates over every match in
# SPECS_DIR directly.
STATE_FILE=""

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
# ISSUE_NUMBER validation — schema says integer ≥ 1. Reject anything else at
# the shell layer so we get a clear diagnostic before touching the filesystem.
# The bash-level check doubles the jsonschema check because validation is
# fail-open when jsonschema is not installed.
# ---------------------------------------------------------------------------
_validate_issue_number() {
  local candidate="$1"
  if [[ ! "$candidate" =~ ^[1-9][0-9]*$ ]]; then
    echo "workflow-state: ISSUE_NUMBER must be a positive integer (got '$candidate')" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Given a validated ISSUE_NUMBER, resolve $SPEC_FOLDER/workflow-state-<issue>.json.
# Called by every subcommand except recall-lessons after ISSUE_NUMBER is validated.
# ---------------------------------------------------------------------------
_resolve_state_file() {
  local issue="$1"
  STATE_FILE="$SPEC_FOLDER/workflow-state-${issue}.json"
}

# ---------------------------------------------------------------------------
# Prepare STATE_FILE for a mutating/reading subcommand: validate ISSUE_NUMBER,
# migrate any legacy `workflow-state.json` in this spec folder to its per-issue
# name, then resolve STATE_FILE to the target per-issue path.
#
# Called by every subcommand except `init` (which deliberately skips migration —
# it creates a fresh per-issue file and must not silently absorb a legacy file
# that may belong to a different issue) and `recall-lessons` (which glob-scans
# every spec folder directly).
# ---------------------------------------------------------------------------
_prepare_state_file() {
  local issue="$1"
  _validate_issue_number "$issue"
  _migrate_legacy_state
  _resolve_state_file "$issue"
}

# ---------------------------------------------------------------------------
# Backward-compat migration (#173).
#
# If a legacy specs/<KEY>/workflow-state.json exists AND the per-issue file
# does not, read the legacy file's own `.issue_number` field, compute the
# per-issue path from it, and `mv` atomically. Idempotent when the per-issue
# path already exists (silent no-op). The rename is content-driven — the
# caller-supplied ISSUE_NUMBER is not used to name the promoted file, so a
# caller reading with a mismatched ISSUE_NUMBER sees `{}` after promotion,
# which is the correct behaviour (the legacy file belongs to a different
# issue and the caller can now `init` its own).
#
# Called before any subcommand body that references STATE_FILE. Not called by
# recall-lessons — the glob widening in that subcommand covers already-migrated
# files, and any not-yet-migrated legacy file simply won't be picked up until
# something else touches it (an acceptable degradation for the aggregate view).
# ---------------------------------------------------------------------------
_migrate_legacy_state() {
  local legacy="$SPEC_FOLDER/workflow-state.json"
  [[ -f "$legacy" ]] || return 0

  local legacy_issue
  legacy_issue="$(jq -r '.issue_number // empty' "$legacy" 2>/dev/null || true)"
  if [[ -z "$legacy_issue" ]] || [[ ! "$legacy_issue" =~ ^[1-9][0-9]*$ ]]; then
    # Legacy file is malformed (no valid issue_number) — leave it for a human
    # to inspect. Do not silently delete or rename to a bogus target.
    echo "workflow-state: legacy $legacy has no valid .issue_number field — skipping migration" >&2
    return 0
  fi

  local target="$SPEC_FOLDER/workflow-state-${legacy_issue}.json"
  if [[ -f "$target" ]]; then
    # Two-writer race: the per-issue file was created after the legacy file.
    # The per-issue file wins — the legacy is stale by definition and would
    # only cause confusion. Move it aside so audit trails preserve evidence.
    # `mv || true` because a concurrent second reader may already have won
    # the race and renamed the legacy file out from under us. `[[ ! -f
    # "$legacy" ]]` after the mv confirms the file is gone regardless of
    # which caller performed the rename.
    mv "$legacy" "${legacy}.superseded-by-${legacy_issue}" 2>/dev/null || true
    [[ ! -f "$legacy" ]] || return 0
    echo "workflow-state: legacy $legacy preserved as ${legacy##*/}.superseded-by-${legacy_issue} (target existed)" >&2
    return 0
  fi

  # Primary migration path. `mv || true` because a concurrent caller may
  # have won the race and already migrated the legacy file. If the target
  # exists after the mv attempt, migration succeeded (either by us or by
  # the other caller) — return cleanly.
  mv "$legacy" "$target" 2>/dev/null || true
  if [[ -f "$target" ]]; then
    echo "workflow-state: migrated legacy $legacy → ${target##*/}" >&2
  fi
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

# ---------------------------------------------------------------------------
# .worktree_path patch validator (#170 Fix 3).
#
# The invariant is: `worktree_path != null ⟺ a worktree at that path is
# registered with this repo's git`. Historically the `patch` subcommand
# accepted any JSON literal for any field, so a caller (or a PO-agent whose
# model tried to self-repair a failed `git worktree add`) could patch
# `.worktree_path` to the main repo root and destroy workspace isolation.
# See #170 § *Impact* for the concrete incident.
#
# This validator refuses `.worktree_path` writes that do not satisfy the
# invariant. Explicit-null writes are always allowed (the invariant permits
# a null path when no worktree is on disk — `worktree.sh cleanup` uses
# this). Non-null writes must resolve to a path that appears in
# `git worktree list --porcelain` of the current repo. The path comparison
# uses realpath canonicalisation so a caller passing an unresolved symlink
# still matches the git-registered canonical form (matches worktree.sh's
# own `_is_registered_worktree` helper).
#
# Bypass: MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1 is honoured for
# smoke-test scenarios that exercise the invariant itself. Production
# callers must NOT set this.
# ---------------------------------------------------------------------------
_validate_worktree_path_write() {
  local jq_path="$1" value="$2"

  # Only guard .worktree_path — every other field falls through untouched.
  [[ "$jq_path" == ".worktree_path" ]] || return 0

  # Explicit null is always permitted. jq -e -n `<value> == null` yields
  # exit 0 on null literal and non-zero otherwise; using it here means
  # we accept `null`, `"null"` treated as a string is not accepted, and
  # any other malformed literal falls through to git's registration check
  # below (which will fail loudly).
  if jq -e -n --argjson v "$value" '$v == null' >/dev/null 2>&1; then
    return 0
  fi

  # Test-scenario bypass. Documented above; not a production knob.
  if [[ "${MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED:-0}" == "1" ]]; then
    return 0
  fi

  # Extract the string value. jq -r on a JSON string yields the raw path;
  # on a non-string it yields e.g. "true"/"3" which will not match any
  # registered worktree — that failure surfaces below with a clear message.
  local candidate
  candidate="$(jq -r <<<"$value")"
  if [[ -z "$candidate" || "$candidate" == "null" ]]; then
    # Empty string or literal-null-as-string — reject with a specific
    # diagnostic so callers know the expected shape.
    echo "workflow-state: refusing .worktree_path write — value must be JSON null or a registered worktree path (got: $value)" >&2
    exit 1
  fi

  # Canonicalise so /var vs /private/var on macOS matches git's own
  # canonicalisation. Delegate to python3 for realpath — matches the
  # exact primitive worktree.sh uses.
  local candidate_real
  candidate_real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null || echo "$candidate")"

  # Extra guard (#170 exact incident): the main repo root IS registered
  # as a worktree in git's own list — it is the primary worktree. Refuse
  # writes that point at it. The isolation invariant is "PO-agent operates
  # in a worktree UNDER .claude/worktrees/, never in the main checkout".
  local repo_root_real
  repo_root_real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
  if [[ "$candidate_real" == "$repo_root_real" ]]; then
    {
      echo "workflow-state: refusing .worktree_path write — $candidate resolves to the main-repo root"
      echo "workflow-state: PO-agent must operate in a per-run worktree under .claude/worktrees/, not the main checkout (#170)"
      echo "workflow-state: (tests may bypass with MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1)"
    } >&2
    exit 1
  fi

  # Scan `git worktree list --porcelain` and compare canonicalised paths.
  # Same parser shape as worktree.sh (`_is_registered_worktree`) so both
  # helpers agree on what "registered" means. Uses `git -C "$REPO_ROOT"`
  # so it works when this helper is invoked from anywhere in the tree.
  local porcelain line wt resolved
  porcelain="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    wt="${line#worktree }"
    resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$wt" 2>/dev/null || echo "$wt")"
    if [[ "$resolved" == "$candidate_real" ]]; then
      return 0
    fi
  done <<<"$porcelain"

  # Not registered — refuse. This is the guard that blocks the #170
  # incident (PO-agent patching .worktree_path to the main-repo root
  # after a failed self-recovery).
  {
    echo "workflow-state: refusing .worktree_path write — $candidate is not a registered git worktree of $REPO_ROOT"
    echo "workflow-state: use plugins/makato-orchestrate/shared/worktree.sh create to establish a worktree, then let it patch state"
    echo "workflow-state: (see #170 for rationale; tests may bypass with MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1)"
  } >&2
  exit 1
}

case "$SUBCMD" in

  # -------------------------------------------------------------------------
  # init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>
  # -------------------------------------------------------------------------
  init)
    REPO="${3:?repo required (owner/name form)}"
    BRANCH="${4:?branch required}"
    ISSUE_NUMBER="${5:?issue_number required}"
    _validate_issue_number "$ISSUE_NUMBER"
    # NB: init deliberately skips _migrate_legacy_state (unlike the shared
    # `_prepare_state_file` helper below). A fresh init creates a brand-new
    # per-issue file; silently absorbing a legacy `workflow-state.json` here
    # could conflate two different issues' state under the wrong file name.
    _resolve_state_file "$ISSUE_NUMBER"

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
        session_baseline_tokens: 0,
        budget_limit_tokens: 500000,
        context_warn_tokens: $ctx_warn,
        outer_iteration: 0,
        merge_conflict_cycles: 0,
        ci_failure_cycles: 0,
        halt_audit: [],
        human_review_cycles: 0,
        github_pr_number: null,
        progress_comment_id: null,
        lessons_learned: [],
        session_summary: null,
        session_count: 0,
        handoff_reason: null,
        restart_failed: false,
        spawned_pid: null,
        resume_ack: null,
        created_at: $now,
        updated_at: $now
      }')"

    _validate "$INITIAL_JSON"
    _atomic_write "$INITIAL_JSON"
    echo "workflow-state: initialised $STATE_FILE" >&2
    ;;

  # -------------------------------------------------------------------------
  # read <KEY> <ISSUE_NUMBER>
  # -------------------------------------------------------------------------
  read)
    ISSUE_NUMBER="${3:?issue_number required}"
    _prepare_state_file "$ISSUE_NUMBER"
    if [[ -f "$STATE_FILE" ]]; then
      cat "$STATE_FILE"
    else
      echo "{}"
    fi
    ;;

  # -------------------------------------------------------------------------
  # write <KEY> <ISSUE_NUMBER> '<JSON>'
  # -------------------------------------------------------------------------
  write)
    ISSUE_NUMBER="${3:?issue_number required}"
    JSON_INPUT="${4:?json required}"
    _prepare_state_file "$ISSUE_NUMBER"
    NOW="$(_now)"

    PATCHED="$(jq --arg now "$NOW" '.updated_at = $now' <<<"$JSON_INPUT")"

    _validate "$PATCHED"
    mkdir -p "$SPEC_FOLDER"
    _atomic_write "$PATCHED"
    ;;

  # -------------------------------------------------------------------------
  # patch <KEY> <ISSUE_NUMBER> <JQ-PATH> <VALUE>
  # -------------------------------------------------------------------------
  patch)
    ISSUE_NUMBER="${3:?issue_number required}"
    JQ_PATH="${4:?jq-path required (e.g. .current_phase)}"
    VALUE="${5:?value required (JSON literal, e.g. '\"implement\"')}"
    _prepare_state_file "$ISSUE_NUMBER"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    # #170 Fix 3 — refuse .worktree_path writes to unregistered paths so
    # a caller cannot fabricate the isolation invariant. See helper for
    # the full contract, bypass, and rationale.
    _validate_worktree_path_write "$JQ_PATH" "$VALUE"

    PATCHED="$(jq \
      --argjson v "$VALUE" \
      --arg now "$NOW" \
      "$JQ_PATH = \$v | .updated_at = \$now" \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;

  # -------------------------------------------------------------------------
  # append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]
  #
  # Schema (GAP-015 / #37): {ts, cycle, trigger, description, files_affected}.
  # The helper:
  #   - injects ts automatically (caller never supplies it)
  #   - truncates description at 200 chars with '…' suffix (schema cap)
  #   - accepts zero or more files_affected as variadic positional args
  # -------------------------------------------------------------------------
  append-lesson)
    ISSUE_NUMBER="${3:?issue_number required}"
    CYCLE="${4:?cycle required (integer ≥ 0)}"
    TRIGGER="${5:?trigger required (ci_failure|halt|review_comment|sensor|merge_conflict)}"
    DESCRIPTION="${6:?description required (≤ 200 chars)}"
    shift 6 || true
    _prepare_state_file "$ISSUE_NUMBER"
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
  # append-halt <KEY> <ISSUE_NUMBER> <CODE> <JSON-DATA>
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
    ISSUE_NUMBER="${3:?issue_number required}"
    CODE="${4:?halt code required (e.g. HALT-007, HALT-007B, HALT-STRUCTURAL)}"
    if [[ $# -lt 5 ]]; then
      echo "workflow-state: halt data required (JSON object; use '{}' for an empty payload)" >&2
      exit 1
    fi
    DATA="$5"
    _prepare_state_file "$ISSUE_NUMBER"
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
  # Aggregate lessons across every specs/*/workflow-state-*.json whose .repo
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

    # Find every workflow-state-*.json under specs/, filter by .repo == REPO,
    # flatten .lessons_learned[] across the matching states, sort newest first.
    # Pass all paths to a single `jq -s` invocation (slurps the parsed payloads
    # into one array) — O(1) jq forks instead of O(N) under xargs -I{}.
    #
    # Glob widened from workflow-state.json to workflow-state-*.json (#173).
    # Any legacy pre-migration files are picked up by their next read/mutate;
    # this aggregate view intentionally ignores them until then.
    find "$SPECS_DIR" -mindepth 2 -maxdepth 2 -type f -name 'workflow-state-*.json' -print0 2>/dev/null |
      xargs -0 jq -s --arg repo "$REPO" --argjson n "$LIMIT" \
        '[.[] | select(.repo == $repo) | (.lessons_learned // [])[]]
         | sort_by([.cycle, .ts]) | reverse | .[0:$n]' \
        2>/dev/null
    ;;

  # -------------------------------------------------------------------------
  # summarise-lessons <KEY> <ISSUE_NUMBER>
  #
  # Render lessons_learned[] as specs/<key>-<slug>/lessons-YYYYMMDD.md per
  # GAP-015 / #37 AC4. Idempotent: a second call on the same day overwrites.
  # No-op (and zero-row file with a stub header) when lessons_learned is empty
  # — the file's existence is the audit signal.
  # -------------------------------------------------------------------------
  summarise-lessons)
    ISSUE_NUMBER="${3:?issue_number required}"
    _prepare_state_file "$ISSUE_NUMBER"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — nothing to summarise" >&2
      exit 1
    fi

    DATE_STAMP="$(date -u +%Y%m%d)"
    LESSONS_FILE="$SPEC_FOLDER/lessons-${DATE_STAMP}-issue-${ISSUE_NUMBER}.md"
    REPO="$(jq -r '.repo' "$STATE_FILE")"
    ISSUE="$(jq -r '.issue_number' "$STATE_FILE")"
    BRANCH="$(jq -r '.branch' "$STATE_FILE")"

    {
      echo "# Lessons learned — ${KEY} #${ISSUE} (${DATE_STAMP})"
      echo
      echo "- **Repo**: \`${REPO}\`"
      echo "- **Issue**: #${ISSUE}"
      echo "- **Branch**: \`${BRANCH}\`"
      echo "- **Source**: \`specs/${SPEC_FOLDER##*/}/workflow-state-${ISSUE}.json\`"
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
