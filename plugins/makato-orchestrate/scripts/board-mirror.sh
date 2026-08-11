#!/usr/bin/env bash
# board-mirror.sh — offline board mirror + per-tick bidirectional sync (issue #9).
#
# Sourced by functions.sh. Lets the loop keep dispatching Ready issues across a
# GitHub partition: it reads from a local snapshot when the live board poll fails
# and queues status transitions it could not push, flushing them once the poll
# succeeds again.
#
# Q-mirror decisions (issue #9):
#   - Sync cadence: PER POLL TICK. No separate daemon — mirror_refresh + mirror_flush
#     run inside cmd_poll on each successful poll, sharing loop.sh's interval.
#   - Conflict rule: LAST-WRITER-WINS, whole-record, by timestamp. Single operator,
#     so simultaneous edits to one card are rare; the newest write wins outright.
#
# State files (under STATE_DIR, or the persistent volume when STATE_DIR points there):
#   MIRROR_FILE   {"mirrored_at": <iso>, "board": {"items":[...]}} — last-known board
#   MIRROR_QUEUE  JSONL of {"issue","status","ts"} — local writes not yet on GitHub
#
# Feature flag MAKATO_LOOP_MIRROR (default 1). 0 disables every mirror behaviour:
# refresh/flush/apply become no-ops and mirror_read fails, so cmd_poll and
# _claim_board_card behave exactly as they did before #9.
#
# Relies on _now() (functions.sh) and the STATE_DIR / CONFIG_FILE paths loop.sh sets.

_mirror_enabled() { [[ "${MAKATO_LOOP_MIRROR:-1}" == "1" ]]; }
_mirror_file()  { printf '%s\n' "${MAKATO_LOOP_MIRROR_FILE:-$STATE_DIR/board-mirror.json}"; }
_mirror_queue() { printf '%s\n' "${MAKATO_LOOP_MIRROR_QUEUE:-$STATE_DIR/board-mirror-queue.jsonl}"; }

# _mirror_status_option_id <status_name> — map a board Status name ("In progress")
# to its Projects v2 single-select option id from config. Names normalise to the
# snake-case keys config uses (in_progress, ready, done, blocked, …).
_mirror_status_option_id() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
  [[ -f "$CONFIG_FILE" ]] || return 0
  jq -r --arg k "$key" \
    '.github_project.fields.status.options[$k] // (.github_project.options[$k] // empty)' \
    "$CONFIG_FILE" 2>/dev/null
}

# mirror_refresh <raw_board_json> — persist a fresh board snapshot atomically.
# Re-applies any still-pending local writes (last-writer-wins) so an unpushed
# transition is not clobbered by the freshly-fetched board.
mirror_refresh() {
  _mirror_enabled || return 0
  local raw="$1" f q tmp board
  f="$(_mirror_file)"; q="$(_mirror_queue)"
  [[ -n "$raw" ]] || return 0
  jq -e '.items' >/dev/null 2>&1 <<<"$raw" || return 0   # never poison the mirror with garbage
  mkdir -p "$(dirname "$f")"
  board="$raw"
  if [[ -s "$q" ]]; then
    # Overlay the latest queued status per issue onto the fetched board.
    board="$(jq -c --slurpfile pend <(jq -s '.' "$q" 2>/dev/null || printf '[]') '
      .items |= map(
        .content.number as $n
        | ($pend[0] | map(select(.issue == $n)) | sort_by(.ts) | last) as $p
        | if $p then .status = $p.status else . end
      )' <<<"$raw" 2>/dev/null)" || board="$raw"
  fi
  tmp="$(mktemp)"
  if jq -n --arg ts "$(_now)" --argjson board "$board" \
      '{mirrored_at: $ts, board: $board}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# mirror_read — print the stored board ({"items":[...]}) for cmd_poll to filter.
# Non-zero when the mirror is disabled, missing, or empty.
mirror_read() {
  _mirror_enabled || return 1
  local f; f="$(_mirror_file)"
  [[ -s "$f" ]] || return 1
  jq -e '.board // empty' "$f" 2>/dev/null || return 1
}

# mirror_apply_local <issue> <status> — record a local status transition the loop
# could not push to GitHub: append it to the push queue AND reflect it in the
# snapshot so the served queue immediately sees the new status (no re-dispatch).
mirror_apply_local() {
  _mirror_enabled || return 0
  local issue="$1" status="$2" f q tmp
  f="$(_mirror_file)"; q="$(_mirror_queue)"
  mkdir -p "$(dirname "$q")"
  jq -nc --argjson i "$issue" --arg s "$status" --arg ts "$(_now)" \
    '{issue: $i, status: $s, ts: $ts}' >>"$q"
  if [[ -s "$f" ]]; then
    tmp="$(mktemp)"
    if jq --argjson i "$issue" --arg s "$status" \
        '.board.items |= map(if .content.number == $i then .status = $s else . end)' \
        "$f" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  fi
}

# mirror_flush <host> — push queued transitions to GitHub, most recent status per
# issue (last-writer-wins). Item ids come from the snapshot, so no extra lookup
# call is needed (item-edit needs only --project-id + --id). Entries that fail to
# push are kept for the next tick; pushed entries are dropped. Best-effort.
mirror_flush() {
  _mirror_enabled || return 0
  local host="$1"
  local f q; f="$(_mirror_file)"; q="$(_mirror_queue)"
  [[ -s "$q" ]] || return 0
  [[ -f "$CONFIG_FILE" ]] || return 0
  local field_id project_node_id
  field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE" 2>/dev/null)"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
  [[ -n "$field_id" && -n "$project_node_id" ]] || return 0

  local collapsed count i n st opt_id item_id remaining
  collapsed="$(jq -s -c 'group_by(.issue) | map(sort_by(.ts) | last)' "$q" 2>/dev/null || printf '[]')"
  count="$(jq 'length' <<<"$collapsed" 2>/dev/null || echo 0)"
  remaining='[]'
  i=0
  while [[ "$i" -lt "$count" ]]; do
    n="$(jq -r ".[$i].issue" <<<"$collapsed")"
    st="$(jq -r ".[$i].status" <<<"$collapsed")"
    i=$((i + 1))
    opt_id="$(_mirror_status_option_id "$st")"
    item_id="$(jq -r --argjson i "$n" \
      'first(.board.items[] | select(.content.number == $i) | .id) // empty' "$f" 2>/dev/null)"
    if [[ -n "$opt_id" && -n "$item_id" ]] && \
       GH_HOST="$host" gh project item-edit --id "$item_id" \
         --project-id "$project_node_id" --field-id "$field_id" \
         --single-select-option-id "$opt_id" >/dev/null 2>&1; then
      echo "loop: mirror-sync pushed #$n → $st (#9)" >&2
    else
      remaining="$(jq -c --argjson i "$n" --arg s "$st" --arg ts "$(_now)" \
        '. + [{issue: $i, status: $s, ts: $ts}]' <<<"$remaining")"
    fi
  done

  if [[ "$remaining" == '[]' ]]; then
    : >"$q"
  else
    jq -c '.[]' <<<"$remaining" >"$q"
  fi
}
