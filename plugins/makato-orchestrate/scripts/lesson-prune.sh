#!/usr/bin/env bash
# lesson-prune.sh — classify records in .makato/memory/ for pruning curation
#
# Reads both .makato/memory/procedural.jsonl and semantic.jsonl line-by-line,
# classifies each record, and emits a machine-readable classification on stdout.
# Pure classification — no file mutation.
#
# Classification rules:
#   DUPLICATE   — same dedup key hash(normalize_text(text) + sorted(tags)) as
#                 another record; keep the record with the highest occurrences /
#                 newest date, mark the rest DUPLICATE.
#   GRADUATED   — record's rule is already encoded in an AGENTS.md (repo root or
#                 any plugins/*/AGENTS.md). Tolerates heading/structure variance
#                 by matching on normalized content, not fixed section paths.
#   STALE       — BOTH: (a) repo_sha not reachable from HEAD via
#                 `git merge-base --is-ancestor`, AND (b) date >90 days old.
#                 NOTE: a still-relevant lesson whose commit was legitimately
#                 rebased out is a valid false-positive — always review STALE
#                 proposals with human judgment before approving deletion.
#   CONSOLIDATE — 2+ records sharing a tag cluster (at least one common tag)
#                 but not identical enough to be DUPLICATE — propose a merge.
#   Default     → KEEP
#
# Usage:
#   lesson-prune.sh [MEMORY_DIR]
#
#   MEMORY_DIR   path to memory directory (default: .makato/memory)
#
# Environment overrides (tests):
#   MAKATO_PRUNE_REPO_OVERRIDE    Override the repo slug (e.g. "owner/repo").
#   MAKATO_PRUNE_TODAY_OVERRIDE   Override today's date (YYYY-MM-DD) for STALE tests.
#   MAKATO_PRUNE_HEAD_OVERRIDE    Override HEAD sha for STALE git tests.
#
# Output (stdout): one JSON object per record:
#   {"key":<key>,"action":"KEEP|DUPLICATE|GRADUATED|STALE|CONSOLIDATE",
#    "reason":"...","target":<key_or_null>}
#
# Exit codes:
#   0   success — including no-op when no records found
#   non-zero — only on file I/O errors
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT from the common git dir (mirrors workflow-state.sh logic).
# ---------------------------------------------------------------------------
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

MEMORY_DIR="${1:-${REPO_ROOT}/.makato/memory}"

# ---------------------------------------------------------------------------
# _log <msg…> — stderr diagnostic
# ---------------------------------------------------------------------------
_log() { echo "lesson-prune: $*" >&2; }

# ---------------------------------------------------------------------------
# Resolve repo slug from git remote (or test override).
# ---------------------------------------------------------------------------
_repo_slug() {
  if [[ -n "${MAKATO_PRUNE_REPO_OVERRIDE:-}" ]]; then
    echo "$MAKATO_PRUNE_REPO_OVERRIDE"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$url" ]]; then
    echo "unknown/unknown"
    return 0
  fi
  # Normalize https://github.com/owner/repo.git and git@github.com:owner/repo.git
  # to owner/repo.
  echo "$url" \
    | sed 's|.*github\.com[:/]\(.*\)|\1|' \
    | sed 's|\.git$||'
}

REPO_SLUG="$(_repo_slug)"

PROCEDURAL_FILE="$MEMORY_DIR/procedural.jsonl"
SEMANTIC_FILE="$MEMORY_DIR/semantic.jsonl"

# ---------------------------------------------------------------------------
# Collect AGENTS.md paths for GRADUATED detection.
# ---------------------------------------------------------------------------
AGENTS_LIST_FILE="$(mktemp)"
cleanup_agents() { rm -f "$AGENTS_LIST_FILE"; }
trap cleanup_agents EXIT

{
  [[ -f "$REPO_ROOT/AGENTS.md" ]] && echo "$REPO_ROOT/AGENTS.md"
  find "$REPO_ROOT/plugins" -maxdepth 3 -name "AGENTS.md" 2>/dev/null | sort || true
} > "$AGENTS_LIST_FILE"

# ---------------------------------------------------------------------------
# Python: load records from both files, classify, emit JSON per record.
# ---------------------------------------------------------------------------
REPO_SLUG="$REPO_SLUG" \
PROCEDURAL_FILE="$PROCEDURAL_FILE" \
SEMANTIC_FILE="$SEMANTIC_FILE" \
AGENTS_LIST_FILE="$AGENTS_LIST_FILE" \
TODAY_OVERRIDE="${MAKATO_PRUNE_TODAY_OVERRIDE:-}" \
HEAD_OVERRIDE="${MAKATO_PRUNE_HEAD_OVERRIDE:-}" \
python3 - <<'PYEOF'
import collections
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

