"""Tests for scripts/lesson-prune.sh (Task 1 — DUPLICATE/CONSOLIDATE/KEEP classification).

Tests call the shell script via subprocess with a temp directory as MEMORY_DIR.
Fully offline — no git remote access required.

The script reads .makato/memory/procedural.jsonl and semantic.jsonl, classifies
each record, and emits one JSON line per record on stdout:
  {key, action, reason, target}

Actions covered in Task 1: DUPLICATE, CONSOLIDATE, KEEP.
(STALE, GRADUATED are Task 2 — not tested here.)
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

WORKTREE = Path("/Users/I346175/GITHUB/makato/.claude/worktrees/macatocz-makato-475")
SCRIPT = WORKTREE / "plugins" / "makato-orchestrate" / "scripts" / "lesson-prune.sh"


def _run(memory_dir: Path, **extra_env) -> subprocess.CompletedProcess:
    """Invoke lesson-prune.sh with MEMORY_DIR as the positional argument."""
    env = {**os.environ, "MAKATO_PRUNE_REPO_OVERRIDE": "macatocz/makato-test"}
    env.update(extra_env)
    return subprocess.run(
        ["bash", str(SCRIPT), str(memory_dir)],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(WORKTREE),
    )


def _write_records(memory_dir: Path, filename: str, records: list[dict]) -> Path:
    """Write records as JSONL to memory_dir/filename, creating parent dirs."""
    memory_dir.mkdir(parents=True, exist_ok=True)
    path = memory_dir / filename
    path.write_text("\n".join(json.dumps(rec) for rec in records) + "\n")
    return path


def _parse_output(result: subprocess.CompletedProcess) -> list[dict]:
    """Parse stdout JSON lines into a list of dicts."""
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return [json.loads(line) for line in lines]


class TestLessonPruneKeepDefault:
    """Single record with no duplicates or shared tags → action:KEEP."""

    def test_single_record_is_kept(self, tmp_path):
        """Single record in procedural.jsonl → action:KEEP."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {
                "key": "abc123",
                "text": "Always run tests before merging",
                "tags": ["testing"],
                "occurrences": 1,
                "date": "2026-07-01",
            }
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] == "KEEP"
        assert records[0]["key"] == "abc123"

    def test_all_keep_multiple_distinct_records(self, tmp_path):
        """Multiple records with no duplicates and no shared tags → all KEEP."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "aaa", "text": "Use atomic writes for files", "tags": ["io"], "occurrences": 1, "date": "2026-07-01"},
            {"key": "bbb", "text": "Validate inputs at boundaries", "tags": ["validation"], "occurrences": 2, "date": "2026-07-02"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 2
        assert all(rec["action"] == "KEEP" for rec in records)


class TestLessonPruneDuplicate:
    """DUPLICATE: two records with same normalized text+tags hash."""

    def test_duplicate_keeps_higher_occurrences(self, tmp_path):
        """Two records with same text+tags: higher occurrences → KEEP, other → DUPLICATE."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "key-low", "text": "use atomic writes for file ops", "tags": ["io", "safety"], "occurrences": 1, "date": "2026-07-01"},
            {"key": "key-high", "text": "use atomic writes for file ops", "tags": ["io", "safety"], "occurrences": 5, "date": "2026-07-02"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 2
        by_key = {rec["key"]: rec for rec in records}
        assert by_key["key-high"]["action"] == "KEEP", f"Expected KEEP for key-high, got: {by_key['key-high']}"
        assert by_key["key-low"]["action"] == "DUPLICATE", f"Expected DUPLICATE for key-low, got: {by_key['key-low']}"
        assert by_key["key-low"]["target"] == "key-high", (
            f"Expected target=key-high, got: {by_key['key-low']['target']}"
        )

    def test_duplicate_keeps_newer_date_on_tie(self, tmp_path):
        """Two records with same text+tags and equal occurrences: newer date → KEEP."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "key-old", "text": "normalize text before hashing", "tags": ["hashing"], "occurrences": 3, "date": "2026-01-01"},
            {"key": "key-new", "text": "normalize text before hashing", "tags": ["hashing"], "occurrences": 3, "date": "2026-07-20"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        by_key = {rec["key"]: rec for rec in records}
        assert by_key["key-new"]["action"] == "KEEP", f"Newer date should win: {by_key}"
        assert by_key["key-old"]["action"] == "DUPLICATE"


class TestLessonPruneConsolidate:
    """CONSOLIDATE: 2+ records sharing the same tag but not identical."""

    def test_shared_tag_triggers_consolidate(self, tmp_path):
        """Two records sharing a tag but different text → both get CONSOLIDATE."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "rec-a", "text": "use ruff for linting python files", "tags": ["python", "linting"], "occurrences": 1, "date": "2026-07-01"},
            {"key": "rec-b", "text": "configure ruff in pyproject toml", "tags": ["python", "config"], "occurrences": 1, "date": "2026-07-02"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 2
        assert all(rec["action"] == "CONSOLIDATE" for rec in records), (
            f"Expected all CONSOLIDATE, got: {[rec['action'] for rec in records]}"
        )


class TestLessonPruneSemanticFile:
    """Script reads semantic.jsonl in addition to procedural.jsonl."""

    def test_semantic_records_are_classified(self, tmp_path):
        """Records from semantic.jsonl appear in classification output."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "semantic.jsonl", [
            {"key": "sem-1", "text": "Keep interfaces small and focused", "tags": ["design"], "occurrences": 2, "date": "2026-07-01"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["key"] == "sem-1"
        assert records[0]["action"] == "KEEP"

    def test_duplicate_across_files_detected(self, tmp_path):
        """Same text+tags in procedural.jsonl and semantic.jsonl → DUPLICATE detected."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "proc-1", "text": "same lesson across files", "tags": ["cross"], "occurrences": 1, "date": "2026-07-01"},
        ])
        _write_records(memory_dir, "semantic.jsonl", [
            {"key": "sem-2", "text": "same lesson across files", "tags": ["cross"], "occurrences": 3, "date": "2026-07-02"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 2
        by_key = {rec["key"]: rec for rec in records}
        # sem-2 has higher occurrences → KEEP; proc-1 → DUPLICATE
        assert by_key["sem-2"]["action"] == "KEEP"
        assert by_key["proc-1"]["action"] == "DUPLICATE"


class TestLessonPruneOutputFormat:
    """Every output line must have exactly: key, action, reason, target."""

    def test_output_fields_present(self, tmp_path):
        """Every output record has the four required fields."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "chk-1", "text": "validate env before running", "tags": ["env"], "occurrences": 1, "date": "2026-07-01"},
        ])
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        for rec in records:
            assert "key" in rec, f"Missing 'key' field: {rec}"
            assert "action" in rec, f"Missing 'action' field: {rec}"
            assert "reason" in rec, f"Missing 'reason' field: {rec}"
            assert "target" in rec, f"Missing 'target' field: {rec}"

    def test_output_is_compact_json(self, tmp_path):
        """Output lines are compact JSON (no pretty-printing)."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "fmt-1", "text": "compact output test", "tags": ["fmt"], "occurrences": 1, "date": "2026-07-01"},
        ])
        result = _run(memory_dir)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        assert len(lines) == 1
        # Compact JSON has no spaces after : or ,
        assert "  " not in lines[0], f"Output should be compact JSON: {lines[0]}"


class TestLessonPruneEnvOverride:
    """MAKATO_PRUNE_REPO_OVERRIDE is accepted and does not cause a crash."""

    def test_env_override_does_not_crash(self, tmp_path):
        """MAKATO_PRUNE_REPO_OVERRIDE env var is accepted without crashing."""
        memory_dir = tmp_path / "memory"
        _write_records(memory_dir, "procedural.jsonl", [
            {"key": "env-test", "text": "test env override path", "tags": ["env"], "occurrences": 1, "date": "2026-07-01"},
        ])
        result = _run(memory_dir, MAKATO_PRUNE_REPO_OVERRIDE="custom/repo-override")
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["key"] == "env-test"


class TestLessonPruneEmptyInputs:
    """Edge cases: empty files, missing files, default MEMORY_DIR."""

    def test_no_memory_files_exits_zero(self, tmp_path):
        """If neither procedural.jsonl nor semantic.jsonl exists, exits 0 with no output."""
        memory_dir = tmp_path / "empty_memory"
        memory_dir.mkdir()
        result = _run(memory_dir)
        assert result.returncode == 0, f"Expected exit 0, got {result.returncode}. stderr: {result.stderr}"
        assert result.stdout.strip() == ""

    def test_empty_memory_file_exits_zero(self, tmp_path):
        """Empty procedural.jsonl → exits 0 with no output lines."""
        memory_dir = tmp_path / "memory"
        memory_dir.mkdir()
        (memory_dir / "procedural.jsonl").write_text("")
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert result.stdout.strip() == ""
