#!/usr/bin/env bash
# migrate-blocked-by-labels.sh — convert holé "blocked by"/"blocking" labels to
# value-bearing "blocked-by:N"/"blocking:N" labels across all issues.
#
# Usage: ./scripts/migrate-blocked-by-labels.sh [--dry-run] [--repo owner/name]
#
# The script is idempotent: label-add and label-remove are no-ops if already
# in the target state. Re-running is safe.
#
# Exit summary: prints "Migrated N issues" on completion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/migrate-blocked-by-labels.sh [OPTIONS]

Convert holé "blocked by" / "blocking" dependency labels to value-bearing
"blocked-by:N" / "blocking:N" labels on all issues.

Options:
  --dry-run         Print planned changes without executing any mutations
  --repo owner/name Target repo (default: derived from git remote)
  -h, --help        Show this help

The script is idempotent — re-running is safe. Each issue's body and
specs/*/created-issues.json are consulted to resolve blocker numbers.
EOF
}

DRY_RUN=0
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --repo)    REPO="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
    || { echo "[migrate] ERROR: could not derive repo from git remote. Pass --repo." >&2; exit 1; }
fi

echo "[migrate] target repo: $REPO (dry_run=$DRY_RUN)"

# ---------------------------------------------------------------------------
# Helper: resolve blocker numbers from issue body and created-issues.json
# Returns one integer per line (may be empty).
# ---------------------------------------------------------------------------
_resolve_blockers_for_issue() {
  local issue_num="$1"
  local issue_body="$2"

  # Source 1: parse issue body for "Blocked by: #N" or "Blocked by: #N, #M"
  echo "$issue_body" \
    | grep -oiE 'blocked[- ]by:?\s*#?[0-9]+(,\s*#?[0-9]+)*' \
    | grep -oE '[0-9]+' \
    || true

  # Source 2: specs/*/created-issues.json blocked_by arrays
  find "$REPO_ROOT/specs" -name 'created-issues.json' -exec \
    python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for issue in data.get('issues', []):
        if str(issue.get('issue_number','')) == sys.argv[2]:
            for b in issue.get('blocked_by', []):
                print(b)
except Exception:
    pass
" {} "$issue_num" \; 2>/dev/null \
    || true
}

# ---------------------------------------------------------------------------
# Phase 1: migrate "blocked by" → "blocked-by:N"
# ---------------------------------------------------------------------------
echo "[migrate] Phase 1: scanning for issues with holé 'blocked by' label…"

MIGRATE_BLOCKED_COUNT=0

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  issue_num="$(echo "$row" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['number'])")"
  issue_body="$(echo "$row" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['body'])")"

  echo "[migrate] issue #${issue_num}: resolving blockers…"

  # Collect blocker numbers (deduplicated)
  mapfile -t BLOCKER_NUMS < <(
    _resolve_blockers_for_issue "$issue_num" "$issue_body" | sort -u
  )

  if [[ "${#BLOCKER_NUMS[@]}" -eq 0 ]]; then
    echo "[migrate] issue #${issue_num}: no blocker numbers resolved — removing holé label without adding blocked-by:N"
  fi

  for BLOCKER_NUM in "${BLOCKER_NUMS[@]}"; do
    [[ -z "$BLOCKER_NUM" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[migrate:dry-run] would add blocked-by:${BLOCKER_NUM} to #${issue_num}"
    else
      gh label create "blocked-by:${BLOCKER_NUM}" \
        --repo "$REPO" --color "B60205" \
        --description "Blocked by issue #${BLOCKER_NUM}" 2>/dev/null || true
      gh issue edit "$issue_num" \
        --repo "$REPO" --add-label "blocked-by:${BLOCKER_NUM}" 2>/dev/null || true
      echo "[migrate] added blocked-by:${BLOCKER_NUM} to #${issue_num}"
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[migrate:dry-run] would remove holé 'blocked by' from #${issue_num}"
  else
    gh issue edit "$issue_num" \
      --repo "$REPO" --remove-label "blocked by" 2>/dev/null || true
    echo "[migrate] removed holé 'blocked by' from #${issue_num}"
  fi

  MIGRATE_BLOCKED_COUNT=$((MIGRATE_BLOCKED_COUNT + 1))
done < <(
  gh issue list \
    --repo "$REPO" \
    --label "blocked by" \
    --state all \
    --limit 500 \
    --json number,body \
    --jq '.[]' 2>/dev/null || true
)

echo "[migrate] Phase 1 complete: processed ${MIGRATE_BLOCKED_COUNT} 'blocked by' issues"

# ---------------------------------------------------------------------------
# Phase 2: migrate "blocking" → "blocking:N"
# ---------------------------------------------------------------------------
echo "[migrate] Phase 2: scanning for issues with holé 'blocking' label…"

MIGRATE_BLOCKING_COUNT=0

while IFS= read -r upstream_num; do
  [[ -z "$upstream_num" ]] && continue

  echo "[migrate] upstream issue #${upstream_num}: resolving dependents from created-issues.json…"

  # Find dependents: issues that list upstream_num in their blocked_by array
  mapfile -t DEP_NUMS < <(
    find "$REPO_ROOT/specs" -name 'created-issues.json' -exec \
      python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for issue in data.get('issues', []):
        if int(sys.argv[2]) in [int(b) for b in issue.get('blocked_by', [])]:
            print(issue.get('issue_number',''))
except Exception:
    pass
" {} "$upstream_num" \; 2>/dev/null | sort -u || true
  )

  for DEP_NUM in "${DEP_NUMS[@]}"; do
    [[ -z "$DEP_NUM" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[migrate:dry-run] would add blocking:${DEP_NUM} to #${upstream_num}"
    else
      gh label create "blocking:${DEP_NUM}" \
        --repo "$REPO" --color "D93F0B" \
        --description "Blocks issue #${DEP_NUM}" 2>/dev/null || true
      gh issue edit "$upstream_num" \
        --repo "$REPO" --add-label "blocking:${DEP_NUM}" 2>/dev/null || true
      echo "[migrate] added blocking:${DEP_NUM} to #${upstream_num}"
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[migrate:dry-run] would remove holé 'blocking' from #${upstream_num}"
  else
    gh issue edit "$upstream_num" \
      --repo "$REPO" --remove-label "blocking" 2>/dev/null || true
    echo "[migrate] removed holé 'blocking' from #${upstream_num}"
  fi

  MIGRATE_BLOCKING_COUNT=$((MIGRATE_BLOCKING_COUNT + 1))
done < <(
  gh issue list \
    --repo "$REPO" \
    --label "blocking" \
    --state all \
    --limit 500 \
    --json number \
    --jq '.[].number' 2>/dev/null || true
)

echo "[migrate] Phase 2 complete: processed ${MIGRATE_BLOCKING_COUNT} 'blocking' issues"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((MIGRATE_BLOCKED_COUNT + MIGRATE_BLOCKING_COUNT))
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[migrate] DRY RUN complete — no mutations applied. $TOTAL issue(s) would be migrated."
else
  echo "[migrate] Migration complete. Migrated $TOTAL issue(s) (blocked by: $MIGRATE_BLOCKED_COUNT → blocked-by:N, blocking: $MIGRATE_BLOCKING_COUNT → blocking:N)."
fi
