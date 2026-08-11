"""Classify records in .makato/memory/ for pruning curation.

Reads both .makato/memory/procedural.jsonl and semantic.jsonl line-by-line,
classifies each record, and emits a machine-readable classification on stdout.
Pure classification — no file mutation.

Classification rules:
  DUPLICATE   — same dedup key hash(normalize_text(text) + sorted(tags)) as
                another record; keep the record with the highest occurrences /
                newest date, mark the rest DUPLICATE.
  GRADUATED   — record's rule is already encoded in an AGENTS.md (repo root or
                any plugins/*/AGENTS.md). Tolerates heading/structure variance
                by matching on normalized content, not fixed section paths.
  STALE       — BOTH: (a) repo_sha not reachable from HEAD via
                `git merge-base --is-ancestor`, AND (b) date >90 days old.
                NOTE: a still-relevant lesson whose commit was legitimately
                rebased out is a valid false-positive — always review STALE
                proposals with human judgment before approving deletion.
  CONSOLIDATE — 2+ records sharing a tag cluster (at least one common tag)
                but not identical enough to be DUPLICATE — propose a merge.
  Default     → KEEP

Usage:
  python3 lesson_prune.py [MEMORY_DIR]

  MEMORY_DIR   path to memory directory (default: .makato/memory)

Environment overrides (tests):
  MAKATO_PRUNE_REPO_OVERRIDE    Override the repo slug (e.g. "owner/repo").
  MAKATO_PRUNE_TODAY_OVERRIDE   Override today's date (YYYY-MM-DD) for STALE tests.
  MAKATO_PRUNE_HEAD_OVERRIDE    Override HEAD sha for STALE git tests.

Output (stdout): one JSON object per record:
  {"key":<key>,"action":"KEEP|DUPLICATE|GRADUATED|STALE|CONSOLIDATE",
   "reason":"...","target":<key_or_null>}

Exit codes:
  0   success — including no-op when no records found
  non-zero — only on file I/O errors
"""

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Public helper functions (match promote-lessons.sh exactly — Q6 contract)
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
# GRADUATED detection
# ---------------------------------------------------------------------------


def load_agents_contents(repo_root: str) -> list[str]:
    """Return normalized text content from all AGENTS.md files in the repo.

    Scans repo root AGENTS.md and plugins/*/AGENTS.md (maxdepth 3).
    """
    contents: list[str] = []
    # Repo-root AGENTS.md
    root_agents = os.path.join(repo_root, "AGENTS.md")
    if os.path.isfile(root_agents):
        try:
            with open(root_agents, encoding="utf-8") as fh:
                contents.append(normalize_text(fh.read()))
        except Exception:
            pass
    # plugins/*/AGENTS.md up to maxdepth 3
    plugins_dir = os.path.join(repo_root, "plugins")
    if os.path.isdir(plugins_dir):
        for root, dirs, files in os.walk(plugins_dir):
            depth = root[len(plugins_dir) :].count(os.sep)
            if depth > 3:
                dirs.clear()
                continue
            if "AGENTS.md" in files:
                path = os.path.join(root, "AGENTS.md")
                try:
                    with open(path, encoding="utf-8") as fh:
                        contents.append(normalize_text(fh.read()))
                except Exception:
                    pass
    return contents


def is_graduated(text: str, agents_contents: list[str]) -> bool:
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
    for agents_content in agents_contents:
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
# STALE detection
# ---------------------------------------------------------------------------


def get_today(today_override: str = "") -> datetime.date:
    """Return today's date, respecting MAKATO_PRUNE_TODAY_OVERRIDE."""
    if today_override:
        return datetime.date.fromisoformat(today_override)
    return datetime.date.today()


def sha_is_ancestor(sha: str, head_override: str = "") -> bool:
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


def is_stale(
    record: dict,
    today_override: str = "",
    head_override: str = "",
) -> bool:
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
    if sha_is_ancestor(repo_sha, head_override):
        return False
    # Condition (b): date >90 days old.
    try:
        record_date = datetime.date.fromisoformat(date_str)
    except ValueError:
        return False
    age_days = (get_today(today_override) - record_date).days
    return age_days > 90


# ---------------------------------------------------------------------------
# Record loading
# ---------------------------------------------------------------------------


def load_records(procedural_file: str, semantic_file: str) -> list[dict]:
    """Read all records from both JSONL input files."""
    all_records: list[dict] = []
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
            print(
                f"lesson-prune: WARNING skipping {filepath}: {exc}",
                file=sys.stderr,
            )
    return all_records


# ---------------------------------------------------------------------------
# Classification pipeline
# ---------------------------------------------------------------------------


