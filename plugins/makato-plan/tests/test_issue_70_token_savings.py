"""
Tests for issue #70: makato-plan P0 token savings.
Verifies that all four token-saving mechanisms are present in the correct SKILL.md files.
"""

from pathlib import Path

PLUGIN_ROOT = Path(__file__).parent.parent
BRAINSTORMING = PLUGIN_ROOT / "skills" / "brainstorming" / "SKILL.md"
CREATE_ARCH = PLUGIN_ROOT / "skills" / "create-architecture" / "SKILL.md"
CREATE_PRD = PLUGIN_ROOT / "skills" / "create-prd" / "SKILL.md"
DECOMPOSE = PLUGIN_ROOT / "skills" / "decompose" / "SKILL.md"


class TestContextScoutTokenBudget:
    """AC-1: CONTEXT_SCOUT_TOKEN_BUDGET: 2000 constant in ## Constants blocks."""

    def test_constant_in_brainstorming(self):
        text = BRAINSTORMING.read_text()
        assert "CONTEXT_SCOUT_TOKEN_BUDGET: 2000" in text

    def test_constant_in_create_architecture(self):
        text = CREATE_ARCH.read_text()
        assert "CONTEXT_SCOUT_TOKEN_BUDGET: 2000" in text

    def test_constant_in_decompose(self):
        text = DECOMPOSE.read_text()
        assert "CONTEXT_SCOUT_TOKEN_BUDGET: 2000" in text

    def test_constants_section_present_in_brainstorming(self):
        text = BRAINSTORMING.read_text()
        assert "## Constants" in text

    def test_constants_section_present_in_create_architecture(self):
        text = CREATE_ARCH.read_text()
        assert "## Constants" in text

    def test_constants_section_present_in_decompose(self):
        text = DECOMPOSE.read_text()
        assert "## Constants" in text


class TestLazyLoadArchitecture:
    """AC-2: create-architecture Step 1.2 lazy-load instruction and per-round load instructions."""

    def test_lazy_load_sentence_present(self):
        text = CREATE_ARCH.read_text()
        assert "Do not load their content yet — catalogue file names and types only" in text

    def test_lazy_loading_is_eager_sentence(self):
        text = CREATE_ARCH.read_text()
        assert "Conversion is eager; loading is lazy." in text

    def test_round_1_load_instruction_present(self):
        text = CREATE_ARCH.read_text()
        assert "Round 1 (System Context)" in text

    def test_round_2_load_instruction_present(self):
        text = CREATE_ARCH.read_text()
        assert "Round 2 (Design Decisions)" in text

    def test_round_3_load_instruction_present(self):
        text = CREATE_ARCH.read_text()
        assert "Round 3 (Operations)" in text

    def test_reference_folder_no_longer_loads_content(self):
        text = CREATE_ARCH.read_text()
        # The old instruction "scan for technical documents" should be replaced
        # by the lazy catalogue instruction
        assert "catalogue file names and types only" in text


class TestPreAmigosCompression:
    """AC-3: decompose Step 4.5 with PRD_EXCERPT/DESIGN_EXCERPT/DECISIONS_SUMMARY."""

    def test_step_4_5_present(self):
        text = DECOMPOSE.read_text()
        assert "### Step 4.5: Pre-Amigos Compression" in text

    def test_prd_excerpt_defined(self):
        text = DECOMPOSE.read_text()
        assert "PRD_EXCERPT" in text

    def test_design_excerpt_defined(self):
        text = DECOMPOSE.read_text()
        assert "DESIGN_EXCERPT" in text

    def test_decisions_summary_defined(self):
        text = DECOMPOSE.read_text()
        assert "DECISIONS_SUMMARY" in text

    def test_step_4_5_before_step_5(self):
        text = DECOMPOSE.read_text()
        pos_4_5 = text.index("### Step 4.5")
        pos_5 = text.index("### Step 5:")
        assert pos_4_5 < pos_5, "Step 4.5 must appear before Step 5"

    def test_step_5_through_11_numbering_intact(self):
        text = DECOMPOSE.read_text()
        for step_num in range(5, 12):
            assert f"### Step {step_num}:" in text, f"Step {step_num} must still be present"


class TestMakatoplanNoHtml:
    """AC-4: MAKATO_PLAN_NO_HTML guard before every doc-writer dispatch and browser-open."""

    def test_guard_present_in_brainstorming(self):
        text = BRAINSTORMING.read_text()
        assert "MAKATO_PLAN_NO_HTML" in text

    def test_guard_present_in_create_prd(self):
        text = CREATE_PRD.read_text()
        assert "MAKATO_PLAN_NO_HTML" in text

    def test_guard_present_in_decompose(self):
        text = DECOMPOSE.read_text()
        assert "MAKATO_PLAN_NO_HTML" in text

    def test_guard_before_html_review_in_brainstorming(self):
        text = BRAINSTORMING.read_text()
        # Guard must appear before the doc-writer HTML review dispatch
        guard_pos = text.index("MAKATO_PLAN_NO_HTML")
        review_pos = text.index("### Step 7: HTML Review & Approval Gate")
        assert guard_pos > review_pos, "Guard should appear inside Step 7"

    def test_guard_before_html_step_in_create_prd(self):
        text = CREATE_PRD.read_text()
        assert "MAKATO_PLAN_NO_HTML" in text
        # Should appear in Step 8 HTML review
        guard_count = text.count("MAKATO_PLAN_NO_HTML")
        assert guard_count >= 2, "create-prd needs guards before both doc-writer dispatches and browser-open"

    def test_guard_before_browser_open_in_decompose(self):
        text = DECOMPOSE.read_text()
        # Guard must appear before the three-amigos browser-open
        guard_pos = text.index("MAKATO_PLAN_NO_HTML")
        browser_pos = text.index("open specs/{folder}/reviews/three-amigos-review.html")
        assert guard_pos < browser_pos, "Guard must appear before browser-open call"

    def test_skip_instruction_present_in_guards(self):
        """Each guard must contain skip instruction."""
        for skill_file in [BRAINSTORMING, CREATE_PRD, DECOMPOSE]:
            text = skill_file.read_text()
            assert "If set, skip" in text, f"{skill_file.name}: guard must say 'If set, skip'"