procedural_file = os.environ.get("PROCEDURAL_FILE", "")
semantic_file = os.environ.get("SEMANTIC_FILE", "")
agents_list_file = os.environ.get("AGENTS_LIST_FILE", "")
today_override = os.environ.get("TODAY_OVERRIDE", "")
head_override = os.environ.get("HEAD_OVERRIDE", "")

# ---------------------------------------------------------------------------
# Helper functions — must match promote-lessons.sh exactly (Q6 contract).
# ---------------------------------------------------------------------------
def normalize_text(text: str) -> str:
    """Lowercase, collapse whitespace, strip non-alphanumeric."""
    t = text.lower()
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"[^a-z0-9 ]", "", t)
    return t.strip()


def compute_key(text: str, tags: list) -> str:
    """Dedup key: sha256(normalized_text + sorted_tags JSON)."""
    normalized = normalize_text(text)
    sorted_tags = sorted(str(t) for t in tags)
    payload = normalized + json.dumps(sorted_tags, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# GRADUATED detection: lesson already encoded in an AGENTS.md.
# Tolerates AGENTS.md structure variance — match on normalized content.
# ---------------------------------------------------------------------------
_agents_contents: list[str] = []
try:
    with open(agents_list_file, encoding="utf-8") as _af:
        for _path in _af:
            _path = _path.strip()
            if not _path:
                continue
            try:
                with open(_path, encoding="utf-8") as _agents_fh:
                    _agents_contents.append(normalize_text(_agents_fh.read()))
            except Exception:
                pass
except Exception:
    pass


def is_graduated(text: str) -> bool:
    """Return True when the lesson's normalized text already appears in any AGENTS.md.

    Matching strategy:
    - Verbatim normalized substring match (primary): the full normalized lesson text
      must appear as a contiguous substring in the normalized AGENTS.md content.
    - Token-subset match (secondary, for paraphrased encodings): requires >=80% of
      significant tokens (>4 chars) AND at least 5 such tokens present, to avoid
      false-positives on short lessons whose common words appear incidentally.
    """
    norm = normalize_text(text)
    if not norm:
        return False
    for agents_content in _agents_contents:
        # Primary: verbatim normalized phrase appears in AGENTS.md content.
        if norm in agents_content:
            return True
        # Secondary: strong token-subset (>=80% of long tokens, minimum 5 tokens).
        long_tokens = [tok for tok in norm.split() if len(tok) > 4]
        if len(long_tokens) >= 5:
            matched = sum(1 for tok in long_tokens if tok in agents_content)
            if matched / len(long_tokens) >= 0.8:
                return True
    return False


# ---------------------------------------------------------------------------
# STALE detection: repo_sha unreachable from HEAD AND date >90 days old.
# ---------------------------------------------------------------------------
def get_today() -> datetime.date:
    if today_override:
        return datetime.date.fromisoformat(today_override)
    return datetime.date.today()


def sha_is_ancestor(sha: str) -> bool:
    """Return True when sha is reachable from HEAD (NOT stale)."""
    if not sha or sha in ("unknown", ""):
        return True  # unknown sha → safe default: not STALE
    effective_head = head_override if head_override else "HEAD"
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", sha, effective_head],
            capture_output=True,
            timeout=10,
        )
        return result.returncode == 0
    except Exception:
        return True  # error → safe default: not STALE


def is_stale(record: dict) -> bool:
    """Return True only when BOTH stale conditions hold.

    Condition (a): repo_sha not reachable from HEAD.
    Condition (b): date is >90 days before today.

    NOTE: A still-relevant lesson whose commit was legitimately rebased out is
    a valid false-positive of this check. Always review STALE proposals with
    human judgment before approving deletion.
    """
    repo_sha = record.get("repo_sha", "")
    date_str = record.get("date", "")
    if not repo_sha or not date_str:
        return False
    # Condition (a): sha not reachable from HEAD.
    if sha_is_ancestor(repo_sha):
        return False
    # Condition (b): date >90 days old.
    try:
        record_date = datetime.date.fromisoformat(date_str)
    except ValueError:
        return False
    age_days = (get_today() - record_date).days
    return age_days > 90


# ---------------------------------------------------------------------------
# Read all records from both input files.
# ---------------------------------------------------------------------------
all_records = []

for filepath in [procedural_file, semantic_file]:
    if not filepath or not os.path.exists(filepath):
        continue
    try:
        with open(filepath, encoding="utf-8") as fh:
            for line_item in fh:
                line_item = line_item.strip()
                if not line_item:
                    continue
                try:
                    rec = json.loads(line_item)
                    if isinstance(rec, dict):
                        all_records.append(rec)
                except json.JSONDecodeError:
                    print(
                        f"lesson-prune: WARNING malformed line in {filepath}: {line_item!r}",
                        file=sys.stderr,
                    )
    except Exception as exc:
        print(f"lesson-prune: WARNING skipping {filepath}: {exc}", file=sys.stderr)

