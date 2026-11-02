#!/usr/bin/env bash
# Manage specs/<key>-<slug>/workflow-state-<issue>.json for the PO-agent outer
# loop and interactive build sessions.
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
#   append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…] [OPTIONS]
#       Append a structured entry; optional --tier procedural|semantic,
#       --scope generalizable|local, --tags <csv>, --bundle <name>, --label <name>.
#       A generalizable lesson promotes immediately; procedural is the default
#       tier, and --tier semantic selects the semantic store.
#       CYCLE / TRIGGER / DESCRIPTION retain their schema constraints.
#       FILE…: zero or more repo-relative paths (variadic).
#   append-halt <KEY> <ISSUE_NUMBER> <CODE> <JSON-DATA>
#       Append {code, ts, data} to halt_audit[].
#   bump-structural-halt <KEY> <ISSUE_NUMBER> <CODE> [ORIGIN]
#       Increment structural_halt_cycles by 1 IFF <CODE> (with optional
#       <ORIGIN> for HALT-008) is a structural HALT (#347, epic #319). The
#       authoritative structural set is HALT-003, HALT-STRUCTURAL, HALT-010,
#       and HALT-008 with ORIGIN == outer_iteration. Non-structural codes
#       (HALT-007, HALT-007B, HALT-008 with origin merge_conflict/ci_failure,
#       any other code) are a no-op — the counter is left untouched and the
#       command exits 0. Called by the PO-agent EXACTLY ONCE per run at its
#       terminal state (Step 7), so the counter measures cross-run recurrence,
#       never within-run retries. Prints the resulting counter value to stdout.
#   recall-lessons <REPO|GIT-URL> [N] [--bundles <b1,b2,...>] [--labels <l1,l2,...>]
#       Print top-N lessons for the repository slug or remote URL across every
#       specs/*/workflow-state-*.json and every committed .makato/memory/*.jsonl.
#       Ordered by scope asc, occurrences DESC, ts DESC. Malformed JSONL lines in
#       the committed store are skipped without aborting (AC-4 / #470).
#       Filters match top-level bundle/label or captured source_events metadata.
#       Empty filters mean no-filter; the 2-arg call remains backward compatible.
#   summarise-lessons <KEY> <ISSUE_NUMBER>
#       Combine workflow-state lessons with issue-attributed change-lessons.jsonl
#       captures in lessons-YYYYMMDD-issue-<ISSUE_NUMBER>.md. Ambiguous legacy
#       captures fail rather than being assigned to an arbitrary issue.
#       Idempotent: re-running on the same day replaces the report atomically.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBCMD="${1:?subcommand required: init|read|write|patch|append-lesson|append-halt|bump-structural-halt|recall-lessons|summarise-lessons|append-decision}"
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
# Allow SPECS_DIR env override for offline smoke tests (mirrors the
# MAKATO_MEMORY_ROOT override in recall-lessons). Production callers
# must NOT set this — REPO_ROOT/specs is the canonical location.
SPECS_DIR="${SPECS_DIR:-$REPO_ROOT/specs}"
DEFAULT_SCHEMA_PATH="$SCRIPT_DIR/../skills/workflow-state/references/workflow-state.schema.json"
if [[ ! -f "$DEFAULT_SCHEMA_PATH" ]]; then
  DEFAULT_SCHEMA_PATH="$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json"
fi
SCHEMA_PATH="${SCHEMA_PATH:-$DEFAULT_SCHEMA_PATH}"

