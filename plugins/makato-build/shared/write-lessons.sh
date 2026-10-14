#!/usr/bin/env bash
# Capture source evidence, then persist generalizable learning immediately.
# Usage: write-lessons.sh <key> <procedural|semantic> <generalizable|local> <text>
#                        [tags_csv] [--issue N] [--bundle B] [--label L]
# A key selects an existing exact spec directory or a unique key-* match.
# All paths resolve to the consumer's main checkout, including linked-worktree calls.
# Generalizable captures invoke the orchestrate promotion CLI; local records remain
# only in specs/<key>/change-lessons.jsonl. A merge is not a persistence prerequisite.
# MAKATO_ORCHESTRATE_ROOT optionally selects the installed orchestrate plugin root.
# Record contract: {event_id,ts,tier,text,tags,scope,key,repo,issue_number?,bundle?,label?}.
# Exit 0: captured and, if generalizable, persisted. Exit 1: invalid input.
# Exit 2: missing/ambiguous spec. Exit 3: capture retained, durable promotion failed.
set -euo pipefail

_usage() {
  cat >&2 <<'EOF'
usage: write-lessons.sh <key> <tier> <scope> <text> [tags] [--issue N] [--bundle B] [--label L]
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
TAGS_CSV=""
ISSUE_NUMBER=""
BUNDLE=""
LABEL=""

if [[ -z "$KEY" || -z "$TIER" || -z "$SCOPE" || -z "$TEXT" ]]; then
  echo "write-lessons: missing required argument" >&2
  _usage
  exit 1
fi

if [[ "$KEY" == "." || "$KEY" == ".." || "$KEY" == */* ]]; then
  echo "write-lessons: key must name one spec directory" >&2
  exit 1
fi
shift 4
if (($#)) && [[ "$1" != --* ]]; then
  TAGS_CSV="$1"
  shift
fi
while (($#)); do
  case "$1" in
    --issue|--bundle|--label)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "write-lessons: $1 requires a value" >&2
        exit 1
      fi
      case "$1" in
        --issue) ISSUE_NUMBER="$2" ;;
        --bundle) BUNDLE="$2" ;;
        --label) LABEL="$2" ;;
      esac
      shift 2
      ;;
    *) echo "write-lessons: unknown argument $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$ISSUE_NUMBER" && ! "$ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "write-lessons: --issue must be a positive integer" >&2
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
# Resolve exact specs/<key>/ first, otherwise require a unique canonical
# specs/<key>-*/ match. Never append a lesson to an arbitrary prefix match.
# ---------------------------------------------------------------------------
SPEC_FOLDER="$SPECS_DIR/$KEY"
if [[ ! -d "$SPEC_FOLDER" && -d "$SPECS_DIR" ]]; then
  SPEC_MATCHES=()
  for candidate in "$SPECS_DIR/${KEY}"-*/; do
    [[ -d "$candidate" ]] && SPEC_MATCHES+=("${candidate%/}")
  done
  if ((${#SPEC_MATCHES[@]} > 1)); then
    echo "write-lessons: ambiguous spec folder for key '$KEY' under $SPECS_DIR (${#SPEC_MATCHES[@]} matches)" >&2
    exit 2
  fi
  if ((${#SPEC_MATCHES[@]} == 1)); then
    SPEC_FOLDER="${SPEC_MATCHES[0]}"
  fi
fi
if [[ ! -d "$SPEC_FOLDER" ]]; then
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
STORE="$STORE" ISSUE_NUMBER="$ISSUE_NUMBER" BUNDLE="$BUNDLE" LABEL="$LABEL" python3 <<'PYEOF'
import datetime
import fcntl
import json
import os
import pathlib
import re
import sys
import uuid

tags_csv = os.environ.get("TAGS_CSV", "")
tags = [t.strip() for t in tags_csv.split(",") if t.strip()] if tags_csv else []

record = {
    "event_id": str(uuid.uuid4()),
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
issue = os.environ["ISSUE_NUMBER"]
if not issue:
    states = sorted(pathlib.Path(store).parent.glob("workflow-state-*.json"))
    if len(states) > 1:
        sys.exit("write-lessons: shared spec has multiple workflow issues; pass --issue N")
    if states:
        issue = states[0].stem.rsplit("-", 1)[1]
        if not issue.isdigit():
            sys.exit("write-lessons: malformed workflow identity; pass --issue N")
    else:
        match = re.match(r"^([0-9]+)(?:-|$)", record["key"]) or re.search(r"-([0-9]+)$", record["key"])
        issue = match[1] if match else ""
if issue:
    record["issue_number"] = int(issue)
for name in ("bundle", "label"):
    if os.environ[name.upper()]:
        record[name] = os.environ[name.upper()]
with open(store, "a", encoding="utf-8") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write(json.dumps(record, separators=(",", ":")) + "\n")
    fh.flush()
PYEOF

if [[ "$SCOPE" == "generalizable" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PROMOTER=""
  if [[ -n "${MAKATO_ORCHESTRATE_ROOT:-}" ]]; then
    PROMOTER="$MAKATO_ORCHESTRATE_ROOT/scripts/promote-lessons.sh"
  else
    # Match the source-checkout / installed-plugin discovery of interactive-worktree.sh.
    for candidate in       "$SCRIPT_DIR/../../makato-orchestrate"       "$REPO_ROOT/plugins/makato-orchestrate"       "$HOME/.omp/plugins/cache/plugins/"*makato-orchestrate*       "$HOME/.claude/plugins/cache/plugins/"*makato-orchestrate*       "$HOME/.claude/plugins/cache/"*/makato-orchestrate/*; do
      if [[ -f "$candidate/scripts/promote-lessons.sh" ]]; then
        PROMOTER="$candidate/scripts/promote-lessons.sh"
        break
      fi
    done
  fi
  if [[ ! -f "$PROMOTER" ]]; then
    echo "write-lessons: capture retained in $STORE; cannot locate promoter; set MAKATO_ORCHESTRATE_ROOT" >&2
    exit 3
  fi
  if ! bash "$PROMOTER" "$(basename "$SPEC_FOLDER")" "$SPECS_DIR"       "$REPO_ROOT/.makato/memory/procedural.jsonl" "$REPO_ROOT/.makato/memory/semantic.jsonl"; then
    echo "write-lessons: capture retained in $STORE; durable promotion failed" >&2
    exit 3
  fi
fi
