"""Task 1 RED tests: MAKATO_CLAUDE_BIN → MAKATO_HARNESS_BIN in loop.sh and functions.sh.

AC-1: No reference to MAKATO_CLAUDE_BIN or claude -p remains in the dispatch code path.

Task 3 extends this module: the shared harness-command.sh adapter must exist,
support both the OMP (--yolo) and Claude Code (--dangerously-skip-permissions)
permission flags behind an EXPLICIT MAKATO_HARNESS_MODE switch, and every
dispatch call site in functions.sh/context-handoff.sh must delegate to it
instead of hardcoding a permission flag or reading MAKATO_CLAUDE_BIN.
"""

import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
LOOP_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "loop.sh"
FUNCTIONS_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "functions.sh"
HARNESS_COMMAND_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "harness-command.sh"
CONTEXT_HANDOFF_SH = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "context-handoff.sh"


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
    """functions.sh production dispatch MUST default to --yolo, not --dangerously-skip-permissions.

    Task 3 superseded the literal '"$CLAUDE_BIN" --yolo' call shape with
    delegation to the shared harness-command.sh adapter (_harness_dispatch_args
    populates HARNESS_DISPATCH_ARGS, which defaults to --yolo — see
    test_harness_command_sh_mode_is_explicit_not_inferred_from_bin_name).
    This test now asserts the delegation itself is present at the production
    dispatch call site instead of a hardcoded flag.
    """
    content = FUNCTIONS_SH.read_text()
    assert '"$CLAUDE_BIN" "${HARNESS_DISPATCH_ARGS[@]}"' in content, (
        "functions.sh production dispatch must invoke $CLAUDE_BIN with the shared adapter's HARNESS_DISPATCH_ARGS (defaults to --yolo) instead of a hardcoded flag"
    )


def test_no_dangerously_skip_in_dispatch_path():
    """No --dangerously-skip-permissions should remain in the CLAUDE_BIN dispatch lines."""
    content = FUNCTIONS_SH.read_text()
    # Find lines that invoke $CLAUDE_BIN
    claude_lines = [line for line in content.splitlines() if '"$CLAUDE_BIN"' in line and "--dangerously-skip-permissions" in line]
    assert len(claude_lines) == 0, f"--dangerously-skip-permissions still present in {len(claude_lines)} CLAUDE_BIN line(s): " + str(claude_lines[:3])


def test_stall_resume_uses_omp_resume():
    """_stall_resume must still thread the resume session id through to the
    harness binary via --resume.

    Task 3 moved the literal '--resume "$_resume_sid"' construction into the
    shared harness-command.sh adapter; the call site now passes the session id
    as _harness_dispatch_args's second argument, which the adapter turns into
    `--resume <session_id>` (see test_harness_command_sh_dispatch_args_includes_resume).
    """
    content = FUNCTIONS_SH.read_text()
    assert '_harness_dispatch_args "$resume_prompt" "$_resume_sid"' in content, (
        "_stall_resume must pass $_resume_sid to _harness_dispatch_args so the shared adapter builds --resume <session_id> for the harness binary"
    )


# ---------------------------------------------------------------------------
# Task 3: shared harness-command.sh adapter — command construction, explicit
# mode selection, and no-Claude-only-fallback contract coverage.
# ---------------------------------------------------------------------------


def test_harness_command_sh_exists():
    """The shared harness adapter must exist as its own sourceable/executable file."""
    assert HARNESS_COMMAND_SH.is_file(), "plugins/makato-orchestrate/scripts/harness-command.sh must exist"


def test_harness_command_sh_supports_both_permission_flags():
    """harness-command.sh must define both the OMP and Claude Code permission flags."""
    content = HARNESS_COMMAND_SH.read_text()
    assert "--yolo" in content, "harness-command.sh must support the OMP --yolo permission flag"
    assert "--dangerously-skip-permissions" in content, "harness-command.sh must support the Claude Code --dangerously-skip-permissions flag"
    assert "MAKATO_HARNESS_MODE" in content, "harness-command.sh must read MAKATO_HARNESS_MODE to select the mode"


