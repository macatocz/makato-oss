"""Test for Task 4: test_lesson_prune.py must exist and pytest passes all scenarios."""

import subprocess
from pathlib import Path

WORKTREE = Path(__file__).parent.parent
PYTEST_TEST = (
    WORKTREE
    / "plugins"
    / "makato-orchestrate"
    / "scripts"
    / "tests"
    / "test_lesson_prune.py"
)


def test_smoke_script_exists():
    assert PYTEST_TEST.exists(), f"Pytest test file not found: {PYTEST_TEST}"


def test_smoke_script_all_scenarios_pass():
    """Run the pytest suite — must exit 0 (all scenarios pass)."""
    result = subprocess.run(
        ["python3", "-m", "pytest", str(PYTEST_TEST), "-v", "--tb=short"],
        capture_output=True,
        text=True,
        cwd=str(WORKTREE),
        timeout=90,
    )
    assert result.returncode == 0, (
        f"Pytest failed (exit {result.returncode}).\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
    assert "passed" in result.stdout, (
        f"Expected 'passed' banner not found.\nSTDOUT:\n{result.stdout}"
    )
