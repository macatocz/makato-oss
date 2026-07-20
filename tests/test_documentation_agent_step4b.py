"""Tests for documentation-agent.md write allow-list and Step 4b (updated for #502).

#502 moved lesson promotion out of the GHA post-merge path (documentation-agent
Step 4b) into the po-agent local lane (po-agent Step 6 item 7), because the
gitignored per-issue sources are absent on the runner's fresh checkout. Step 4b
is now a documented no-op and the write allow-list drops `.makato/memory/`.
"""

from pathlib import Path

WORKTREE = Path(__file__).parent.parent
DOC_AGENT = (
    WORKTREE / "plugins" / "makato-orchestrate" / "agents" / "documentation-agent.md"
)
PO_AGENT = WORKTREE / "plugins" / "makato-orchestrate" / "agents" / "po-agent.md"


def test_allow_list_excludes_makato_memory():
    """#502: the write allow-list no longer includes .makato/memory/ (promote moved to po-agent)."""
    content = DOC_AGENT.read_text()
    assert ".makato/memory/procedural.jsonl" not in content, (
        "Allow-list still references .makato/memory/procedural.jsonl — "
        "promotion moved to the po-agent local lane in #502"
    )


def test_step_4b_is_documented_noop():
    """#502: Step 4b remains as a heading but is an explicit no-op — the promote call is gone."""
    content = DOC_AGENT.read_text()
    assert "### Step 4b" in content, "Step 4b heading not found"
    assert "no-op" in content, (
        "Step 4b should document that it is intentionally a no-op"
    )
    # The log events that were emitted by the removed promote invocation must be gone.
    assert "promote_skipped_no_issue" not in content, (
        "promote_skipped_no_issue was tied to the removed Step 4b promote call (#502)"
    )
    assert "promote_lessons_failed" not in content, (
        "promote_lessons_failed was tied to the removed Step 4b promote call (#502)"
    )
    # Ordering preserved: Step 4b must still appear between Step 4a and Step 5.
    idx_4a = content.find("### Step 4a")
    idx_4b = content.find("### Step 4b")
    idx_5 = content.find("### Step 5")
    assert idx_4a < idx_4b < idx_5, (
        f"Step ordering wrong: 4a@{idx_4a}, 4b@{idx_4b}, 5@{idx_5}"
    )


def test_allow_list_count_is_four():
    """#502: allow-list reverts to four paths (the .makato/memory entry was removed)."""
    content = DOC_AGENT.read_text()
    assert "four\n" in content or "four " in content, (
        "Allow-list header should say 'four' after removing the .makato/memory entry"
    )


def test_po_agent_success_terminal_promotes_lessons():
    """#502: po-agent success terminal (Step 6 item 7) runs promote-lessons.sh in the local lane."""
    content = PO_AGENT.read_text()
    assert "promote-lessons.sh" in content, (
        "po-agent.md must reference promote-lessons.sh — the local-lane promotion hook (#502)"
    )
    assert "git rev-parse --git-common-dir" in content, (
        "po-agent promote must resolve the main checkout via git-common-dir so it reads "
        "the same specs/ store write-lessons.sh writes to"
    )
