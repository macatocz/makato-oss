"""Tests for Phase-0 spike artefacts (#3 — makato-harness-independence).

Validates that the three committed spike documents exist, are non-empty, and
contain the required sections per the acceptance criteria of issue #3:

- D16 flipped from PENDING to RESOLVED
- Migration scope count matches the `grep -r "^model:" plugins/` audit
- filterBrowser workaround documented
- Phase-detection contract resolved (Option B chosen)
- omp absence documented with gate disposition
"""

from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
DOCS_DIR = REPO_ROOT / "docs" / "harness-independence"


# ---------------------------------------------------------------------------
# Artefact existence
# ---------------------------------------------------------------------------


def test_phase0_spike_results_exists():
    """phase-0-spike-results.md must be committed."""
    assert (DOCS_DIR / "phase-0-spike-results.md").exists(), "phase-0-spike-results.md is missing from docs/harness-independence/"


def test_d16_phase_detection_contract_exists():
    """d16-phase-detection-contract.md must be committed."""
    assert (DOCS_DIR / "d16-phase-detection-contract.md").exists(), "d16-phase-detection-contract.md is missing from docs/harness-independence/"


def test_q5_migration_scope_exists():
    """q5-migration-scope.md must be committed."""
    assert (DOCS_DIR / "q5-migration-scope.md").exists(), "q5-migration-scope.md is missing from docs/harness-independence/"


# ---------------------------------------------------------------------------
# D16 phase-detection contract — RESOLVED, Option B
# ---------------------------------------------------------------------------


def test_d16_is_resolved():
    """D16 must declare RESOLVED status (not PENDING)."""
    content = (DOCS_DIR / "d16-phase-detection-contract.md").read_text()
    assert "RESOLVED" in content, "d16 document must show RESOLVED status"
    assert "PENDING" not in content or "PENDING" not in content.split("RESOLVED")[0], "D16 still reads as PENDING — it must be flipped to RESOLVED"


def test_d16_chooses_option_b():
    """D16 must document Option B (state-file-only) as the chosen option."""
    content = (DOCS_DIR / "d16-phase-detection-contract.md").read_text()
    assert "Option B" in content, "D16 must explicitly choose Option B"
    assert "state-file-only" in content.lower() or "state-file" in content.lower(), "D16 must describe the state-file-only detection approach"


def test_d16_documents_session_id_resume_handle():
    """D16 must document the omp resume handle (session_id)."""
    content = (DOCS_DIR / "d16-phase-detection-contract.md").read_text()
    assert "session_id" in content, "D16 must document the session_id field as the resume handle"


def test_d16_documents_terminal_event_shape():
    """D16 must capture the terminal NDJSON event shape."""
    content = (DOCS_DIR / "d16-phase-detection-contract.md").read_text()
    assert '"type"' in content and '"result"' in content, "D16 must include the terminal event shape with type:result"


# ---------------------------------------------------------------------------
# Migration scope — Q5 counts
# ---------------------------------------------------------------------------


def test_q5_documents_agent_file_count():
    """q5 must document the number of agent files needing modelRole substitution."""
    content = (DOCS_DIR / "q5-migration-scope.md").read_text()
    # The confirmed count is 25 agent .md files (grep -r "^model:" plugins/ | grep "/agents/")
    assert "25" in content, "q5 must document 25 agent .md files requiring modelRole substitution"


def test_q5_documents_shell_script_count():
    """q5 must document shell scripts requiring targeted harness rewrite."""
    content = (DOCS_DIR / "q5-migration-scope.md").read_text()
    assert "5" in content, "q5 must document 5 shell scripts requiring targeted rewrite"
    assert "functions.sh" in content, "q5 must name functions.sh as a rewrite target"
    assert "context-handoff.sh" in content, "q5 must name context-handoff.sh as a rewrite target"


def test_q5_documents_makato_harness_bin_seam():
    """q5 or phase-0 must reference the MAKATO_HARNESS_BIN insertion seam."""
    q5 = (DOCS_DIR / "q5-migration-scope.md").read_text()
    phase0 = (DOCS_DIR / "phase-0-spike-results.md").read_text()
    combined = q5 + phase0
    assert "MAKATO_HARNESS_BIN" in combined or "MAKATO_CLAUDE_BIN" in combined, "The dispatch seam rename (MAKATO_CLAUDE_BIN → MAKATO_HARNESS_BIN) must be documented"


def test_q5_count_matches_grep_audit():
    """Verify the modelRole migration is complete: 0 model: remain, 25 modelRole: present.

    Pre-migration (Phase-0 spike): 25 agent .md files had ``model:`` frontmatter.
    Post-migration (issue #5): all 25 use ``modelRole:`` — no provider name in code.
    AC-1: grep audit must return zero results for model: in agent frontmatter.
    """
    import subprocess

    # AC-1: zero model: haiku/sonnet/opus/claude- in any agent frontmatter
    old_result = subprocess.run(
        ["grep", "-r", "^model:", "plugins/", "--include=*.md", "-l"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    old_agent_files = [f for f in old_result.stdout.strip().splitlines() if "/agents/" in f and "RETURN-CONTRACT" not in f]
    assert len(old_agent_files) == 0, f"Expected 0 agent .md files with model: frontmatter after migration, found {len(old_agent_files)}: {old_agent_files}"

    # Positive check: all 25 agents now carry modelRole:
    new_result = subprocess.run(
        ["grep", "-r", "^modelRole:", "plugins/", "--include=*.md", "-l"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    new_agent_files = [f for f in new_result.stdout.strip().splitlines() if "/agents/" in f and "RETURN-CONTRACT" not in f]
    assert len(new_agent_files) == 25, f"Expected 25 agent .md files with modelRole: frontmatter, found {len(new_agent_files)}: {new_agent_files}"


# ---------------------------------------------------------------------------
# omp availability and pass/fail gate
# ---------------------------------------------------------------------------


def test_phase0_documents_omp_absence():
    """phase-0 must document that omp is not installed in this environment."""
    content = (DOCS_DIR / "phase-0-spike-results.md").read_text()
    assert "not installed" in content.lower() or "not available" in content.lower(), "phase-0 must document that omp is not installed on the development machine"


def test_phase0_documents_hermes_fallback_not_triggered():
    """phase-0 must state that the Hermes fallback (D2) is NOT triggered."""
    content = (DOCS_DIR / "phase-0-spike-results.md").read_text()
    assert "Hermes" in content, "phase-0 must address the Hermes fallback gate"
    assert "NOT triggered" in content or "not triggered" in content.lower(), "phase-0 must explicitly state the Hermes fallback is not triggered"


# ---------------------------------------------------------------------------
# filterBrowser caveat — Q8
# ---------------------------------------------------------------------------


def test_phase0_documents_filter_browser():
    """phase-0 must document the filterBrowser caveat and workaround."""
    content = (DOCS_DIR / "phase-0-spike-results.md").read_text()
    assert "filterBrowser" in content or "filter_browser" in content.lower(), "phase-0 must document the filterBrowser Playwright MCP caveat (Q8)"
    assert "false" in content.lower() or "workaround" in content.lower(), "phase-0 must document the filterBrowser:false workaround"
