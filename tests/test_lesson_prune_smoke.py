"""RED test for Task 4: lesson-prune-smoke-tests.sh must exist and pass all 12 scenarios."""

from pathlib import Path
import subprocess


WORKTREE = Path(__file__).parent.parent
SMOKE_SCRIPT = (
    WORKTREE
    / "plugins"
    / "makato-orchestrate"
    / "scripts"
    / "lesson-prune-smoke-tests.sh"
)


def test_smoke_script_exists():
    assert SMOKE_SCRIPT.exists(), f"Smoke test script not found: {SMOKE_SCRIPT}"


def test_smoke_script_all_scenarios_pass():
    """Run the smoke test script — must exit 0 (all 12 scenarios pass)."""
    result = subprocess.run(
        ["bash", str(SMOKE_SCRIPT)],
        capture_output=True,
        text=True,
        cwd=str(WORKTREE),
        timeout=90,
    )
    assert result.returncode == 0, (
        f"Smoke tests failed (exit {result.returncode}).\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
    assert "All lesson-prune-smoke-tests passed" in result.stdout, (
        f"Expected success banner not found.\nSTDOUT:\n{result.stdout}"
    )
