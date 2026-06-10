#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADR_DIR="$REPO_ROOT/docs/governance/adr"

ERRORS=0

if [ ! -d "$ADR_DIR" ]; then
  echo "ERROR: ADR directory not found: docs/governance/adr/"
  exit 1
fi

adr_count=0
expected_num=1

for adr_file in "$ADR_DIR"/*.md; do
  if [ ! -f "$adr_file" ]; then
    continue
  fi

  filename="$(basename "$adr_file")"
  adr_count=$((adr_count + 1))

  if ! echo "$filename" | grep -qE '^[0-9]{4}-[a-z][a-z0-9-]+\.md$'; then
    echo "ERROR: ADR filename doesn't match pattern '0000-kebab-case.md': $filename"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  file_num=$(echo "$filename" | grep -oE '^[0-9]+' | sed 's/^0*//')
  if [ "$file_num" != "$expected_num" ]; then
    echo "ERROR: ADR numbering gap — expected $(printf '%04d' $expected_num), got $(printf '%04d' $file_num)"
    ERRORS=$((ERRORS + 1))
  fi
  expected_num=$((expected_num + 1))

  REQUIRED_SECTIONS=("## Status" "## Date" "## Context" "## Decision" "## Consequences")
  for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "^${section}" "$adr_file"; then
      echo "ERROR: [$filename] Missing section: $section"
      ERRORS=$((ERRORS + 1))
    fi
  done
done

if [ $adr_count -eq 0 ]; then
  echo "WARNING: No ADR files found"
fi

if [ $ERRORS -eq 0 ]; then
  echo "ADRs: OK ($adr_count files)"
  exit 0
else
  echo "ADRs: $ERRORS error(s)"
  exit 1
fi
