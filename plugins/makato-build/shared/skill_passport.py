"""Hierarchical skill passport writer (F3 / #147).

Provides a persistent, append-only log of which skills were invoked by which
agent across a multi-agent session tree. Each write appends a session node to
``<dir>/skill-passport.json``.

Concurrent writes are guarded with ``fcntl.LOCK_EX | fcntl.LOCK_NB``. If a
lock cannot be acquired, the write is silently skipped — callers must tolerate
a best-effort write (advisory telemetry).

Public API
----------
PassportNode
    Dataclass representing a node in the agent invocation tree.

skills_invoked_transitively(node) -> list[str]
    Sorted, deduplicated union of ``skills_invoked`` across *node* and all
    descendants.

read_passport(dir) -> dict | None
    Parse ``skill-passport.json`` in *dir*; return ``None`` when absent.

write_passport(dir, node) -> None
    Create or append to ``skill-passport.json``.

compute_rollup(passport) -> dict
    Inject ``skills_invoked_transitively`` key per session node (in-memory only).
"""

from __future__ import annotations

import fcntl
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# PassportNode dataclass
# ---------------------------------------------------------------------------


@dataclass
class PassportNode:
    """A single node in the agent invocation tree recorded in a passport."""

    agent_name: str
    task_id: str
    skills_invoked: list
    children: list
    ts: str = ""  # ISO-8601 timestamp; defaults to empty string


# ---------------------------------------------------------------------------
# skills_invoked_transitively
# ---------------------------------------------------------------------------


def skills_invoked_transitively(node: PassportNode) -> list:
    """Return sorted, deduplicated union of skills_invoked across *node* and all descendants.

    Works on both :class:`PassportNode` instances (has ``.skills_invoked`` and
    ``.children`` attributes) and raw ``dict`` nodes (uses key access).
    """
    all_skills: set[str] = set()
    _collect_skills(node, all_skills)
    return sorted(all_skills)


def _collect_skills(node, acc: set) -> None:
    """Recursively collect skills from a PassportNode or dict node."""
    if isinstance(node, PassportNode):
        acc.update(node.skills_invoked)
        for child in node.children:
            _collect_skills(child, acc)
    else:
        # dict-based node
        acc.update(node.get("skills_invoked", []))
        for child in node.get("children", []):
            _collect_skills(child, acc)


# ---------------------------------------------------------------------------
# read_passport
# ---------------------------------------------------------------------------


def read_passport(dir: Path) -> dict | None:
    """Return parsed skill-passport.json dict, or None when file absent."""
    passport_path = Path(dir) / "skill-passport.json"
    if not passport_path.exists():
        return None
    return json.loads(passport_path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# write_passport
# ---------------------------------------------------------------------------


def write_passport(dir: Path, node: dict) -> None:
    """Create or append to skill-passport.json in *dir*.

    Schema: ``{"schema_version": "1", "sessions": [...]}``

    Each session node receives a ``"ts"`` timestamp field (ISO-8601 UTC).

    Uses ``fcntl.LOCK_EX | fcntl.LOCK_NB``. If the lock is already held by
    another process, the write is silently skipped — the file is left unchanged.
    """
    dir = Path(dir)
    passport_path = dir / "skill-passport.json"

    # Stamp the node with a timestamp
    node_with_ts = dict(node)
    node_with_ts["ts"] = datetime.now(timezone.utc).isoformat()

    # Open for read+write, creating the file if necessary.
    # We open with 'a+' so that the file is created atomically when absent,
    # then seek to the start to read existing content.
    try:
        fd = open(passport_path, "a+", encoding="utf-8")
    except OSError:
        return  # Cannot open — skip gracefully

    try:
        # Attempt non-blocking exclusive lock
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            # Lock held by another process — skip gracefully
            return

        try:
            # Read current content
            fd.seek(0)
            content = fd.read()

            if content.strip():
                try:
                    passport = json.loads(content)
                except json.JSONDecodeError:
                    # Corrupted file — start fresh
                    passport = {"schema_version": "1", "sessions": []}
            else:
                passport = {"schema_version": "1", "sessions": []}

            passport["sessions"].append(node_with_ts)

            # Write back (truncate first)
            fd.seek(0)
            fd.truncate()
            json.dump(passport, fd, indent=2)
            fd.flush()
        finally:
            # Release the lock
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        fd.close()


# ---------------------------------------------------------------------------
# compute_rollup
# ---------------------------------------------------------------------------


def compute_rollup(passport: dict) -> dict:
    """Inject skills_invoked_transitively key per session node.

    Operates on the passed dict only (in-memory, never touches disk).
    Returns the modified dict for convenience.
    """
    sessions = passport.get("sessions", [])
    for session in sessions:
        _enrich_node(session)
    return passport


def _enrich_node(node: dict) -> None:
    """Recursively enrich a dict node with skills_invoked_transitively."""
    # Recurse into children first
    for child in node.get("children", []):
        _enrich_node(child)

    # Collect all skills transitively using _collect_skills
    acc: set[str] = set()
    _collect_skills(node, acc)
    node["skills_invoked_transitively"] = sorted(acc)