def test_harness_command_sh_mode_is_explicit_not_inferred_from_bin_name():
    """Mode selection must be explicit-only: a bin named '*claude*' must NOT switch modes on its own."""
    # No MAKATO_HARNESS_MODE set — even though the bin argument mentions "claude",
    # the default mode must remain "omp" (the adapter does not use $1 for mode
    # inference; the standalone CLI's `mode` subcommand takes no bin argument).
    result = subprocess.run(
        ["bash", str(HARNESS_COMMAND_SH), "permission-flag"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"harness-command.sh permission-flag failed: {result.stderr}"
    assert result.stdout.strip() == "--yolo", f"default mode (no MAKATO_HARNESS_MODE) must resolve to --yolo (OMP); got {result.stdout.strip()!r}"


def test_harness_command_sh_explicit_claude_mode_selects_dangerously_skip_permissions():
    """MAKATO_HARNESS_MODE=claude — the explicit compatibility mode — must select the Claude Code flag."""
    import os

    env = os.environ.copy()
    env["MAKATO_HARNESS_MODE"] = "claude"
    result = subprocess.run(
        ["bash", str(HARNESS_COMMAND_SH), "permission-flag"],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    assert result.returncode == 0, f"harness-command.sh permission-flag failed: {result.stderr}"
    assert result.stdout.strip() == "--dangerously-skip-permissions", f"MAKATO_HARNESS_MODE=claude must resolve to --dangerously-skip-permissions; got {result.stdout.strip()!r}"


def test_harness_command_sh_dispatch_args_includes_resume():
    """dispatch-args must build --resume <session_id> -p <prompt> when a session id is given."""
    result = subprocess.run(
        ["bash", str(HARNESS_COMMAND_SH), "dispatch-args", "hello prompt", "sess-123"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"harness-command.sh dispatch-args failed: {result.stderr}"
    lines = result.stdout.splitlines()
    assert lines == ["--yolo", "--resume", "sess-123", "-p", "hello prompt"], lines


def test_harness_command_sh_dispatch_args_no_resume_omits_flag():
    """dispatch-args without a session id must NOT include --resume."""
    result = subprocess.run(
        ["bash", str(HARNESS_COMMAND_SH), "dispatch-args", "hello prompt"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"harness-command.sh dispatch-args failed: {result.stderr}"
    lines = result.stdout.splitlines()
    assert lines == ["--yolo", "-p", "hello prompt"], lines
    assert "--resume" not in lines


def test_functions_sh_sources_shared_harness_adapter():
    """functions.sh must delegate dispatch-arg construction to harness-command.sh."""
    content = FUNCTIONS_SH.read_text()
    assert "harness-command.sh" in content, "functions.sh must source the shared harness-command.sh adapter"


def test_functions_sh_no_hardcoded_yolo_dispatch_remains():
    """No dispatch call site may hardcode --yolo directly on $CLAUDE_BIN any more —
    every site must build its args via the shared adapter (_harness_dispatch_args /
    HARNESS_DISPATCH_ARGS), so an explicit MAKATO_HARNESS_MODE=claude switch is
    honoured everywhere, not just at some call sites."""
    content = FUNCTIONS_SH.read_text()
    hardcoded = [line for line in content.splitlines() if '"$CLAUDE_BIN"' in line and "--yolo" in line]
    assert len(hardcoded) == 0, f"functions.sh still hardcodes --yolo on a $CLAUDE_BIN dispatch line instead of delegating to harness-command.sh: {hardcoded[:5]}"


def test_context_handoff_sh_uses_makato_harness_bin_not_claude_bin():
    """context-handoff.sh must read MAKATO_HARNESS_BIN, matching loop.sh/functions.sh,
    and must NOT depend on MAKATO_CLAUDE_BIN in its active path."""
    content = CONTEXT_HANDOFF_SH.read_text()
    assert "MAKATO_HARNESS_BIN" in content, "context-handoff.sh must reference MAKATO_HARNESS_BIN"
    assert "MAKATO_CLAUDE_BIN" not in content, "context-handoff.sh must NOT reference MAKATO_CLAUDE_BIN — it was renamed to MAKATO_HARNESS_BIN"


def test_context_handoff_sh_sources_shared_harness_adapter():
    """context-handoff.sh must build its resume-script permission flag via the shared adapter."""
    content = CONTEXT_HANDOFF_SH.read_text()
    assert "harness-command.sh" in content, "context-handoff.sh must source the shared harness-command.sh adapter"
