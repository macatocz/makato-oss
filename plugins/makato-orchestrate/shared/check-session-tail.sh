#!/usr/bin/env bash
# check-session-tail.sh — PO-agent post-dispatch audit-tail guard (#175).
#
# Purpose:
#   Cross-check the tail of specs/<key>-*/build.jsonl to determine whether
#   the just-dispatched build-* sub-skill closed its session properly. The
#   PO-agent uses the return value to decide whether to route on halt_code,
#   escalate a silent exit, or proceed unchanged on the happy path.
#
# Background: closes the outer-loop half of the audit-contract gap #169 fixed
# on the sub-skill side (PR #174). Before this helper, a build-* skill that
# torn its R1 envelope after emitting `step:"session" status:"error"` in
# build.jsonl still left the PO-agent flying blind — the R1 parser produced
# `failure` with no halt_code, and the sub-skill's explicit signal in
# build.jsonl was ignored.
#
# Usage:
#   check-session-tail.sh <key> <skill-name> [--tail-limit N]
#
# Arguments:
#   <key>          Work-item key used to resolve specs/<key>-*/build.jsonl.
#                  Same resolution rules as shared/workflow-state.sh and
#                  makato-build/shared/build-log.sh: prefix-match on
#                  specs/<key>-*/, fall back to specs/<key>/.
#   <skill-name>   Name of the build-* skill whose session line we're auditing
#                  (e.g. "build-create-pr", "build-verify"). Matches
#                  entry.skill in build.jsonl.
#   --tail-limit N Optional. How many trailing lines of build.jsonl to
#                  consider. Default 20 (cheap; the last session block for
#                  any single skill invocation fits well under this).
#
# Output (stdout, single JSON object):
#   {
#     "verdict":     "ok"|"error"|"silent"|"no-log",
#     "halt_code":   "<CODE>"|null,   // populated only when verdict=="error"
#     "last_step":   "<step-name>",   // last event.step observed for the skill
#     "last_status": "<status>",      // its status
#     "session_start_present": bool   // did we see step:"session",status:"start"?
#   }
#
# Verdict semantics:
#   - "ok"     — Last event for <skill-name> is step:"session" status:"ok".
#                PO-agent proceeds unchanged (AC3).
#   - "error"  — Last event for <skill-name> is step:"session" status:"error".
#                halt_code is populated from event.data.halt_code (may still
#                be null if the sub-skill misbehaved). PO-agent routes per
#                halt-codes.md (AC1).
#   - "silent" — Session-start seen but no terminal session line.
#                Sub-skill exited between start and terminal — the exact
#                silent-exit class #169 fixes. PO-agent records HALT-011
#                and applies `needs-human-review` (AC2).
#   - "no-log" — No build.jsonl at all, or no entries for this skill.
#                Caller decides how to treat: the po-agent trusts R1 in this
#                case (helper is additive, never a HALT source on empty log).
#
# Exit codes: 0 in all normal outcomes (verdict conveys the result via JSON).
# Non-zero only on argument errors or an unreadable filesystem state.
#
# Test hook: MAKATO_BUILD_JSONL_OVERRIDE forces a specific file path. Used by
# the smoke test to point at fixtures without materialising a specs/ tree.

set -euo pipefail

KEY="${1:?key required (e.g. gap-007-loop)}"
SKILL="${2:?skill name required (e.g. build-create-pr)}"
shift 2

TAIL_LIMIT=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail-limit)
      TAIL_LIMIT="${2:?--tail-limit needs an integer}"
      shift 2
      ;;
    *)
      echo "check-session-tail: unknown flag '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$TAIL_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "check-session-tail: --tail-limit must be a positive integer (got '$TAIL_LIMIT')" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve build.jsonl. Mirror the resolution used by build-log.sh so this
# helper never disagrees with the writer about which file to inspect.
# ---------------------------------------------------------------------------
if [[ -n "${MAKATO_BUILD_JSONL_OVERRIDE:-}" ]]; then
  LOG_FILE="$MAKATO_BUILD_JSONL_OVERRIDE"
else
  GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$GIT_COMMON_DIR" ]]; then
    REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
  else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  SPECS_DIR="$REPO_ROOT/specs"

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

  LOG_FILE="$SPEC_FOLDER/build.jsonl"
fi

# ---------------------------------------------------------------------------
# Empty / missing log — nothing to audit. Emit "no-log" and exit; the PO-agent
# falls back to R1 parsing.
# ---------------------------------------------------------------------------
if [[ ! -s "$LOG_FILE" ]]; then
  cat <<EOF
{"verdict":"no-log","halt_code":null,"last_step":null,"last_status":null,"session_start_present":false}
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Filter to events for this skill in the last N lines. Read raw + fromjson?
# to skip malformed lines (a sensor-fixer variant could emit non-JSON debug
# output); `-s` after the -R/fromjson? pipeline is invalid, so we drop the
# non-objects via a second pass with `[inputs]` + select(type=="object").
# ---------------------------------------------------------------------------
tail -n "$TAIL_LIMIT" "$LOG_FILE" \
  | jq -c -R -n --arg skill "$SKILL" '
      [inputs | fromjson? | select(type == "object")] as $entries
      | ($entries | map(select(.skill == $skill))) as $for_skill
      | ($for_skill | map(select(.step == "session" and .status == "start")) | length > 0) as $start_seen
      | ($for_skill | last) as $last
      | ($for_skill
          | map(select(.step == "session" and (.status == "ok" or .status == "error")))
          | last) as $terminal
      | if $terminal == null then
          if $start_seen then
            {verdict: "silent",
             halt_code: null,
             last_step: ($last.step // null),
             last_status: ($last.status // null),
             session_start_present: true}
          else
            {verdict: "no-log",
             halt_code: null,
             last_step: ($last.step // null),
             last_status: ($last.status // null),
             session_start_present: false}
          end
        elif $terminal.status == "ok" then
          {verdict: "ok",
           halt_code: null,
           last_step: "session",
           last_status: "ok",
           session_start_present: $start_seen}
        else
          {verdict: "error",
           halt_code: ($terminal.data.halt_code // null),
           last_step: "session",
           last_status: "error",
           session_start_present: $start_seen}
        end
    '
