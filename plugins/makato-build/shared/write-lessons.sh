#!/usr/bin/env bash
# write-lessons.sh — append one raw per-issue lesson/fact record to a build (or
# change) session's per-issue store: specs/<key>-*/change-lessons.jsonl (#473).
#
# This is a PURE WRITER. It NEVER touches .makato/memory/ — promotion of
# generalizable records into the committed store is documentation-agent's job
# (via scripts/promote-lessons.sh, S2/#471). The record shape written here
# matches what promote-lessons.sh reads from change-lessons.jsonl as "source B":
# fields {ts, tier, text, tags, scope, key, repo}.
#
# The build lane recalls memory (S3) but, before this script, never contributed.
# write-lessons.sh makes the lane symmetric: at a build session terminal step
# (build-verify / build-push-to-git) the agent appends any noteworthy lesson.
#
# Usage:
#   write-lessons.sh <key> <tier> <scope> <text> [tags]
#
#   key    story key, e.g. 473-makato-build-lane-lesson-and-fact-write (required)
#   tier   procedural | semantic (required)
#            procedural = a lesson (bugfix/gotcha pattern)
#            semantic   = an agent fact (durable technical truth)
#   scope  generalizable | local (required)
#            generalizable = promote-lessons.sh will lift it into .makato/memory/
#            local          = stays in the per-issue store, never promoted
#   text   lesson text (required, quoted)
#   tags   optional comma-separated list (default: empty array)
#
# The writer STAMPS tier verbatim but does NOT route by tier. Routing a
# tier:semantic record into .makato/memory/semantic.jsonl is the promoter's job
# and is tracked separately (#494); until then a semantic record is still
# promoted by S2 but mis-tiered as procedural (no data loss).
#
# Exit codes:
#   0   record appended
#   1   usage / validation error (bad tier, bad scope, missing args) — nothing written
#   2   spec folder for <key> not found — nothing written
set -euo pipefail

_usage() {
  cat >&2 <<'EOF'
usage: write-lessons.sh <key> <tier> <scope> <text> [tags]
  tier  = procedural | semantic
  scope = generalizable | local
  tags  = optional comma-separated list
EOF
}

# ---------------------------------------------------------------------------
# Parse and validate arguments (fail fast on a mis-stamped record).
# ---------------------------------------------------------------------------
KEY="${1:-}"
TIER="${2:-}"
SCOPE="${3:-}"
TEXT="${4:-}"
TAGS_CSV="${5:-}"

if [[ -z "$KEY" || -z "$TIER" || -z "$SCOPE" || -z "$TEXT" ]]; then
  echo "write-lessons: missing required argument" >&2
  _usage
  exit 1
fi

case "$TIER" in
  procedural | semantic) ;;
  *)
    echo "write-lessons: invalid tier '$TIER' (expected: procedural | semantic)" >&2
    exit 1
    ;;
esac

case "$SCOPE" in
  generalizable | local) ;;
  *)
    echo "write-lessons: invalid scope '$SCOPE' (expected: generalizable | local)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve to the MAIN checkout's repo root. From a worktree,
# `git rev-parse --git-common-dir` echoes the main repo's `.git`; its parent is
# the main checkout. specs/ is gitignored, so a per-run worktree has no specs/
# content — the per-issue store must live in the main checkout so promote-lessons.sh
# (which also resolves via the common dir) reads the same file. Identical
# behaviour for non-worktree callers. Mirrors shared/build-log.sh.
# ---------------------------------------------------------------------------
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  # Outside a git repo (test fixtures / scratch) — degrade gracefully.
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
SPECS_DIR="$REPO_ROOT/specs"

# ---------------------------------------------------------------------------
# Resolve the spec folder: prefix-match specs/<key>-*/ (canonical to-issues
# naming), falling back to the exact specs/<key>/ folder.
# ---------------------------------------------------------------------------
SPEC_FOLDER=""
if [[ -d "$SPECS_DIR" ]]; then
  SPEC_FOLDER="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${KEY}-*" 2>/dev/null | sort | head -1)"
fi
if [[ -z "$SPEC_FOLDER" && -d "$SPECS_DIR/$KEY" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi
if [[ -z "$SPEC_FOLDER" ]]; then
  echo "write-lessons: no spec folder for key '$KEY' under $SPECS_DIR" >&2
  exit 2
fi

STORE="$SPEC_FOLDER/change-lessons.jsonl"

# ---------------------------------------------------------------------------
# Derive the repo slug (owner/repo) from git remote, normalized the same way
# promote-lessons.sh does, so the `repo` field is consistent across writer and
# promoter.
# ---------------------------------------------------------------------------
_repo_slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$url" ]]; then
    echo "unknown/unknown"
    return 0
  fi
  echo "$url" \
    | sed 's|.*github\.com[:/]\(.*\)|\1|' \
    | sed 's|\.git$||'
}
REPO_SLUG="$(_repo_slug)"

# ---------------------------------------------------------------------------
# Emit one JSONL record via python3 for correct JSON escaping (text may carry
# quotes, backslashes, unicode). tags CSV → JSON array (empty CSV → []).
# ---------------------------------------------------------------------------
KEY="$KEY" TIER="$TIER" SCOPE="$SCOPE" TEXT="$TEXT" TAGS_CSV="$TAGS_CSV" REPO_SLUG="$REPO_SLUG" \
STORE="$STORE" python3 <<'PYEOF'
import datetime
import json
import os

tags_csv = os.environ.get("TAGS_CSV", "")
tags = [t.strip() for t in tags_csv.split(",") if t.strip()] if tags_csv else []

record = {
    # Timezone-aware UTC, rendered with the same trailing-Z format the schema
    # and promote-lessons.sh use (…utcnow() is deprecated; this is the drop-in).
    "ts": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).isoformat() + "Z",
    "tier": os.environ["TIER"],
    "text": os.environ["TEXT"],
    "tags": tags,
    "scope": os.environ["SCOPE"],
    "key": os.environ["KEY"],
    "repo": os.environ["REPO_SLUG"],
}

store = os.environ["STORE"]
# Append one line — JSONL is append-safe; no rewrite of prior records.
with open(store, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, separators=(",", ":")) + "\n")
PYEOF
