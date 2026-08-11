"""Structural smoke tests for change-lane memory recall and write (#474).

Asserts that the four contract additions documented in issue #474 are present
in the relevant SKILL.md / agent files.  These are static contract tests —
they read committed text files, never execute the skills or scripts.

Contracts verified:

(a) ``analyze/SKILL.md`` contains a ``recall-lessons`` invocation and defines
    ``PRIOR_LESSONS`` — Task 1 (Step 2.7).

(b) ``change-implementer.md`` Input table has a ``PRIOR_LESSONS`` row, and
    ``execute/SKILL.md`` forwards it in the Step 2.2 dispatch bundle — Task 2.

(c) ``execute/SKILL.md`` and ``resolve-review/SKILL.md`` each reference
    ``write-lessons.sh`` at their terminal steps — Task 3.

(d) The documented write call-site names exactly the 7 JSONL fields:
    ts, tier, text, tags, scope, key, repo — confirming the shape expected
    by ``promote-lessons.sh`` (S2/#471) is preserved — Task 3.
"""

from __future__ import annotations

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ANALYZE_SKILL = REPO_ROOT / "plugins" / "makato-change" / "skills" / "analyze" / "SKILL.md"
CHANGE_IMPLEMENTER = REPO_ROOT / "plugins" / "makato-change" / "agents" / "change-implementer.md"
EXECUTE_SKILL = REPO_ROOT / "plugins" / "makato-change" / "skills" / "execute" / "SKILL.md"
RESOLVE_REVIEW_SKILL = REPO_ROOT / "plugins" / "makato-change" / "skills" / "resolve-review" / "SKILL.md"
WRITE_LESSONS_SH = REPO_ROOT / "plugins" / "makato-build" / "shared" / "write-lessons.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# (a) analyze/SKILL.md — recall step + PRIOR_LESSONS variable
# ---------------------------------------------------------------------------


def test_analyze_skill_contains_recall_lessons_invocation() -> None:
    """analyze/SKILL.md must invoke workflow-state.sh recall-lessons."""
    content = _text(ANALYZE_SKILL)
    assert "recall-lessons" in content, "analyze/SKILL.md must contain a recall-lessons invocation (Task 1 / Step 2.7)"


def test_analyze_skill_defines_prior_lessons_variable() -> None:
    """analyze/SKILL.md must define PRIOR_LESSONS and set it to []  on failure."""
    content = _text(ANALYZE_SKILL)
    assert "PRIOR_LESSONS" in content, "analyze/SKILL.md must define the PRIOR_LESSONS variable (Task 1 / Step 2.7)"
    # The skill must set the safe fallback.
    assert 'PRIOR_LESSONS="[]"' in content or "PRIOR_LESSONS=[]" in content, "analyze/SKILL.md must initialize PRIOR_LESSONS to [] as a safe fallback"


def test_analyze_skill_persists_prior_lessons_into_analysis_md() -> None:
    """analyze/SKILL.md must document writing PRIOR_LESSONS into analysis.md."""
    content = _text(ANALYZE_SKILL)
    # The sentinel comment format must be documented so the execute lane can parse it.
    assert "prior_lessons:" in content, "analyze/SKILL.md must document persisting prior_lessons into analysis.md"


# ---------------------------------------------------------------------------
# (b) change-implementer.md Input table + execute/SKILL.md forwarding
# ---------------------------------------------------------------------------


def test_change_implementer_input_table_has_prior_lessons_row() -> None:
    """change-implementer.md Input table must include a PRIOR_LESSONS row."""
    content = _text(CHANGE_IMPLEMENTER)
    assert "PRIOR_LESSONS" in content, "change-implementer.md must have a PRIOR_LESSONS row in the Input table (Task 2)"


def test_change_implementer_prior_lessons_treats_absent_and_empty_identically() -> None:
    """change-implementer.md must state that absent and [] are identical."""
    content = _text(CHANGE_IMPLEMENTER)
    # The wording from coder.md: "Absent key and [] are treated identically (skip)."
    assert re.search(r"[Aa]bsent.{0,30}\[\]", content) or re.search(r"\[\].{0,30}absent", content), "change-implementer.md must document that absent key and [] are treated identically"


