#!/usr/bin/env bash
# Append a JSONL entry to the spec folder's build.jsonl.
# Resolves the spec folder by prefix-matching specs/<key>-*/ (daff-shape naming convention).
# Usage: build-log.sh <key> '<json-object>'
set -euo pipefail

KEY="${1:?key required}"
ENTRY="${2:?json entry required}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPECS_DIR="$REPO_ROOT/specs"

# Resolve spec folder: find the first directory matching specs/<key>-*/
SPEC_FOLDER=""
if [[ -d "$SPECS_DIR" ]]; then
  SPEC_FOLDER="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${KEY}-*" | head -1)"
fi

# Fall back to local-work path (no slug suffix)
if [[ -z "$SPEC_FOLDER" ]] && [[ -d "$SPECS_DIR/$KEY" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

# If still not found, create a placeholder directory so logging never fails
if [[ -z "$SPEC_FOLDER" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

LOG_FILE="$SPEC_FOLDER/build.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"
printf '%s\n' "$ENTRY" >> "$LOG_FILE"
