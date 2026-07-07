#!/usr/bin/env bash
# loop.sh — autonomous polling driver for the PO-agent (GAP-007 / #33).
#
# Polls a GitHub Projects v2 board for items whose Status equals the
# configured "ready" option (default "Ready"). For each board item not
# already tracked (no in-flight `workflow-state.json` for the issue),
# dispatches the PO-agent serially.
#
# Single-threaded: at most one PO-agent runs at a time; the next item is
# not picked up until the current workflow-state's `current_phase` is
# `done` or the loop exits on a HALT.
#
# The queue source is the **board**, not labels. The repo's label set has
# no `status:ready` label (the `status:*` taxonomy is dormant per
# `to-issues` v3.2.0 — `issue-to-project` writes Status on the board
# instead). `loop` reads `.claude/config.json` → `github_project` to
# resolve the project owner/number/status-option, then polls
# `gh project item-list` and filters by the resolved Status text.
#
# Subcommands:
#   run [--status <NAME>] [--interval <S>] [--dry-run] [--once]
#       Long-running poll loop. Default Status: the option labelled
#       "Ready" in github_project.fields.status (or override via
#       MAKATO_LOOP_STATUS).
#
#   poll [STATUS_NAME]
#       Print the queue as JSON: a flat array of {issue, repository,
#       title, url, status, labels} for board items matching STATUS_NAME.
#
#   next [STATUS_NAME]
#       Print the issue_number of the first untracked open issue, or
#       empty string if the queue is empty or fully in-flight.
#
#   status
#       Pretty-print `.claude/state/loop-status.json` (or `{}` if missing).
#
#   dispatch <ISSUE_NUMBER> [--dry-run]
#       Dispatch one issue. Writes loop-status.json with active_workflow,
#       execs `$MAKATO_CLAUDE_BIN --dangerously-skip-permissions -p "<po-agent delegation prompt>"`
#       (or echoes the planned command under --dry-run), clears
#       active_workflow on return.
#
#   check-halt
#       Exit 0 if `~/.claude/HALT` (or `$MAKATO_HALT_FILE`) is absent,
#       exit 1 otherwise. Mirrors hooks/check-halt.sh's contract.
#
# Environment variables:
#   MAKATO_LOOP_INTERVAL       Poll interval in seconds (default 300).
#   MAKATO_LOOP_STATUS         Default Status name override
#                              (CLI flag wins). Default: "Ready".
#   MAKATO_LOOP_CONFIG         Override path to .claude/config.json
#                              (tests only).
#   MAKATO_CLAUDE_BIN          Path to claude binary (default: `claude`).
#                              Tests stub this.
#   MAKATO_HALT_FILE           HALT-file path override
#                              (default ~/.claude/HALT).
#   MAKATO_LOOP_STATE_DIR      Override `.claude/state/` location
#                              (tests only).
#   MAKATO_LOOP_DRY_DISPATCH=1 Internal test hook: instead of execing
#                              claude, write `last_dispatch_issue` to
#                              loop-status.json and return 0. Used by
#                              smoke tests so they exercise the full
#                              code path without a real subprocess.
#   MAKATO_LOOP_GH_OVERRIDE    Tests only: path to a JSON file holding
#                              the pre-canned `gh project item-list`
#                              result. When set, `cmd_poll` reads this
#                              file instead of invoking `gh`. Keeps
#                              smoke tests fully offline.
#
# Conventions: matches scripts/context-handoff.sh (POSIX-ish bash, `set
# -euo pipefail`, python3 for ISO-8601 millisecond timestamps, jq for
# JSON work).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPECS_DIR="$REPO_ROOT/specs"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
STATUS_FILE="$STATE_DIR/loop-status.json"
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"
CONFIG_FILE="${MAKATO_LOOP_CONFIG:-$REPO_ROOT/.claude/config.json}"
DEFAULT_INTERVAL="${MAKATO_LOOP_INTERVAL:-300}"
DEFAULT_STATUS="${MAKATO_LOOP_STATUS:-Ready}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Matches workflow-state.sh.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Read .claude/config.json → github_project. Outputs a JSON object with the
# four fields the loop needs: {owner, number, host, status_field_name}.
# `status_field_name` is hardcoded to "Status" (the GitHub Projects v2
# default — sibling `issue-to-project` makes the same assumption).
#
# Exits with a clear error if the file is missing or malformed. Tests can
# substitute via MAKATO_LOOP_CONFIG.
# ---------------------------------------------------------------------------
_read_project_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: .claude/config.json not found at $CONFIG_FILE — run \`issue-to-project --init\` first" >&2
    return 65
  fi
  local owner number host
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  if [[ -z "$owner" || -z "$number" ]]; then
    echo "loop: github_project.owner / github_project.number missing in $CONFIG_FILE — run \`issue-to-project --init\`" >&2
    return 65
  fi
  jq -n --arg owner "$owner" --arg number "$number" --arg host "$host" \
    '{owner: $owner, number: ($number|tonumber), host: $host}'
}

# ---------------------------------------------------------------------------
# Read the loop-status file, or echo `{}` if missing.
# ---------------------------------------------------------------------------
_read_status() {
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    echo '{}'
  fi
}

# ---------------------------------------------------------------------------
# Atomic write to STATUS_FILE. Stamps updated_at automatically.
# Args: JSON object string
# ---------------------------------------------------------------------------
_write_status() {
  local payload="$1"
  local now
  now="$(_now)"
  local stamped
  stamped="$(jq --arg ts "$now" '. + {updated_at: $ts}' <<<"$payload")"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$stamped" >"$tmp"
  mv "$tmp" "$STATUS_FILE"
}

# ---------------------------------------------------------------------------
# Patch a single jq path in the status file. Args: <path> <value-json>
# Initialises the file with an empty object if missing.
# ---------------------------------------------------------------------------
_patch_status() {
  local path="$1"
  local value="$2"
  local current
  current="$(_read_status)"
  local merged
  merged="$(jq "$path = $value" <<<"$current")"
  _write_status "$merged"
}

# ---------------------------------------------------------------------------
# check-halt — exit 0 if HALT_FILE absent, exit 1 if present.
# ---------------------------------------------------------------------------
cmd_check_halt() {
  if [[ -e "$HALT_FILE" ]]; then
    echo "loop: HALT file present at $HALT_FILE — exiting cleanly" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# poll [STATUS_NAME] — emit board items at the requested Status.
#
# Output shape (JSON array, one entry per matching open Issue):
#   [{"issue": 33, "repository": "macatocz/makato",
#     "title": "...", "url": "...",
#     "status": "Ready", "labels": ["enhancement", ...]}]
#
# Closed issues, PRs, and DraftIssue items are filtered out.
# ---------------------------------------------------------------------------
cmd_poll() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local raw
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_GH_OVERRIDE")"
  else
    local cfg
    cfg="$(_read_project_config)" || return 65
    local owner number host
    owner="$(jq -r '.owner' <<<"$cfg")"
    number="$(jq -r '.number' <<<"$cfg")"
    host="$(jq -r '.host' <<<"$cfg")"
    # `gh project item-list` has no host flag — the `gh` CLI resolves the
    # host via `GH_HOST` (auth context) and `--owner`. A bare
    # `gh --hostname …` at this subcommand position fails with
    # `unknown flag: --hostname` and previously left the queue silently
    # empty (issue #156). Route host through the env var instead, and let
    # gh's stderr surface real failures so callers see them (the outer
    # `run` loop retries next tick regardless — the loss was diagnostics).
    # `--limit 9999` mirrors plugins/makato-plan/.../board-audit.md — same
    # ceiling, same WARN-on-truncation contract.
    raw="$(GH_HOST="$host" gh project item-list "$number" \
      --owner "$owner" --format json --limit 9999 || echo '{"items":[]}')"
  fi
  jq --arg status "$status_name" \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status == $status)
      | {
          issue: .content.number,
          repository: .content.repository,
          title: .content.title,
          url: .content.url,
          status: .status,
          labels: (.labels // [])
        }]' <<<"$raw"
}

# ---------------------------------------------------------------------------
# in_flight_issues — emit a set (one issue_number per line) of issues
# whose `workflow-state.json` exists and is NOT in `current_phase: "done"`.
# These must NOT be re-dispatched.
# ---------------------------------------------------------------------------
in_flight_issues() {
  [[ -d "$SPECS_DIR" ]] || return 0
  # One jq invocation per file but only one (not two): extract both fields
  # in a single pass and filter in jq rather than running two greps' worth
  # of forks per file. Per-file error handling preserved — malformed JSON
  # in one workflow-state.json must not crash the whole poll.
  find "$SPECS_DIR" -maxdepth 2 -name 'workflow-state.json' -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      jq -r 'select(.current_phase != "done") | (.issue_number // empty)' \
        "$f" 2>/dev/null || true
    done | sort -u
}

# ---------------------------------------------------------------------------
# next [STATUS_NAME] — first untracked open issue at the requested Status,
# or empty.
# ---------------------------------------------------------------------------
cmd_next() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local queue
  queue="$(cmd_poll "$status_name")"
  local in_flight
  in_flight="$(in_flight_issues)"
  jq -r --argjson in_flight \
    "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
    '.[] | .issue as $n
      | select(($in_flight | index($n|tostring) | not)) | $n' \
    <<<"$queue" | head -1
}

# ---------------------------------------------------------------------------
# status — pretty-print the status file.
# ---------------------------------------------------------------------------
cmd_status() {
  _read_status | jq .
}

# ---------------------------------------------------------------------------
# dispatch <ISSUE_NUMBER> [--dry-run]
# ---------------------------------------------------------------------------
cmd_dispatch() {
  local issue="${1:?issue number required}"
  local dry_run="${2:-}"

  # Refuse to dispatch when a workflow is already active in this loop session.
  local active
  active="$(_read_status | jq -r '.active_workflow.issue // empty')"
  if [[ -n "$active" && "$active" != "$issue" ]]; then
    echo "loop: refuse to dispatch #$issue — active_workflow=#$active (single-threaded)" >&2
    return 2
  fi

  local now
  now="$(_now)"
  local active_obj
  active_obj="$(jq -n --argjson issue "$issue" --arg ts "$now" \
    '{issue: $issue, started_at: $ts}')"
  _patch_status '.active_workflow' "$active_obj"

  if [[ "$dry_run" == "--dry-run" ]]; then
    echo "loop: --dry-run — would exec: $CLAUDE_BIN --dangerously-skip-permissions -p \"<dispatch makato-orchestrate:po-agent for issue #${issue}>\"" >&2
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Test hook — exercise the full state-machine without forking a subprocess.
  if [[ "${MAKATO_LOOP_DRY_DISPATCH:-0}" == "1" ]]; then
    _patch_status '.last_dispatch_issue' "$issue"
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  local rc=0
  # Single-threaded by construction: this call blocks until the PO-agent
  # subprocess exits. The next outer iteration polls fresh.
  #
  # The prompt explicitly delegates to the `makato-orchestrate:po-agent`
  # subagent via the Task tool. The po-agent owns the outer-loop contract
  # and threads `--autonomous` into every downstream `makato-build` skill
  # dispatch (see po-agent.md § "Autonomous Execution" and
  # plugins/makato-build/AUTONOMOUS-MODE.md). Without this delegation, the
  # top-level Claude session picks whichever skill it thinks matches
  # "drive the issue" and invokes it in default interactive mode — which
  # in a headless `claude -p` subprocess deadlocks on the first
  # AskUserQuestion prompt (see #160).
  #
  # `MAKATO_HEADLESS=1` is exported as a defensive belt: if the top-level
  # session or any downstream skill ignores the delegation prompt above
  # and falls back to interactive mode, the makato-build Step 1b guard
  # (see plugins/makato-build/AUTONOMOUS-MODE.md § "Defensive-headless
  # guard") HALTs with MISSING_INPUT instead of hanging on
  # AskUserQuestion. This is the #163 fix; the #160 fix (delegation
  # prompt) remains the primary defence.
  local dispatch_prompt
  dispatch_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to drive GitHub issue #${issue} to a merged PR. Pass the issue number as the sole argument. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
  MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions -p "$dispatch_prompt" || rc=$?
  _patch_status '.active_workflow' 'null'
  return $rc
}

# ---------------------------------------------------------------------------
# run — long-running poll loop. CLI flags override env defaults.
# ---------------------------------------------------------------------------
cmd_run() {
  local status_name="$DEFAULT_STATUS"
  local interval="$DEFAULT_INTERVAL"
  local dry_run=""
  local once=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)   status_name="${2:?--status requires a value}"; shift 2 ;;
      --interval) interval="${2:?--interval requires a value}"; shift 2 ;;
      --dry-run)  dry_run="--dry-run"; shift ;;
      --once)     once="1"; shift ;;
      *) echo "loop: unknown flag: $1" >&2; return 64 ;;
    esac
  done

  # Seed/refresh status with the run-level metadata before any poll. This
  # makes `loop status` informative even if the first poll is mid-flight.
  _patch_status '.status_name' "\"$status_name\""
  _patch_status '.interval_seconds' "$interval"
  _patch_status '.dry_run' "$( [[ -n "$dry_run" ]] && echo true || echo false )"

  while true; do
    if ! cmd_check_halt; then
      _patch_status '.last_halt_at' "\"$(_now)\""
      return 0
    fi

    local queue queue_depth
    queue="$(cmd_poll "$status_name" || echo '[]')"
    queue_depth="$(jq 'length' <<<"$queue")"
    # Batch the three poll-result fields into a single status write — saves
    # three `_patch_status` invocations (each reads + jq-merges + mktemp + mv).
    local now
    now="$(_now)"
    _write_status "$(jq \
      --arg ts "$now" \
      --argjson depth "$queue_depth" \
      --argjson q "$(jq '[.[].issue]' <<<"$queue")" \
      '. + {last_poll: $ts, queue_depth: $depth, queue: $q}' \
      <<<"$(_read_status)")"

    local in_flight
    in_flight="$(in_flight_issues)"
    local next_issue
    next_issue="$(jq -r --argjson in_flight \
      "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
      '.[] | .issue as $n
        | select(($in_flight | index($n|tostring) | not)) | $n' \
      <<<"$queue" | head -1)"

    if [[ -n "$next_issue" ]]; then
      echo "loop: dispatching issue #$next_issue (status=$status_name, queue_depth=$queue_depth)" >&2
      # `cmd_dispatch` already clears active_workflow on return; we ignore
      # the PO-agent's exit code — it writes its own HALT audit to
      # workflow-state.json; the loop's job is to surface the next issue,
      # not to second-guess the orchestrator's terminal state.
      cmd_dispatch "$next_issue" "$dry_run" || true
    else
      echo "loop: queue empty or fully in-flight (depth=$queue_depth) — idle" >&2
    fi

    if [[ -n "$once" ]]; then
      return 0
    fi

    sleep "$interval"
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUBCMD="${1:?subcommand required: run|poll|next|status|dispatch|check-halt}"
shift || true

case "$SUBCMD" in
  run)        cmd_run "$@" ;;
  poll)       cmd_poll "$@" ;;
  next)       cmd_next "$@" ;;
  status)     cmd_status ;;
  dispatch)   cmd_dispatch "$@" ;;
  check-halt) cmd_check_halt ;;
  *) echo "loop: unknown subcommand: $SUBCMD" >&2; exit 64 ;;
esac
