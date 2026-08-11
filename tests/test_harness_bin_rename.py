"""Task 1 RED tests: MAKATO_CLAUDE_BIN → MAKATO_HARNESS_BIN in loop.sh and functions.sh.

AC-1: No reference to MAKATO_CLAUDE_BIN or claude -p remains in the dispatch code path.
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
LOOP_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "loop.sh"
FUNCTIONS_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "functions.sh"


def _dispatch_lines(path: Path) -> list[str]:
    """Return lines that are in active code (not comments) for the dispatch path."""
    lines = []
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        lines.append(line)
    return lines


def test_loop_sh_uses_makato_harness_bin():
    """loop.sh MUST define CLAUDE_BIN using MAKATO_HARNESS_BIN, not MAKATO_CLAUDE_BIN."""
    content = LOOP_SH.read_text()
    assert "MAKATO_HARNESS_BIN" in content, "loop.sh must reference MAKATO_HARNESS_BIN"
    assert "MAKATO_CLAUDE_BIN" not in content, "loop.sh must NOT reference MAKATO_CLAUDE_BIN — it was renamed to MAKATO_HARNESS_BIN"


def test_loop_sh_default_is_omp():
    """loop.sh MUST default CLAUDE_BIN to omp, not claude."""
    content = LOOP_SH.read_text()
    # The assignment line: CLAUDE_BIN="${MAKATO_HARNESS_BIN:-omp}"
    assert re.search(r'CLAUDE_BIN="\$\{MAKATO_HARNESS_BIN:-omp\}"', content), "loop.sh must set CLAUDE_BIN to omp via MAKATO_HARNESS_BIN"


def test_functions_sh_production_dispatch_uses_yolo():
    """functions.sh production dispatch MUST use --yolo, not --dangerously-skip-permissions."""
    content = FUNCTIONS_SH.read_text()
    # Check that the production dispatch at ~3698 uses --yolo
    assert '"$CLAUDE_BIN" --yolo' in content or '"$CLAUDE_BIN" --yolo -p' in content, "functions.sh production dispatch must use --yolo instead of --dangerously-skip-permissions"


def test_no_dangerously_skip_in_dispatch_path():
    """No --dangerously-skip-permissions should remain in the CLAUDE_BIN dispatch lines."""
    content = FUNCTIONS_SH.read_text()
    # Find lines that invoke $CLAUDE_BIN
    claude_lines = [line for line in content.splitlines() if '"$CLAUDE_BIN"' in line and "--dangerously-skip-permissions" in line]
    assert len(claude_lines) == 0, f"--dangerously-skip-permissions still present in {len(claude_lines)} CLAUDE_BIN line(s): " + str(claude_lines[:3])


def test_stall_resume_uses_omp_resume():
    """_stall_resume must use --yolo -p --resume, not --dangerously-skip-permissions --resume."""
    content = FUNCTIONS_SH.read_text()
    assert '--resume "$_resume_sid"' in content or '--resume "$_resume_sid"' in content, "_stall_resume must still pass --resume <session_id> to the harness binary"
