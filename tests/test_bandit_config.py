"""Regression guard: [tool.bandit] config and bandit hook args must stay wired."""

from __future__ import annotations

import pathlib
import tomllib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def _bandit_hook_block(content: str) -> str:
    start = content.find("id: bandit")
    if start == -1:
        return ""
    end = content.find("\n  - repo:", start)
    return content[start:end] if end != -1 else content[start:]


def test_bandit_section_exists() -> None:
    with open(REPO_ROOT / "pyproject.toml", "rb") as fh:
        config = tomllib.load(fh)
    assert "bandit" in config.get("tool", {}), "[tool.bandit] section must exist in pyproject.toml"


def test_b101_in_skips() -> None:
    with open(REPO_ROOT / "pyproject.toml", "rb") as fh:
        config = tomllib.load(fh)
    skips = config.get("tool", {}).get("bandit", {}).get("skips", [])
    assert "B101" in skips, "[tool.bandit].skips must contain B101"


def test_bandit_hook_uses_pyproject() -> None:
    content = (REPO_ROOT / ".pre-commit-config.yaml").read_text()
    block = _bandit_hook_block(content)
    assert "-c" in block and "pyproject.toml" in block, "bandit hook must pass -c pyproject.toml via args"


def test_bandit_hook_has_toml_dep() -> None:
    content = (REPO_ROOT / ".pre-commit-config.yaml").read_text()
    block = _bandit_hook_block(content)
    assert "bandit[toml]" in block, "bandit hook must list bandit[toml] in additional_dependencies"
