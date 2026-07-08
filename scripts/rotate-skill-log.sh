#!/usr/bin/env bash
# rotate-skill-log.sh — NFR-O1 weekly log rotation for .claude/skill-invocations.log
# Rotate if file >= 100 MB or oldest entry ts field is > 7 days ago.
# Retention: delete rotated files older than 90 days.
# POSIX-compatible: uses awk, date, mv, find only.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOG_FILE="${REPO_ROOT}/.claude/skill-invocations.log"

# Exit silently if log does not exist
if [ ! -f "$LOG_FILE" ]; then
    exit 0
fi

ROTATE=0

# Check size: rotate if >= 100 MB (find -size +100M matches files strictly > 100 MB;
# use +99M to catch files at exactly 100 MB and above)
if find "$LOG_FILE" -size +99M | grep -q .; then
    ROTATE=1
fi

# Check oldest entry age if not already rotating
if [ "$ROTATE" -eq 0 ]; then
    # Extract the first ts field value from the log (JSONL format: {"ts":"<ISO8601>", ...})
    OLDEST_TS="$(awk 'NR==1 { match($0, /"ts"[[:space:]]*:[[:space:]]*"([^"]+)"/, a); if (a[1] != "") print a[1] }' "$LOG_FILE" 2>/dev/null || true)"

    if [ -n "$OLDEST_TS" ]; then
        # Convert ISO 8601 ts to seconds-since-epoch using date.
        # macOS date: date -j -f "%Y-%m-%dT%H:%M:%S" "<ts>" +%s (strips trailing Z / timezone for simplicity)
        # GNU date:   date -d "<ts>" +%s
        # We strip fractional seconds and Z suffix to get a basic ISO 8601 datetime.
        OLDEST_TS_CLEAN="$(echo "$OLDEST_TS" | sed 's/\.[0-9]*Z$//' | sed 's/Z$//' | sed 's/+[0-9:]*$//')"

        # Try GNU date first, fall back to macOS date
        OLDEST_EPOCH=""
        if date -d "$OLDEST_TS_CLEAN" +%s >/dev/null 2>&1; then
            OLDEST_EPOCH="$(date -d "$OLDEST_TS_CLEAN" +%s)"
        elif date -j -f "%Y-%m-%dT%H:%M:%S" "$OLDEST_TS_CLEAN" +%s >/dev/null 2>&1; then
            OLDEST_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%S" "$OLDEST_TS_CLEAN" +%s)"
        fi

        if [ -n "$OLDEST_EPOCH" ]; then
            NOW_EPOCH="$(date +%s)"
            AGE_DAYS=$(( (NOW_EPOCH - OLDEST_EPOCH) / 86400 ))
            if [ "$AGE_DAYS" -gt 7 ]; then
                ROTATE=1
            fi
        fi
    fi
fi

# Perform rotation
if [ "$ROTATE" -eq 1 ]; then
    DATESTAMP="$(date +%Y-%m-%d)"
    ROTATED="${LOG_FILE}.${DATESTAMP}"

    # If a rotated file with today's date already exists, append a counter
    if [ -f "$ROTATED" ]; then
        COUNTER=1
        while [ -f "${ROTATED}.${COUNTER}" ]; do
            COUNTER=$(( COUNTER + 1 ))
        done
        ROTATED="${ROTATED}.${COUNTER}"
    fi

    mv "$LOG_FILE" "$ROTATED"
fi

# Retention: delete rotated files older than 90 days (idempotent)
LOG_DIR="$(dirname "$LOG_FILE")"
find "$LOG_DIR" -maxdepth 1 -name "skill-invocations.log.*" -mtime +90 -delete

exit 0
