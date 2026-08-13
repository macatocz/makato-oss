"""Regression guard: pytest-slow hook must not reference non-existent test directories."""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = REPO_ROOT / ".pre-commit-config.yaml"


def _pytest_slow_entry(content: str) -> str:
    start = content.find("id: pytest-slow")
    if start == -1:
        return ""
    end = content.find("\n  - repo:", start)
    return content[start:end] if end != -1 else content[start:]


def test_pytest_slow_no_unit_path() -> None:
    content = CONFIG.read_text()
    assert "tests/unit" not in _pytest_slow_entry(content), "pytest-slow hook must not reference tests/unit (directory does not exist)"


def test_pytest_slow_no_property_path() -> None:
    content = CONFIG.read_text()
    assert "tests/property" not in _pytest_slow_entry(content), "pytest-slow hook must not reference tests/property (directory does not exist)"
