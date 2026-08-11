#!/usr/bin/env bash
# loop-halt-watch.sh — notify on macOS when the makato loop HALTs, crashes, or
# the liveness watchdog kills a stuck po-agent.
#
# Runs INDEPENDENTLY of loop.sh (so it survives a loop crash). Polls three
# signals every MAKATO_WATCH_INTERVAL seconds against a single repo's state dir:
#   1. HALT-000       — ~/.claude/HALT appears, OR last_halt_at advances.
#   2. process death  — loop.pid names a PID that stops responding to kill -0
#                       while there is still queued work (queue_depth > 0).
#   3. watchdog kill  — last_watchdog_kill in loop-status.json changes.
#
# Each transition fires exactly once (state is latched), then the watcher keeps
# running so a later, distinct event still notifies.
#
# Usage:  loop-halt-watch.sh [REPO_ROOT]
#   REPO_ROOT defaults to $MAKATO_WATCH_REPO or the cwd.
# Env:
#   MAKATO_WATCH_INTERVAL   poll cadence seconds (default 30)
#   MAKATO_HALT_FILE        HALT file path (default ~/.claude/HALT)
#   MAKATO_WATCH_ONCE=1     run a single poll and exit (for testing)
#   MAKATO_WATCH_NOTIFY_CMD when set, append notifications to this file instead
#                           of firing a real macOS notification (test stub)

set -uo pipefail

REPO_ROOT="${1:-${MAKATO_WATCH_REPO:-$PWD}}"
STATE_DIR="$REPO_ROOT/.claude/state"
STATUS_JSON="$STATE_DIR/loop-status.json"
PIDFILE="${MAKATO_LOOP_PIDFILE:-$STATE_DIR/loop.pid}"
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
INTERVAL="${MAKATO_WATCH_INTERVAL:-30}"

notify() {
  local title="$1" msg="$2"
  # Test hook: when set, append the notification to this file instead of
  # firing a real macOS notification (used by loop-halt-watch-smoke-tests.sh).
  if [ -n "${MAKATO_WATCH_NOTIFY_CMD:-}" ]; then
    printf '%s\t%s\n' "$title" "$msg" >> "$MAKATO_WATCH_NOTIFY_CMD"
  elif command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -subtitle "makato loop" -message "$msg" \
      -sound Basso -group "makato-loop-halt" >/dev/null 2>&1
  elif [[ "$(uname)" == "Darwin" ]]; then
    /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"Basso\"" >/dev/null 2>&1
  fi
  printf '%s [loop-halt-watch] %s — %s\n' "$(date '+%H:%M:%S')" "$title" "$msg"
}

json_get() { # file, jq-filter -> value or empty
  [ -f "$1" ] || { echo ""; return; }
  jq -r "$2 // empty" "$1" 2>/dev/null
}

# ---- baseline (avoid firing on pre-existing state) ----------------------------
prev_halt_at="$(json_get "$STATUS_JSON" '.last_halt_at')"
prev_wd_kill="$(json_get "$STATUS_JSON" '.last_watchdog_kill | tojson')"
halt_file_seen=0; [ -e "$HALT_FILE" ] && halt_file_seen=1
proc_dead_fired=0

echo "[loop-halt-watch] watching $REPO_ROOT (interval ${INTERVAL}s, pidfile $PIDFILE)"

poll_once() {
  # 1. HALT-000: file appears
  if [ -e "$HALT_FILE" ] && [ "$halt_file_seen" -eq 0 ]; then
    halt_file_seen=1
    notify "⛔ Loop HALT" "HALT soubor se objevil: $HALT_FILE — loop se zastaví."
  elif [ ! -e "$HALT_FILE" ] && [ "$halt_file_seen" -eq 1 ]; then
    halt_file_seen=0  # re-arm if the file is removed
  fi

  # 1b. HALT-000: last_halt_at advanced (clean HALT exit)
  local cur_halt_at; cur_halt_at="$(json_get "$STATUS_JSON" '.last_halt_at')"
  if [ -n "$cur_halt_at" ] && [ "$cur_halt_at" != "$prev_halt_at" ]; then
    prev_halt_at="$cur_halt_at"
    notify "⛔ Loop HALT" "Loop čistě skončil na HALT ($cur_halt_at)."
  fi

  # 2. process death while work is queued
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$pid" ]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      if [ "$proc_dead_fired" -eq 0 ]; then
        proc_dead_fired=1
        local qd; qd="$(json_get "$STATUS_JSON" '.queue_depth')"
        notify "💥 Loop spadl" "Proces PID $pid neběží (fronta: ${qd:-?}). Restartuj loop.sh run."
      fi
    else
      proc_dead_fired=0  # re-arm once a live PID is seen again
    fi
  fi

  # 3. watchdog kill changed
  local cur_wd_kill; cur_wd_kill="$(json_get "$STATUS_JSON" '.last_watchdog_kill | tojson')"
  if [ -n "$cur_wd_kill" ] && [ "$cur_wd_kill" != "null" ] && [ "$cur_wd_kill" != "$prev_wd_kill" ]; then
    prev_wd_kill="$cur_wd_kill"
    local iss; iss="$(json_get "$STATUS_JSON" '.last_watchdog_kill.issue')"
    local idle; idle="$(json_get "$STATUS_JSON" '.last_watchdog_kill.idle_seconds')"
    notify "🐕 Watchdog kill" "po-agent pro #${iss:-?} zabit po ${idle:-?}s ticha."
  fi
}

poll_once
if [ "${MAKATO_WATCH_ONCE:-0}" = "1" ]; then exit 0; fi
while true; do
  sleep "$INTERVAL"
  poll_once
done
