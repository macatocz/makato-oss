"""RED test for Task 2: promote-lessons-smoke-tests.sh must exist and pass all 7 scenarios."""

import subprocess
from pathlib import Path

WORKTREE = Path(__file__).parent.parent
SMOKE_SCRIPT = (
    WORKTREE
    / "plugins"
    / "makato-orchestrate"
    / "scripts"
    / "promote-lessons-smoke-tests.sh"
)


def test_smoke_script_exists():
    assert SMOKE_SCRIPT.exists(), f"Smoke test script not found: {SMOKE_SCRIPT}"


def test_smoke_script_all_scenarios_pass():
    """Run the smoke test script — must exit 0 (all 7 scenarios pass)."""
    result = subprocess.run(
        ["bash", str(SMOKE_SCRIPT)],
        capture_output=True,
        text=True,
        cwd=str(WORKTREE),
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Smoke tests failed (exit {result.returncode}).\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
    assert "All promote-lessons-smoke-tests passed" in result.stdout, (
        f"Expected success banner not found.\nSTDOUT:\n{result.stdout}"
    )