if not all_records:
    sys.exit(0)

# ---------------------------------------------------------------------------
# Step 1: Compute dedup key for every record (stored in _dedup_key, not emitted).
# ---------------------------------------------------------------------------
for rec in all_records:
    text = rec.get("text", "")
    tags = rec.get("tags") or []
    if not isinstance(tags, list):
        tags = []
    rec["_dedup_key"] = compute_key(text, tags)

# ---------------------------------------------------------------------------
# Step 2: Group by dedup key — groups with 2+ members are DUPLICATE candidates.
# ---------------------------------------------------------------------------
dedup_groups: dict[str, list[int]] = collections.defaultdict(list)
for idx, rec in enumerate(all_records):
    dedup_groups[rec["_dedup_key"]].append(idx)

# ---------------------------------------------------------------------------
# Step 3: Assign KEEP / DUPLICATE within each dedup group.
#   Keeper = highest occurrences; tie-break: lexicographically newest date string.
# ---------------------------------------------------------------------------
action_map: dict[int, dict] = {}

for dedup_key, indices in dedup_groups.items():
    if len(indices) == 1:
        action_map[indices[0]] = {
            "action": "KEEP",
            "reason": "unique record",
            "target": None,
        }
        continue

    def _sort_key(idx: int):
        rec = all_records[idx]
        occ = rec.get("occurrences", 0)
        date_str = rec.get("date", "")
        return (occ, date_str)

    sorted_indices = sorted(indices, key=_sort_key, reverse=True)
    keeper_idx = sorted_indices[0]
    keeper_rec_key = all_records[keeper_idx].get("key", "")

    action_map[keeper_idx] = {
        "action": "KEEP",
        "reason": "highest occurrences among duplicates",
        "target": None,
    }
    for dup_idx in sorted_indices[1:]:
        action_map[dup_idx] = {
            "action": "DUPLICATE",
            "reason": "same text and tags as keeper record",
            "target": keeper_rec_key,
        }

# ---------------------------------------------------------------------------
# Step 4: CONSOLIDATE check.
#   Among records currently assigned KEEP, find those sharing at least one tag
#   with another KEEP record — these form a consolidation candidate cluster.
#   GRADUATED and STALE override CONSOLIDATE (checked first in Step 5).
# ---------------------------------------------------------------------------
keep_indices = [idx for idx, info in action_map.items() if info["action"] == "KEEP"]

tag_to_keep_indices: dict[str, list[int]] = collections.defaultdict(list)
for idx in keep_indices:
    tags = all_records[idx].get("tags") or []
    if not isinstance(tags, list):
        tags = []
    for tag in tags:
        tag_to_keep_indices[tag].append(idx)

consolidate_set: set[int] = set()
for tag, indices in tag_to_keep_indices.items():
    if len(indices) >= 2:
        for idx in indices:
            consolidate_set.add(idx)

for idx in consolidate_set:
    action_map[idx] = {
        "action": "CONSOLIDATE",
        "reason": "shares tag cluster with other records — merge candidate",
        "target": None,
    }

# ---------------------------------------------------------------------------
# Step 5: GRADUATED and STALE — override KEEP and CONSOLIDATE assignments.
#   Priority order (highest wins): DUPLICATE > STALE > GRADUATED > CONSOLIDATE > KEEP.
#   DUPLICATE is already locked in Step 3 (never overridden here).
# ---------------------------------------------------------------------------
for idx, rec in enumerate(all_records):
    current_action = action_map[idx]["action"]
    if current_action == "DUPLICATE":
        continue  # DUPLICATE is locked

    text = rec.get("text", "")

    if is_stale(rec):
        action_map[idx] = {
            "action": "STALE",
            "reason": (
                f"repo_sha '{rec.get('repo_sha', '')}' not reachable from HEAD "
                f"and date '{rec.get('date', '')}' is >90 days old. "
                "NOTE: verify with human judgment — a legitimate rebase may cause "
                "a false-positive STALE on a still-relevant lesson."
            ),
            "target": None,
        }
    elif is_graduated(text):
        action_map[idx] = {
            "action": "GRADUATED",
            "reason": "lesson text (or strong token subset) already encoded in an AGENTS.md",
            "target": None,
        }

# ---------------------------------------------------------------------------
# Step 6: Emit one compact JSON line per record.
# ---------------------------------------------------------------------------
for idx, rec in enumerate(all_records):
    info = action_map[idx]
    output = {
        "key": rec.get("key", ""),
        "action": info["action"],
        "reason": info["reason"],
        "target": info["target"],
    }
    print(json.dumps(output, separators=(",", ":")))
PYEOF