def classify_records(
    all_records: list[dict],
    agents_contents: list[str],
    today_override: str = "",
    head_override: str = "",
) -> list[dict]:
    """Classify a list of records and return classification dicts.

    Each returned dict has keys: key, action, reason, target.

    Priority order (highest wins):
      DUPLICATE > STALE > GRADUATED > CONSOLIDATE > KEEP
    """
    if not all_records:
        return []

    # Step 1: Compute dedup key for every record.
    for rec in all_records:
        text = rec.get("text", "")
        tags = rec.get("tags") or []
        if not isinstance(tags, list):
            tags = []
        rec["_dedup_key"] = compute_key(text, tags)

    # Step 2: Group by dedup key.
    dedup_groups: dict[str, list[int]] = collections.defaultdict(list)
    for idx, rec in enumerate(all_records):
        dedup_groups[rec["_dedup_key"]].append(idx)

    # Step 3: Assign KEEP / DUPLICATE within each dedup group.
    #   Keeper = highest occurrences; tie-break: lexicographically newest date string.
    action_map: dict[int, dict] = {}

    for dedup_key, indices in dedup_groups.items():
        if len(indices) == 1:
            action_map[indices[0]] = {
                "action": "KEEP",
                "reason": "unique record",
                "target": None,
            }
            continue

        def _sort_key(idx: int) -> tuple:
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

    # Step 4: CONSOLIDATE check.
    #   Among records currently assigned KEEP, find those sharing at least one tag
    #   with another KEEP record.
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

    # Step 5: GRADUATED and STALE — override KEEP and CONSOLIDATE assignments.
    #   Priority order (highest wins): DUPLICATE > STALE > GRADUATED > CONSOLIDATE > KEEP.
    #   DUPLICATE is already locked in Step 3 (never overridden here).
    for idx, rec in enumerate(all_records):
        current_action = action_map[idx]["action"]
        if current_action == "DUPLICATE":
            continue  # DUPLICATE is locked

        text = rec.get("text", "")

        if is_stale(rec, today_override, head_override):
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
        elif is_graduated(text, agents_contents):
            action_map[idx] = {
                "action": "GRADUATED",
                "reason": "lesson text (or strong token subset) already encoded in an AGENTS.md",
                "target": None,
            }

    # Step 6: Build output list.
    results: list[dict] = []
    for idx, rec in enumerate(all_records):
        info = action_map[idx]
        results.append(
            {
                "key": rec.get("key", ""),
                "action": info["action"],
                "reason": info["reason"],
                "target": info["target"],
            }
        )
    return results


# ---------------------------------------------------------------------------
# Repo root resolution (mirrors workflow-state.sh logic)
# ---------------------------------------------------------------------------


def resolve_repo_root() -> str:
    """Resolve REPO_ROOT from the common git dir (works from worktrees)."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            git_common_dir = result.stdout.strip()
            if git_common_dir:
                return str(Path(git_common_dir).parent.resolve())
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return os.getcwd()


# ---------------------------------------------------------------------------
# main entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """Classify lesson records and emit one JSON line per record to stdout.

    Returns 0 on success (including empty memory dir), non-zero on I/O errors.
    """
    parser = argparse.ArgumentParser(
        description="Classify .makato/memory/ records for pruning curation.",
        prog="lesson_prune",
    )
    parser.add_argument(
        "memory_dir",
        nargs="?",
        default=None,
        help="Path to memory directory (default: <repo_root>/.makato/memory)",
    )
    args = parser.parse_args(argv)

    repo_root = resolve_repo_root()

    if args.memory_dir is not None:
        memory_dir = args.memory_dir
    else:
        memory_dir = os.path.join(repo_root, ".makato", "memory")

    procedural_file = os.path.join(memory_dir, "procedural.jsonl")
    semantic_file = os.path.join(memory_dir, "semantic.jsonl")

    # Environment overrides (for tests)
    today_override = os.environ.get("MAKATO_PRUNE_TODAY_OVERRIDE", "")
    head_override = os.environ.get("MAKATO_PRUNE_HEAD_OVERRIDE", "")

    # Load AGENTS.md contents for GRADUATED detection
    agents_contents = load_agents_contents(repo_root)

    # Load records
    all_records = load_records(procedural_file, semantic_file)

    if not all_records:
        return 0

    # Classify
    results = classify_records(
        all_records,
        agents_contents,
        today_override=today_override,
        head_override=head_override,
    )

    # Emit one compact JSON line per record
    for result in results:
        print(json.dumps(result, separators=(",", ":")))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
