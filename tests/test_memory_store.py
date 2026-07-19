"""Tests for T1: .makato/memory/ committed store existence (AC-5 partial)."""
from pathlib import Path

WORKTREE = Path("/Users/I346175/GITHUB/makato/.claude/worktrees/macatocz-makato-470")


def test_semantic_jsonl_exists():
    assert (WORKTREE / ".makato" / "memory" / "semantic.jsonl").exists()


def test_procedural_jsonl_exists():
    assert (WORKTREE / ".makato" / "memory" / "procedural.jsonl").exists()


def test_semantic_jsonl_is_valid_empty():
    content = (WORKTREE / ".makato" / "memory" / "semantic.jsonl").read_text()
    # Empty JSONL file is valid (zero lines)
    assert content == "" or all(
        line.strip() == "" or __import__("json").loads(line)
        for line in content.splitlines()
    )
