#!/usr/bin/env bash
# log-bypass.sh — append a canonical `autonomous_bypass` JSONL entry to build.jsonl.
#
# Usage:
#   log-bypass.sh <skill> <key> <gate> <default_taken> <trigger> [extra-json-object]
#
# Required arguments:
#   skill          — name of the calling skill (e.g. "build-simplify")
#   key            — work-item key (e.g. "DCP-1234", "#123")
#   gate           — short identifier for the bypassed gate (e.g. "per-finding-approval")
#   default_taken  — short identifier for the default action taken (e.g. "auto-approve-simplify")
#   trigger        — one of: agent_id, cli_flag, task_id_bundle
#
# Optional 6th argument:
#   extra-json-object — a JSON object that is merged into `data` alongside the
#                       canonical 5 fields. Use this for skill-specific context
#                       (counts, comment_id, follow_up_issue, etc.) without
#                       drifting the canonical schema. Example:
#                         '{"comment_id":"42","follow_up_issue":"https://..."}'
#
# Canonical emitted shape (matches AUTONOMOUS-MODE.md § *Logging contract*):
#   {
#     "ts": "<ISO-8601-ms>",
#     "skill": "<skill>",
#     "story": "<key>",
#     "step": "decision",
#     "status": "decision",
#     "data": {
#       "event": "autonomous_bypass",
#       "gate": "<gate>",
#       "bypassed": true,
#       "default_taken": "<default_taken>",
#       "trigger": "<trigger>"
#       <merged extra fields, if extra-json-object was passed>
#     }
#   }
#
# HALT semantics: missing any of the 5 required positional args is a fatal
# error — the script exits 2 with a usage message rather than emitting a
# malformed row. A non-JSON `extra` argument is a fatal error (exit 3).
#
# Delegates the actual file append to `build-log.sh` so REPO_ROOT / worktree
# resolution stays in one place.

set -euo pipefail

# Resolve the canonical ISO-8601 timestamp with millisecond precision. macOS
# `date` lacks %N; the python fallback covers both Linux and macOS without a
# new tool dependency (python3 is required by other makato-build scripts).
_ts() {
  python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.datetime.now(datetime.timezone.utc).microsecond // 1000:03d}Z")'
}

_usage() {
  cat >&2 <<'EOF'
Usage: log-bypass.sh <skill> <key> <gate> <default_taken> <trigger> [extra-json-object]

Required:
  skill          name of the calling skill (e.g. "build-simplify")
  key            work-item key (e.g. "DCP-1234", "#123")
  gate           short identifier for the bypassed gate
  default_taken  short identifier for the default action taken
  trigger        one of: agent_id, cli_flag, task_id_bundle

Optional 6th argument:
  extra-json-object  a JSON object merged into `data` alongside the canonical fields.

Example:
  log-bypass.sh build-simplify "$KEY" per-finding-approval auto-approve-simplify cli_flag
  log-bypass.sh build-address-pr-comments "$KEY" out-of-scope-carry-over open-followup-issue cli_flag \
    '{"comment_id":"42","follow_up_issue":"https://github.com/o/r/issues/99"}'
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  _usage
  exit 0
fi

if [[ $# -lt 5 ]]; then
  echo "log-bypass.sh: missing required arguments ($# given, 5 required)" >&2
  _usage
  exit 2
fi

SKILL="$1"
KEY="$2"
GATE="$3"
DEFAULT_TAKEN="$4"
TRIGGER="$5"
EXTRA="${6:-}"

# Validate trigger against the canonical 3-value enum. We accept anything that
# matches the documented set; callers may use a bare token (cli_flag) or the
# alternation-style placeholder (agent_id|cli_flag|task_id_bundle) the prose
# documents — both are surfaced verbatim so audit consumers can grep either.
case "$TRIGGER" in
  agent_id|cli_flag|task_id_bundle|"agent_id|cli_flag|task_id_bundle"|"<agent_id|cli_flag|task_id_bundle>") ;;
  *)
    echo "log-bypass.sh: invalid trigger '$TRIGGER' (expected: agent_id|cli_flag|task_id_bundle)" >&2
    exit 2
    ;;
esac

# Assemble the data object via jq so quoting stays correct even if any field
# contains spaces, slashes, or shell metacharacters. The optional `extra`
# argument is merged with `*` (recursive object union — later wins), so a
# caller that passes `{"bypassed": false}` would be silently overruled by the
# canonical `bypassed: true`. That's intentional: callers extend the schema,
# they do not override the canonical fields.
if [[ -n "$EXTRA" ]]; then
  # Reject non-object or non-JSON extra payloads early.
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$EXTRA"; then
    echo "log-bypass.sh: extra argument must be a JSON object, got: $EXTRA" >&2
    exit 3
  fi
  DATA="$(jq -c -n \
    --arg gate "$GATE" \
    --arg default_taken "$DEFAULT_TAKEN" \
    --arg trigger "$TRIGGER" \
    --argjson extra "$EXTRA" \
    '$extra + {event: "autonomous_bypass", gate: $gate, bypassed: true, default_taken: $default_taken, trigger: $trigger}')"
else
  DATA="$(jq -c -n \
    --arg gate "$GATE" \
    --arg default_taken "$DEFAULT_TAKEN" \
    --arg trigger "$TRIGGER" \
    '{event: "autonomous_bypass", gate: $gate, bypassed: true, default_taken: $default_taken, trigger: $trigger}')"
fi

ENTRY="$(jq -c -n \
  --arg ts "$(_ts)" \
  --arg skill "$SKILL" \
  --arg story "$KEY" \
  --argjson data "$DATA" \
  '{ts: $ts, skill: $skill, story: $story, step: "decision", status: "decision", data: $data}')"

# Delegate the actual file append. The helper lives next to this script.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/build-log.sh" "$KEY" "$ENTRY"