# ---------------------------------------------------------------------------
# Spec-folder resolution (duplicated from build-log.sh — intentional). An exact
# folder name is authoritative; a slug-prefix lookup must have one owner.
# ---------------------------------------------------------------------------
SPEC_FOLDER=""
if [[ "$SUBCMD" != "recall-lessons" ]]; then
  if [[ -d "$SPECS_DIR/$KEY" ]]; then
    SPEC_FOLDER="$SPECS_DIR/$KEY"
  elif [[ -d "$SPECS_DIR" ]]; then
    if ! SPEC_CANDIDATES="$(find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)"; then
      echo "workflow-state: unable to inspect spec folders in $SPECS_DIR" >&2
      exit 1
    fi
    SPEC_MATCH_COUNT=0
    SPEC_MATCHES=""
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      if [[ "${candidate##*/}" == "${KEY}-"* ]]; then
        SPEC_MATCH_COUNT=$((SPEC_MATCH_COUNT + 1))
        SPEC_MATCHES="${SPEC_MATCHES:+$'\n'}$candidate"
      fi
    done <<<"$SPEC_CANDIDATES"
    if ((SPEC_MATCH_COUNT > 1)); then
      echo "workflow-state: refusing ambiguous spec folders for key '$KEY'; pass an exact spec-folder name" >&2
      printf '%s\n' "$SPEC_MATCHES" >&2
      exit 1
    fi
    if ((SPEC_MATCH_COUNT == 1)); then
      SPEC_FOLDER="$SPEC_MATCHES"
    fi
  fi

  if [[ -z "$SPEC_FOLDER" ]]; then
    SPEC_FOLDER="$SPECS_DIR/$KEY"
  fi
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
    sys.stderr.write(
        "workflow-state: WARN — jsonschema not installed; "
        "degraded: schema-unvalidated (install jsonschema to enable full validation)\n"
    )
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

    # Derive a stable per-issue trace ID from static data: sha256(repo+issue_number).
    # Deterministic — same inputs always yield the same hex digest, so repeated
    # init calls (e.g. in tests) remain idempotent on this field. sha256sum is
    # available on macOS (via coreutils) and all Linux targets — no new deps.
    ISSUE_TRACE_ID="$(printf '%s%s' "$REPO" "$ISSUE_NUMBER" | sha256sum | cut -c1-64)"

    # Context-ceiling default — env var override, else 150000 (safe below the
    # observed 170 k degradation threshold for 200 k context models). See
    # GAP-004 / #30 extension and the field doc in workflow-state.schema.json.
    CTX_WARN="${MAKATO_CONTEXT_WARN_TOKENS:-150000}"

    INITIAL_JSON="$(jq -n \
      --arg repo "$REPO" \
      --arg branch "$BRANCH" \
      --argjson issue "$ISSUE_NUMBER" \
      --argjson ctx_warn "$CTX_WARN" \
      --arg trace_id "$ISSUE_TRACE_ID" \
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
        structural_halt_cycles: 0,
        reshape_cycles: 0,
        halt_audit: [],
        human_review_cycles: 0,
        review_rounds: 0,
        review_stagnant_rounds: 0,
        review_last_decision: null,
        github_pr_number: null,
        progress_comment_id: null,
        lessons_learned: [],
        session_summary: null,
        session_count: 0,
        handoff_reason: null,
        restart_failed: false,
        spawned_pid: null,
        resume_ack: null,
        issue_trace_id: $trace_id,
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
  # append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…] [OPTIONS]
  # Optional metadata stays absent unless the caller supplies it, preserving
  # the legacy local-workflow recall contract.
  # -------------------------------------------------------------------------
  append-lesson)
    ISSUE_NUMBER="${3:?issue_number required}"
    CYCLE="${4:?cycle required (integer ≥ 0)}"
    TRIGGER="${5:?trigger required (ci_failure|halt|review_comment|sensor|merge_conflict)}"
    DESCRIPTION="${6:?description required (≤ 200 chars)}"
    shift 6 || true
    LESSON_TIER=""
    LESSON_SCOPE=""
    TAGS_CSV=""
    BUNDLE=""
    LABEL=""
    HAS_TAGS=false
    FILE_ARGS=()
    while (( $# > 0 )); do
      case "$1" in
        --tier | --scope | --tags | --bundle | --label)
          option="$1"
          if (( $# < 2 )) || [[ "$2" == --* ]]; then
            echo "workflow-state: $option requires a value" >&2
            exit 1
          fi
          case "$option" in
            --tier) LESSON_TIER="$2" ;;
            --scope) LESSON_SCOPE="$2" ;;
            --tags) TAGS_CSV="$2"; HAS_TAGS=true ;;
            --bundle) BUNDLE="$2" ;;
            --label) LABEL="$2" ;;
          esac
          shift 2
          ;;
        --)
          shift
          FILE_ARGS+=("$@")
          break
          ;;
        --*)
          echo "workflow-state: append-lesson unrecognised option '$1'" >&2
          exit 1
          ;;
        *)
          FILE_ARGS+=("$1")
          shift
          ;;
      esac
    done
    _prepare_state_file "$ISSUE_NUMBER"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi
    if [[ ! "$CYCLE" =~ ^[0-9]+$ ]]; then
      echo "workflow-state: cycle must be a non-negative integer (got '$CYCLE')" >&2
      exit 1
    fi
    if [[ ! "$TRIGGER" =~ ^(ci_failure|halt|review_comment|sensor|merge_conflict)$ ]]; then
      echo "workflow-state: trigger must be one of ci_failure|halt|review_comment|sensor|merge_conflict (got '$TRIGGER')" >&2
      exit 1
    fi
    if [[ -n "$LESSON_TIER" && ! "$LESSON_TIER" =~ ^(procedural|semantic)$ ]]; then
      echo "workflow-state: tier must be procedural or semantic (got '$LESSON_TIER')" >&2
      exit 1
    fi
    if [[ -n "$LESSON_SCOPE" && ! "$LESSON_SCOPE" =~ ^(generalizable|local)$ ]]; then
      echo "workflow-state: scope must be generalizable or local (got '$LESSON_SCOPE')" >&2
      exit 1
    fi
    if [[ -n "$BUNDLE" && ! "$BUNDLE" =~ ^[^,]+$ ]]; then
      echo "workflow-state: bundle must be one non-empty value" >&2
      exit 1
    fi
    if [[ -n "$LABEL" && ! "$LABEL" =~ ^[^,]+$ ]]; then
      echo "workflow-state: label must be one non-empty value" >&2
      exit 1
    fi
    if (( ${#DESCRIPTION} > 200 )); then
      DESCRIPTION="${DESCRIPTION:0:199}…"
    fi

    FILES_JSON='[]'
    if (( ${#FILE_ARGS[@]} > 0 )); then
      FILES_JSON="$(printf '%s\n' "${FILE_ARGS[@]}" | jq -R . | jq -s .)"
    fi
    TAGS_JSON='[]'
    if [[ "$HAS_TAGS" == true && -n "$TAGS_CSV" ]]; then
      TAGS_JSON="$(TAGS_CSV="$TAGS_CSV" python3 - <<'PYEOF'
import json, os
print(json.dumps([tag.strip() for tag in os.environ["TAGS_CSV"].split(",") if tag.strip()]))
PYEOF
)"
    fi

    PATCHED="$(jq \
      --arg ts "$NOW" \
      --argjson cycle "$CYCLE" \
      --arg trigger "$TRIGGER" \
      --arg description "$DESCRIPTION" \
      --argjson files "$FILES_JSON" \
      --arg tier "$LESSON_TIER" \
      --arg scope "$LESSON_SCOPE" \
      --arg bundle "$BUNDLE" \
      --arg label "$LABEL" \
      --argjson tags "$TAGS_JSON" \
      --argjson has_tags "$HAS_TAGS" \
      '.lessons_learned += [{
         ts: $ts,
         cycle: $cycle,
         trigger: $trigger,
         description: $description,
         files_affected: $files
       } + (if $tier == "" then {} else {tier: $tier} end)
         + (if $scope == "" then {} else {scope: $scope} end)
         + (if $bundle == "" then {} else {bundle: $bundle} end)
         + (if $label == "" then {} else {label: $label} end)
         + (if $has_tags then {tags: $tags} else {} end)]
       | .updated_at = $ts' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    if [[ "$LESSON_SCOPE" == "generalizable" ]]; then
      SPEC_KEY="${SPEC_FOLDER##*/}"
      "$SCRIPT_DIR/../scripts/promote-lessons.sh" "$SPEC_KEY" "$SPECS_DIR" "$REPO_ROOT/.makato/memory/procedural.jsonl" "$REPO_ROOT/.makato/memory/semantic.jsonl"
    fi
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

  # -------------------------------------------------------------------------
  # bump-structural-halt <KEY> <ISSUE_NUMBER> <CODE> [ORIGIN]
  #
  # Increment structural_halt_cycles by exactly 1 IFF (CODE, ORIGIN) names a
  # structural HALT (#347, epic #319). This is the durable, cross-run
  # recurrence counter that AC-epic-1 of #319 needs to detect "repeated
  # structural failure on the same issue".
  #
  # Authoritative structural-HALT classification set:
  #   - HALT-003        (structural blocker — CRITICAL findings / STRUCTURAL MUST-FIX)
  #   - HALT-STRUCTURAL (a sub-agent escalated to refine and refine also failed)
  #   - HALT-010        (human_review_cycles ceiling — repeated re-shape need)
  #   - HALT-008 WITH ORIGIN == outer_iteration (re-plan budget exhausted)
  #
  # Explicitly NON-structural (no-op — counter untouched, exit 0):
  #   - HALT-007        (cost ceiling)
  #   - HALT-007B       (context handoff — quality control, run CONTINUES)
  #   - HALT-008 with ORIGIN merge_conflict | ci_failure (transient, not a
  #     structural defect of the story)
  #   - any other / unknown code
  #
  # The PO-agent calls this EXACTLY ONCE per run at its terminal state
  # (Step 7), so the counter reflects cross-run recurrence and never conflates
  # with the within-run outer_iteration counter. HALT-007B is deliberately a
  # no-op: the run has not terminated, it is handing off to a fresh session,
  # and that session MUST read the same structural_halt_cycles value — this is
  # the "context handoff does not reset the counter" contract (Scenario 3).
  #
  # Emits a JSONL audit line to orchestrate.jsonl on a real increment.
  # Prints the resulting counter value to stdout (unchanged on a no-op).
  # -------------------------------------------------------------------------
  bump-structural-halt)
    ISSUE_NUMBER="${3:?issue_number required}"
    CODE="${4:?halt code required (e.g. HALT-008, HALT-STRUCTURAL)}"
    ORIGIN="${5:-}"
    _prepare_state_file "$ISSUE_NUMBER"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    # Validate CODE shape (same gate as append-halt) so a typo is caught
    # rather than silently classified as non-structural.
    if [[ ! "$CODE" =~ ^HALT-([0-9]{3}[A-Z]?|STRUCTURAL)$ ]]; then
      echo "workflow-state: halt code must match HALT-NNN, HALT-NNN[A-Z], or HALT-STRUCTURAL (got '$CODE')" >&2
      exit 1
    fi

    # Authoritative structural classification. HALT-008 is structural ONLY
    # when its origin is the outer_iteration (re-plan) budget; the
    # merge_conflict and ci_failure origins are transient and excluded.
    is_structural=0
    case "$CODE" in
      HALT-003|HALT-STRUCTURAL|HALT-010)
        is_structural=1
        ;;
      HALT-008)
        if [[ "$ORIGIN" == "outer_iteration" ]]; then
          is_structural=1
        fi
        ;;
    esac

    # Current counter — default 0 for backward compatibility with in-flight
    # state files predating #347 (the field is optional in the schema).
    CURRENT="$(jq -r '.structural_halt_cycles // 0' "$STATE_FILE")"

    if (( is_structural == 0 )); then
      # Non-structural HALT (or HALT-008 with a non-outer_iteration origin):
      # leave the counter untouched. Exit 0 — this is the documented no-op.
      echo "$CURRENT"
      exit 0
    fi

    NOW="$(_now)"
    NEXT=$(( CURRENT + 1 ))

    # Patch the counter. Also backfill the field to CURRENT first via `// 0`
    # so a pre-#347 file that lacks the field gains it on the increment.
    PATCHED="$(jq \
      --argjson next "$NEXT" \
      --arg now "$NOW" \
      '.structural_halt_cycles = $next | .updated_at = $now' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"

    # Audit the increment to orchestrate.jsonl (best-effort — logging must
    # never fail the state mutation). Mirrors the dual-write convention in
    # halt-conditions.md: halt_audit[] for live state, orchestrate.jsonl for
    # the cross-session audit trail.
    if [[ -x "$REPO_ROOT/plugins/makato-build/shared/build-log.sh" ]]; then
      LOG_ENTRY="$(jq -n \
        --arg ts "$NOW" \
        --argjson issue "$ISSUE_NUMBER" \
        --arg code "$CODE" \
        --arg origin "$ORIGIN" \
        --argjson before "$CURRENT" \
        --argjson after "$NEXT" \
        '{ts: $ts, skill: "workflow-state", issue: $issue, step: "structural_halt_increment",
          status: "warn",
          data: {halt_code: $code, origin: (if $origin == "" then null else $origin end),
                 structural_halt_cycles_before: $before, structural_halt_cycles: $after}}')"
      "$REPO_ROOT/plugins/makato-build/shared/build-log.sh" "$KEY" "$LOG_ENTRY" 2>/dev/null || true
    fi

    echo "$NEXT"
    ;;
  #
  # matches REPO. Print the top-N (default 3) most recent lessons as a JSON
  # array, sorted by (cycle DESC, ts DESC). Used by the PO-agent at session
  # start (GAP-015 / #37 AC3) to inject warm-start context.
  #
  # ARG2 was bound to KEY at the top of the script — for this subcommand it
  # holds REPO. We do not touch SPEC_FOLDER / STATE_FILE here.
  # -------------------------------------------------------------------------
  recall-lessons)
    REPO="$ARG2"
    case "$REPO" in
      *://*) REPO="${REPO#*://}"; REPO="${REPO#*/}" ;;
      *@*:*/*) REPO="${REPO#*:}" ;;
    esac
    REPO="${REPO%.git}"
    REPO="${REPO#/}"
    REPO="${REPO%/}"

    # Parse positional N and optional --bundles / --labels flags.
    # Supports both:
    #   recall-lessons <REPO> [N]                                (AC-2 backward compat)
    #   recall-lessons <REPO> [N] [--bundles b1,b2] [--labels l1,l2]  (AC-1 / #470)
    # Parsing starts at $3 (after SUBCMD and REPO).
    LIMIT="3"
    BUNDLES_CSV=""
    LABELS_CSV=""
    _recall_idx=3
    # Capture positional N if it is a bare positive integer (not a flag).
    if [[ "${!_recall_idx:-}" =~ ^[0-9]+$ ]]; then
      LIMIT="${!_recall_idx}"
      _recall_idx=$(( _recall_idx + 1 ))
    fi
    # Parse remaining --bundles / --labels flags in any order.
    while [[ $_recall_idx -le $# ]]; do
      _flag="${!_recall_idx}"
      _recall_idx=$(( _recall_idx + 1 ))
      case "$_flag" in
        --bundles)
          BUNDLES_CSV="${!_recall_idx:-}"
          _recall_idx=$(( _recall_idx + 1 ))
          ;;
        --labels)
          LABELS_CSV="${!_recall_idx:-}"
          _recall_idx=$(( _recall_idx + 1 ))
          ;;
        *)
          echo "workflow-state: recall-lessons unrecognised argument '$_flag'" >&2
          exit 1
          ;;
      esac
    done

    if [[ ! "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then
      echo "workflow-state: recall-lessons N must be a positive integer (got '$LIMIT')" >&2
      exit 1
    fi

    # Resolve the committed memory store root. Callers may override via
    # MAKATO_MEMORY_ROOT for testing (AC-3 / AC-4 isolation). Default is the
    # main-checkout REPO_ROOT (NOT the worktree — committed store lives in main).
    MEMORY_ROOT="${MAKATO_MEMORY_ROOT:-$REPO_ROOT}"
    MEMORY_DIR="$MEMORY_ROOT/.makato/memory"

    # Build jq bundle/label filter expressions.
    # Empty CSV means no-filter (all lessons pass — AC-2 backward compat).
    # --argjson allows null for "no filter applied".
    BUNDLES_JSON="null"
    LABELS_JSON="null"
    if [[ -n "$BUNDLES_CSV" ]]; then
      BUNDLES_JSON="$(echo "$BUNDLES_CSV" | tr ',' '\n' | jq -R . | jq -s .)"
    fi
    if [[ -n "$LABELS_CSV" ]]; then
      LABELS_JSON="$(echo "$LABELS_CSV" | tr ',' '\n' | jq -R . | jq -s .)"
    fi

    # ----------------------------------------------------------------
    # Both capture sources are streamed through temp files (never argv): a
    # large memory store or workflow-state set would overflow the exec
    # argument limit if passed to jq via --argjson. Unexpected collection or
    # jq failures exit nonzero with stderr rather than degrading to [].
    # ----------------------------------------------------------------
    RECALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/workflow-state-recall.XXXXXX")"
    trap 'rm -rf "$RECALL_TMP"' EXIT
    WS_LESSONS_FILE="$RECALL_TMP/ws.jsonl"
    STORE_LESSONS_FILE="$RECALL_TMP/store.jsonl"
    : > "$WS_LESSONS_FILE"
    : > "$STORE_LESSONS_FILE"

    # ----------------------------------------------------------------
    # Step 1: Collect lessons from workflow-state-*.json files (live state).
    # find -exec ... {} + runs jq only when files exist and batches under the
    # argv limit; -c emits one lesson per line so batches concatenate safely.
    # ----------------------------------------------------------------
    if [[ -d "$SPECS_DIR" ]]; then
      # shellcheck disable=SC2016 # $repo is a jq variable, not a shell variable.
      find "$SPECS_DIR" -mindepth 2 -maxdepth 2 -type f -name 'workflow-state-*.json' \
        -exec jq -c --arg repo "$REPO" \
          'select(.repo == $repo) | (.lessons_learned // [])[]' {} + \
        > "$WS_LESSONS_FILE" \
        || { echo "workflow-state: recall-lessons failed collecting workflow-state lessons from $SPECS_DIR" >&2; exit 1; }
    fi

    # ----------------------------------------------------------------
    # Step 2: Collect lessons from the committed memory store.
    # Read each *.jsonl file in MEMORY_DIR line by line, skipping
    # malformed lines (AC-4 / #470). Missing directory is AC-3 (return []).
    # ----------------------------------------------------------------
    if [[ -d "$MEMORY_DIR" ]]; then
      python3 - "$MEMORY_DIR" "$REPO" > "$STORE_LESSONS_FILE" <<'PYEOF' \
        || { echo "workflow-state: recall-lessons failed collecting memory-store lessons from $MEMORY_DIR" >&2; exit 1; }
import sys, json, glob, os

memory_dir = sys.argv[1]
repo = sys.argv[2]

for fpath in sorted(glob.glob(os.path.join(memory_dir, "*.jsonl"))):
    # Binary read: undecodable bytes surface as ValueError on the line, so
    # they are skipped as malformed instead of aborting the whole store.
    with open(fpath, "rb") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                # AC-4: skip malformed lines silently
                continue
            if isinstance(obj, dict) and obj.get("repo") == repo:
                sys.stdout.write(json.dumps(obj) + "\n")
PYEOF
    fi

    # ----------------------------------------------------------------
    # Step 3: Merge, filter, sort, limit.
    # Filter: repo AND (bundle in my_bundles OR label in my_labels)
    #         when bundles/labels filters are non-empty (AC-1 / #470).
    #         When both are null, pass all lessons (AC-2 backward compat).
    # Order: scope asc (generalizable < local < other), then occurrences DESC,
    #        then ts DESC (AC-1 / #470).
    # Two-pass stable sort: ts DESC first (so within scope+occ ties newest wins),
    # then scope+occurrences as the primary stable key.
    # ----------------------------------------------------------------
    jq -n \
      --slurpfile ws    "$WS_LESSONS_FILE" \
      --slurpfile store "$STORE_LESSONS_FILE" \
      --argjson bundles "$BUNDLES_JSON" \
      --argjson labels  "$LABELS_JSON" \
      --argjson n       "$LIMIT" \
      '
      def matches_filter($values; $field):
        ([.[$field]] + [(.source_events // [])[]? | .[$field]]) as $candidates
        | any($candidates[]; . as $candidate | $candidate != null and ($values | index($candidate)) != null);
      ($ws + $store)
      | map(
          if ($bundles == null and $labels == null) then
            .
          else
            select(
              ($bundles != null and matches_filter($bundles; "bundle"))
              or
              ($labels != null and matches_filter($labels; "label"))
            )
          end
        )
      # Pass 1: sort by ts descending — so within scope+occurrences ties newest wins.
      | sort_by(.ts // "") | reverse
      # Pass 2: stable sort by [scope_rank asc, occurrences desc, cycle desc].
      # Adding -cycle as a tiebreaker after occurrences restores the legacy
      # cycle-DESC ordering for items that have no scope/occurrences fields
      # (AC-2 backward compat — the old sort was cycle DESC, ts DESC).
      # jq sort_by is stable: preserves the ts-desc order from pass 1 within
      # groups that share the same scope_rank, occurrences, and cycle.
      | sort_by([
          (if .scope == "generalizable" then 0 elif .scope == "local" then 1 else 2 end),
          ((.occurrences // 1) * -1),
          ((.cycle // 0) * -1)
        ])
      | .[0:$n]
      '
    ;;

  # -------------------------------------------------------------------------
  # summarise-lessons <KEY> <ISSUE_NUMBER>
  #
  # Render both capture sources without attributing another issue's lessons
  # to this run. Validate before replacing a previous report.
  # -------------------------------------------------------------------------
  summarise-lessons)
    ISSUE_NUMBER="${3:?issue_number required}"
    _prepare_state_file "$ISSUE_NUMBER"
    DATE_STAMP="$(date -u +%Y%m%d)"
    LESSONS_FILE="$SPEC_FOLDER/lessons-${DATE_STAMP}-issue-${ISSUE_NUMBER}.md"
    python3 - "$STATE_FILE" "$LESSONS_FILE" "$ISSUE_NUMBER" "$KEY" "$DATE_STAMP" <<'PYEOF'
import datetime
import json
import os
import pathlib
import re
import sys
import tempfile

state_path, output_path = map(pathlib.Path, sys.argv[1:3])
issue = int(sys.argv[3])
key, date_stamp = sys.argv[4:6]
raw_path = state_path.parent / "change-lessons.jsonl"


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def validate_lesson(entry, source, raw=False):
    if not isinstance(entry, dict):
        raise ValueError(f"{source}: lesson must be an object")
    body = entry.get("text", entry.get("description")) if raw else entry.get("description")
    if not nonempty_string(body) or not nonempty_string(entry.get("ts")):
        raise ValueError(f"{source}: lesson requires non-empty text and ts")
    datetime.datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
    for field in ("tags", "files_affected"):
        values = entry.get(field, [])
        if not isinstance(values, list) or not all(nonempty_string(value) for value in values):
            raise ValueError(f"{source}: {field} must be an array of non-empty strings")
    if raw:
        if entry.get("tier") not in ("procedural", "semantic") or entry.get("scope") not in ("generalizable", "local"):
            raise ValueError(f"{source}: invalid lesson tier or scope")
        if not all(nonempty_string(entry.get(field)) for field in ("key", "repo")):
            raise ValueError(f"{source}: lesson requires key and repo")
    elif type(entry.get("cycle")) is not int or entry["cycle"] < 0 or not nonempty_string(entry.get("trigger")):
        raise ValueError(f"{source}: invalid workflow lesson cycle or trigger")
    return dict(entry, description=body, source=source)


try:
    lessons = []
    sources = []
    state = {}
    if state_path.exists() or state_path.is_symlink():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if not isinstance(state, dict) or type(state.get("issue_number")) is not int or state["issue_number"] != issue:
            raise ValueError(f"{state_path}: issue_number does not match #{issue}")
        if not isinstance(state.get("lessons_learned"), list):
            raise ValueError(f"{state_path}: lessons_learned must be an array")
        if not all(nonempty_string(state.get(field)) for field in ("repo", "branch")):
            raise ValueError(f"{state_path}: repo and branch are required")
        sources.append(state_path.name)
        lessons.extend(validate_lesson(entry, state_path.name) for entry in state["lessons_learned"])
    if raw_path.exists() or raw_path.is_symlink():
        sources.append(raw_path.name)
        state_issues = {int(match.group(1)) for path in state_path.parent.glob("workflow-state-*.json")
                        if (match := re.fullmatch(r"workflow-state-([1-9][0-9]*)\.json", path.name))}
        for line_number, line in enumerate(raw_path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            source = f"{raw_path.name}:{line_number}"
            entry = validate_lesson(json.loads(line), source, raw=True)
            owner = entry.get("issue_number")
            if "issue_number" in entry:
                if type(owner) is not int or owner < 1:
                    raise ValueError(f"{source}: issue_number must be a positive integer")
            else:
                key_issues = {int(match.group(1)) for pattern in (r"^([1-9][0-9]*)(?:-|$)", r"(?:^|-)([1-9][0-9]*)$")
                              if (match := re.search(pattern, entry["key"]))}
                owners = key_issues or state_issues
                if len(owners) != 1:
                    raise ValueError(f"{source}: cannot attribute legacy lesson to one issue; add issue_number using verified provenance")
                owner = next(iter(owners))
            if owner == issue:
                if state and entry["repo"] != state["repo"]:
                    raise ValueError(f"{source}: repo does not match workflow state")
                lessons.append(entry)
    if not sources:
        raise ValueError(f"no lesson sources for issue #{issue} in {state_path.parent}")

    lines = [f"# Lessons learned — {key} #{issue} ({date_stamp})", "", f"- **Issue**: #{issue}"]
    repo = state.get("repo") or next((lesson["repo"] for lesson in lessons if lesson.get("repo")), None)
    if repo:
        lines.append(f"- **Repo**: {repo}")
    if state.get("branch"):
        lines.append(f"- **Branch**: {state['branch']}")
    lines.extend(["- **Sources**: " + ", ".join(f"specs/{state_path.parent.name}/{source}" for source in sources), ""])
    if not lessons:
        lines.append("_No lessons recorded for this issue in the inspected sources._")
    else:
        lines.extend([f"## Lessons ({len(lessons)}, newest first)", ""])
        for lesson in sorted(lessons, key=lambda item: (item.get("cycle", 0), item["ts"]), reverse=True):
            title = f"Cycle {lesson['cycle']} — {lesson['trigger']}" if "cycle" in lesson else lesson["tier"]
            lines.extend([f"### {title} — {lesson['ts']}", "", lesson["description"], "", f"**Source**: {lesson['source']}", ""])
            if lesson.get("files_affected"):
                lines.extend(["**Files**: " + ", ".join(lesson["files_affected"]), ""])
            metadata = [f"{field}: {lesson[field]}" for field in ("tier", "scope", "bundle", "label") if lesson.get(field)]
            if lesson.get("tags"):
                metadata.append("tags: " + ", ".join(lesson["tags"]))
            if metadata:
                lines.extend(["**Classification**: " + "; ".join(metadata), ""])
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output_path.parent, prefix=output_path.name + ".", delete=False) as handle:
            temporary = pathlib.Path(handle.name)
            handle.write("\n".join(lines) + "\n")
        os.replace(temporary, output_path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
except (OSError, ValueError, TypeError) as exc:
    print(f"workflow-state: unable to summarise lessons: {exc}", file=sys.stderr)
    sys.exit(1)
print(output_path)
PYEOF
    ;;

  # -------------------------------------------------------------------------
  # prune <KEY_GLOB> [AGE_DAYS]
  #
  # Remove workflow-state-*.json files whose current_phase is "done" AND
  # whose updated_at is older than AGE_DAYS days (default 30).
  # Non-done files and files within the age threshold are never touched.
  # Emits one stderr line per removed file: "workflow-state: pruned <path>".
  # Prints pruned count (integer) to stdout.
  # Idempotent: a second run with no qualifying files exits 0 with count=0.
  # -------------------------------------------------------------------------
  prune)
    KEY_GLOB="${2:?key_glob required (e.g. \"*\" or \"gap-*\")}"
    AGE_DAYS="${3:-30}"

    if ! [[ "$AGE_DAYS" =~ ^[0-9]+$ ]]; then
      echo "workflow-state: AGE_DAYS must be a non-negative integer (got '${AGE_DAYS}')" >&2
      exit 1
    fi

    PRUNED=0
    # Compute the cutoff epoch using python3 for portability (macOS/Linux).
    CUTOFF_EPOCH="$(python3 -c "
import time, sys
age_days = int(sys.argv[1])
print(int(time.time()) - age_days * 86400)
" "$AGE_DAYS")"

    # Iterate over all matching workflow-state-*.json files.
    # KEY_GLOB is expanded by the shell glob below against $SPECS_DIR.
    while IFS= read -r -d '' STATE_FILE_CANDIDATE; do
      # Read current_phase and updated_at from the candidate.
      if ! PHASE="$(jq -re '.current_phase // empty' "$STATE_FILE_CANDIDATE" 2>/dev/null)"; then
        continue
      fi
      if [[ "$PHASE" != "done" ]]; then
        continue
      fi

      UPDATED_AT="$(jq -re '.updated_at // empty' "$STATE_FILE_CANDIDATE" 2>/dev/null || true)"
      if [[ -z "$UPDATED_AT" ]]; then
        continue
      fi

      FILE_EPOCH="$(python3 -c "
import time, sys
from datetime import datetime, timezone
ts = sys.argv[1]
# Strip trailing Z, parse as UTC ISO-8601.
ts_clean = ts.rstrip('Z').split('+')[0]
try:
    dt = datetime.fromisoformat(ts_clean).replace(tzinfo=timezone.utc)
except ValueError:
    sys.exit(1)
print(int(dt.timestamp()))
" "$UPDATED_AT" 2>/dev/null || echo "")"

      if [[ -z "$FILE_EPOCH" ]]; then
        continue
      fi

      if (( FILE_EPOCH < CUTOFF_EPOCH )); then
        echo "workflow-state: pruned $STATE_FILE_CANDIDATE" >&2
        rm -f "$STATE_FILE_CANDIDATE"
        (( PRUNED++ )) || true
      fi
    done < <(find "$SPECS_DIR" -maxdepth 2 \
        -name 'workflow-state-*.json' \
        -path "*/${KEY_GLOB}/*" \
        -print0 2>/dev/null)

    echo "$PRUNED"
    ;;

  # -------------------------------------------------------------------------
  # append-decision <KEY> <ISSUE_NUMBER> <JSON-OBJECT>
  #
  # Append a design decision entry to design_decision[] (#603).
  # Schema: {id, ts, title, chosen, rationale} required;
  #         {rejected[], source} optional.
  #
  # The helper:
  #   - injects id (short ISO timestamp slug) and ts automatically
  #   - validates required keys: title, chosen, rationale
  #   - accepts optional: rejected (JSON array), source (string)
  #   - appends the entry to design_decision[] via a jq patch
  #   - updates updated_at
  #
  # Mirrors the append-lesson subcommand pattern.
  # -------------------------------------------------------------------------
  append-decision)
    ISSUE_NUMBER="${3:?issue_number required}"
    DECISION_JSON="${4:?json-object required}"
    _prepare_state_file "$ISSUE_NUMBER"
    NOW="$(_now)"

    if [[ ! -f "$STATE_FILE" ]]; then
      echo "workflow-state: $STATE_FILE not found — run 'init' first" >&2
      exit 1
    fi

    # Validate JSON parsability.
    if ! echo "$DECISION_JSON" | jq -e . >/dev/null 2>&1; then
      echo "workflow-state: append-decision requires a valid JSON object (got '${DECISION_JSON:0:60}')" >&2
      exit 1
    fi

    # Validate required keys: title, chosen, rationale.
    for REQ_KEY in title chosen rationale; do
      VAL="$(echo "$DECISION_JSON" | jq -r --arg k "$REQ_KEY" '.[$k] // empty' 2>/dev/null)"
      if [[ -z "$VAL" ]]; then
        echo "workflow-state: append-decision requires '$REQ_KEY' in JSON object" >&2
        exit 1
      fi
    done

    # Generate id as a short ISO timestamp slug (e.g. 20260803T110700Z).
    DECISION_ID="$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
print(now.strftime('%Y%m%dT%H%M%SZ'))
")"

    # Build the final entry: inject id and ts, pass the rest through.
    ENTRY="$(echo "$DECISION_JSON" | jq \
      --arg id "$DECISION_ID" \
      --arg ts "$NOW" \
      '. + {id: $id, ts: $ts}')"

    PATCHED="$(jq \
      --argjson entry "$ENTRY" \
      --arg ts "$NOW" \
      '(.design_decision //= []) | .design_decision += [$entry] | .updated_at = $ts' \
      "$STATE_FILE")"

    _validate "$PATCHED"
    _atomic_write "$PATCHED"
    ;;

  *)
    echo "workflow-state: unknown subcommand '$SUBCMD'. Valid: init|read|write|patch|append-lesson|append-halt|bump-structural-halt|recall-lessons|summarise-lessons|append-decision|prune" >&2
    exit 1
    ;;
esac
