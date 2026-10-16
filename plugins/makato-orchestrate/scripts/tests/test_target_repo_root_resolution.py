"""Regression tests for explicit target-root resolution from nested worktrees."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

_SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from emit_needs_planning_signal import _repo_root as resolve_needs_root  # noqa: E402
from emit_reshape_request import resolve_repo_root as resolve_reshape_root  # noqa: E402
from lesson_prune import resolve_repo_root as resolve_prune_root  # noqa: E402

_ROOT_RESOLVERS = (resolve_reshape_root, resolve_needs_root, resolve_prune_root)


def _git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def _linked_worktree_layout(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create main → linked target → nested per-run worktree layout."""
    main_root = tmp_path / "main"
    main_root.mkdir()
    _git("init", "-q", "-b", "main", str(main_root))
    _git("-C", str(main_root), "config", "user.email", "root-test@example.com")
    _git("-C", str(main_root), "config", "user.name", "Root Test")
    (main_root / "README.md").write_text("seed\n", encoding="utf-8")
    _git("-C", str(main_root), "add", "README.md")
    _git("-C", str(main_root), "commit", "-q", "-m", "seed")

    target_root = tmp_path / "target"
    _git("-C", str(main_root), "worktree", "add", "-q", "-b", "linked-target", str(target_root), "HEAD")

    run_worktree = target_root / ".claude" / "worktrees" / "x"
    run_worktree.parent.mkdir(parents=True)
    _git("-C", str(target_root), "worktree", "add", "-q", "--detach", str(run_worktree), "HEAD")
    return main_root.resolve(), target_root.resolve(), run_worktree.resolve()


def test_target_root_wins_and_is_canonical_from_nested_worktree(tmp_path, monkeypatch):
    main_root, target_root, run_worktree = _linked_worktree_layout(tmp_path)
    target_alias = tmp_path / "target-alias"
    target_alias.symlink_to(target_root, target_is_directory=True)
    monkeypatch.chdir(run_worktree)
    monkeypatch.setenv("MAKATO_TARGET_REPO_ROOT", str(target_alias))

    for resolve_root in _ROOT_RESOLVERS:
        assert Path(resolve_root()) == target_root

    assert target_root != main_root


def test_unset_target_root_preserves_common_dir_main_checkout(tmp_path, monkeypatch):
    main_root, target_root, run_worktree = _linked_worktree_layout(tmp_path)
    monkeypatch.chdir(run_worktree)
    monkeypatch.delenv("MAKATO_TARGET_REPO_ROOT", raising=False)

    for resolve_root in _ROOT_RESOLVERS:
        assert Path(resolve_root()) == main_root

    assert target_root != main_root


def test_invalid_target_root_fails_instead_of_falling_back(tmp_path, monkeypatch):
    _, _, run_worktree = _linked_worktree_layout(tmp_path)
    not_a_directory = tmp_path / "not-a-directory"
    not_a_directory.write_text("file\n", encoding="utf-8")
    monkeypatch.chdir(run_worktree)
    monkeypatch.setenv("MAKATO_TARGET_REPO_ROOT", str(not_a_directory))

    for resolve_root in _ROOT_RESOLVERS:
        with pytest.raises(SystemExit, match="target repository root is not a directory"):
            resolve_root()
