"""Tests for T2: .makato allowed in check-root-structure.sh (AC-6)."""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "check-root-structure.sh"


def test_makato_in_allowed_array() -> None:
    """check-root-structure.sh ALLOWED array must contain .makato (AC-6)."""
    content = SCRIPT.read_text()
    assert '".makato"' in content, ".makato must be in the ALLOWED array"


def test_makato_entry_is_inside_allowed_block() -> None:
    """'.makato' entry must appear between ALLOWED=( and the closing ) (AC-6).

    This guards against the string appearing elsewhere in the file (e.g., a comment).
    """
    content = SCRIPT.read_text()
    # Extract the ALLOWED=(...) block
    start = content.index("ALLOWED=(")
    end = content.index(")", start)
    allowed_block = content[start:end]
    assert '".makato"' in allowed_block, (
        '".makato" must appear inside the ALLOWED=(...) array block, '
        f"but it was not found there.\nBlock content:\n{allowed_block}"
    )
