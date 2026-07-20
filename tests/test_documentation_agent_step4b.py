"""RED→GREEN tests for Task 3: documentation-agent.md write allow-list and Step 4b."""
from pathlib import Path

WORKTREE = Path(__file__).parent.parent
DOC_AGENT = WORKTREE / "plugins" / "makato-orchestrate" / "agents" / "documentation-agent.md"


def test_allow_list_includes_makato_memory():
    """AC-7: documentation-agent.md write allow-list includes .makato/memory/."""
    content = DOC_AGENT.read_text()
    assert ".makato/memory/procedural.jsonl" in content, (
        "Allow-list entry for .makato/memory/procedural.jsonl not found in documentation-agent.md"
    )
    assert "promote step only; append/dedup, never truncate" in content, (
        "Expected constraint annotation missing from allow-list entry"
    )


def test_step_4b_present():
    """AC-8: documentation-agent.md includes Step 4b after Step 4a, before Step 5."""
    content = DOC_AGENT.read_text()
    assert "### Step 4b" in content, "Step 4b heading not found"
    assert "promote-lessons.sh" in content, "promote-lessons.sh not referenced in Step 4b"
    assert "promote_skipped_no_issue" in content, "promote_skipped_no_issue log event missing"
    assert "promote_lessons_failed" in content, "promote_lessons_failed log event missing"
    # Ordering: Step 4b must appear between Step 4a and Step 5
    idx_4a = content.find("### Step 4a")
    idx_4b = content.find("### Step 4b")
    idx_5 = content.find("### Step 5")
    assert idx_4a < idx_4b < idx_5, (
        f"Step ordering wrong: 4a@{idx_4a}, 4b@{idx_4b}, 5@{idx_5}"
    )


def test_allow_list_count_is_five():
    """Allow-list now lists five paths (was four)."""
    content = DOC_AGENT.read_text()
    assert "five" in content, "Allow-list header still says 'four' — expected 'five'"