def test_execute_skill_forwards_prior_lessons_in_step_2_2() -> None:
    """execute/SKILL.md Step 2.2 dispatch bundle must include PRIOR_LESSONS."""
    content = _text(EXECUTE_SKILL)
    assert "PRIOR_LESSONS" in content, "execute/SKILL.md must forward PRIOR_LESSONS in the change-implementer dispatch bundle (Task 2 / Step 2.2)"


def test_execute_skill_reads_prior_lessons_from_analysis_md_sentinel() -> None:
    """execute/SKILL.md must document reading the sentinel from analysis.md."""
    content = _text(EXECUTE_SKILL)
    assert "prior_lessons:" in content or "analysis.md" in content, "execute/SKILL.md must document reading PRIOR_LESSONS from the analysis.md sentinel"


# ---------------------------------------------------------------------------
# (c) execute/SKILL.md and resolve-review/SKILL.md reference write-lessons.sh
# ---------------------------------------------------------------------------


def test_execute_skill_terminal_step_references_write_lessons() -> None:
    """execute/SKILL.md must reference write-lessons.sh at its terminal step."""
    content = _text(EXECUTE_SKILL)
    assert "write-lessons.sh" in content, "execute/SKILL.md must reference write-lessons.sh at its terminal step (Task 3)"


def test_resolve_review_skill_terminal_step_references_write_lessons() -> None:
    """resolve-review/SKILL.md must reference write-lessons.sh at its terminal step."""
    content = _text(RESOLVE_REVIEW_SKILL)
    assert "write-lessons.sh" in content, "resolve-review/SKILL.md must reference write-lessons.sh at its terminal step (Task 3)"


# ---------------------------------------------------------------------------
# (d) The documented write shape names exactly the 7 required fields
# ---------------------------------------------------------------------------

_REQUIRED_FIELDS = {"ts", "tier", "text", "tags", "scope", "key", "repo"}


def test_write_lessons_shape_names_all_seven_fields_in_execute() -> None:
    """execute/SKILL.md write-lesson call-site prose must name all 7 JSONL fields."""
    content = _text(EXECUTE_SKILL)
    # Extract the section after write-lessons.sh is first mentioned.
    idx = content.find("write-lessons.sh")
    assert idx != -1, "write-lessons.sh reference not found in execute/SKILL.md"
    # Look in a reasonable window around the first mention.
    window = content[idx : idx + 600]
    missing = [f for f in _REQUIRED_FIELDS if f not in window]
    assert not missing, f"execute/SKILL.md write-lessons call-site is missing field documentation: {missing}. All 7 fields (ts, tier, text, tags, scope, key, repo) must be named."


def test_write_lessons_shape_names_all_seven_fields_in_resolve_review() -> None:
    """resolve-review/SKILL.md write-lesson call-site prose must name all 7 JSONL fields."""
    content = _text(RESOLVE_REVIEW_SKILL)
    idx = content.find("write-lessons.sh")
    assert idx != -1, "write-lessons.sh reference not found in resolve-review/SKILL.md"
    window = content[idx : idx + 600]
    missing = [f for f in _REQUIRED_FIELDS if f not in window]
    assert not missing, f"resolve-review/SKILL.md write-lessons call-site is missing field documentation: {missing}. All 7 fields (ts, tier, text, tags, scope, key, repo) must be named."


def test_write_lessons_sh_itself_uses_all_seven_fields() -> None:
    """The shared write-lessons.sh script must reference all 7 record fields."""
    content = _text(WRITE_LESSONS_SH)
    missing = [f for f in _REQUIRED_FIELDS if f'"{f}"' not in content]
    assert not missing, f"write-lessons.sh is missing field references: {missing}. The script must produce a record with exactly the 7 fields the promoter reads."
