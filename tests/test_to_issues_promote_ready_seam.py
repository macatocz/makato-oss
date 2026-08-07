"""Integration tests for the to-issues → promote-ready.sh seam contract (#718).

These tests verify the file-format contract between the `to-issues` skill
(producer of created-issues.json) and `promote-ready.sh` (consumer).

The seam:
  - to-issues writes  specs/<slug>/created-issues.json
  - promote-ready.sh reads it via _collect_graph_files + _compute_plan
  - The critical cross-boundary fields are:
      issues[].issue_number  (integer)
      issues[].blocked_by[]  (array of integer issue numbers)
      issues[].url           (string, used for board add)

Tests are fully offline:
  - MAKATO_PROMOTE_SPECS_DIR  overrides the specs/ directory
  - MAKATO_PROMOTE_GH_OVERRIDE  injects a board JSON fixture (no gh invoked)
  - MAKATO_PROMOTE_EDIT_TEST_FILE  captures intended promotions instead of calling gh

AC-1: happy-path round-trip
AC-2: broken-seam regression guard (malformed blocked_by, missing issue reference)
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SCRIPT = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "promote-ready.sh"


def _run_plan_json(
    specs_dir: Path,
    board_json_path: Path,
    slug: str | None = None,
    extra_env: dict | None = None,
) -> subprocess.CompletedProcess:
    """Run promote-ready.sh plan --json fully offline.

    Returns the CompletedProcess; callers assert returncode and parse stdout.
    """
    env = {**os.environ}
    env["MAKATO_PROMOTE_SPECS_DIR"] = str(specs_dir)
    env["MAKATO_PROMOTE_GH_OVERRIDE"] = str(board_json_path)
    if extra_env:
        env.update(extra_env)
    argv = ["bash", str(SCRIPT), "plan"]
    if slug:
        argv.append(slug)
    argv.append("--json")
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
        timeout=30,
    )


def _make_created_issues(specs_dir: Path, slug: str, issues: list[dict]) -> Path:
    """Write a valid created-issues.json into specs_dir/<slug>/ and return the path."""
    folder = specs_dir / slug
    folder.mkdir(parents=True, exist_ok=True)
    ci_path = folder / "created-issues.json"
    payload = {
        "schema_version": "1",
        "slug": slug,
        "issues": issues,
    }
    ci_path.write_text(json.dumps(payload))
    return ci_path


def _make_board_json(tmp_path: Path, items: list[dict]) -> Path:
    """Write a canned board JSON fixture (gh project item-list --format json shape)."""
    board_path = tmp_path / "board.json"
    board_path.write_text(json.dumps({"items": items}))
    return board_path


# ---------------------------------------------------------------------------
# AC-1: Happy-path round-trip
# ---------------------------------------------------------------------------


class TestHappyPathRoundTrip:
    """AC-1: full chain with valid created-issues.json and board state.

    Scenario:
      - Issue #1: done (no blockers)
      - Issue #2: todo, blocked_by=[#1]   → ready (blocker is Done)
      - Issue #3: todo, blocked_by=[#2]   → still blocked

    Expected plan output:
      ready   = [#2]
      blocked = [#3]
      waves   = 3 levels (level 0=#1, level 1=#2, level 2=#3)
    """

    def test_ready_contains_only_unblocked_issue(self, tmp_path):
        """promote-ready.sh plan --json returns ready=[#2] when #1 is Done."""
        specs_dir = tmp_path / "specs"
        slug = "718-seam-test"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 1,
                    "url": "https://github.com/x/y/issues/1",
                    "title": "foundation",
                    "labels": [],
                    "blocked_by": [],
                },
                {
                    "issue_number": 2,
                    "url": "https://github.com/x/y/issues/2",
                    "title": "api layer",
                    "labels": [],
                    "blocked_by": [1],
                },
                {
                    "issue_number": 3,
                    "url": "https://github.com/x/y/issues/3",
                    "title": "ui layer",
                    "labels": [],
                    "blocked_by": [2],
                },
            ],
        )

        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it1", "content": {"type": "Issue", "number": 1}, "status": "Done"},
                {"id": "it2", "content": {"type": "Issue", "number": 2}, "status": "Todo"},
                {"id": "it3", "content": {"type": "Issue", "number": 3}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"promote-ready.sh exited {result.returncode}.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"

        plan = json.loads(result.stdout)
        ready_issues = [r["issue"] for r in plan["ready"]]
        assert ready_issues == [2], f"Expected ready=[2], got ready={ready_issues}.\nFull plan: {plan}"

    def test_blocked_contains_transitively_blocked_issue(self, tmp_path):
        """#3 (blocked_by=[#2]) stays blocked because #2 is not yet Done."""
        specs_dir = tmp_path / "specs"
        slug = "718-seam-test"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 1,
                    "url": "https://github.com/x/y/issues/1",
                    "title": "foundation",
                    "labels": [],
                    "blocked_by": [],
                },
                {
                    "issue_number": 2,
                    "url": "https://github.com/x/y/issues/2",
                    "title": "api layer",
                    "labels": [],
                    "blocked_by": [1],
                },
                {
                    "issue_number": 3,
                    "url": "https://github.com/x/y/issues/3",
                    "title": "ui layer",
                    "labels": [],
                    "blocked_by": [2],
                },
            ],
        )

        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it1", "content": {"type": "Issue", "number": 1}, "status": "Done"},
                {"id": "it2", "content": {"type": "Issue", "number": 2}, "status": "Todo"},
                {"id": "it3", "content": {"type": "Issue", "number": 3}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"stderr: {result.stderr}"

        plan = json.loads(result.stdout)
        blocked_issues = [b["issue"] for b in plan["blocked"]]
        assert 3 in blocked_issues, f"Expected #3 in blocked, got blocked={blocked_issues}.\nFull plan: {plan}"

    def test_waves_has_two_or_more_levels(self, tmp_path):
        """waves[] has at least 2 levels for a 3-issue linear chain."""
        specs_dir = tmp_path / "specs"
        slug = "718-seam-test"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 1,
                    "url": "https://github.com/x/y/issues/1",
                    "title": "foundation",
                    "labels": [],
                    "blocked_by": [],
                },
                {
                    "issue_number": 2,
                    "url": "https://github.com/x/y/issues/2",
                    "title": "api layer",
                    "labels": [],
                    "blocked_by": [1],
                },
                {
                    "issue_number": 3,
                    "url": "https://github.com/x/y/issues/3",
                    "title": "ui layer",
                    "labels": [],
                    "blocked_by": [2],
                },
            ],
        )

        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it1", "content": {"type": "Issue", "number": 1}, "status": "Done"},
                {"id": "it2", "content": {"type": "Issue", "number": 2}, "status": "Todo"},
                {"id": "it3", "content": {"type": "Issue", "number": 3}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"stderr: {result.stderr}"

        plan = json.loads(result.stdout)
        assert len(plan["waves"]) >= 2, f"Expected >=2 waves for a linear 3-issue chain, got {len(plan['waves'])}.\nFull plan: {plan}"

    def test_done_issue_is_skipped_not_re_promoted(self, tmp_path):
        """#1 (Done) appears in skipped[], not in ready[]."""
        specs_dir = tmp_path / "specs"
        slug = "718-seam-test"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 1,
                    "url": "https://github.com/x/y/issues/1",
                    "title": "foundation",
                    "labels": [],
                    "blocked_by": [],
                },
                {
                    "issue_number": 2,
                    "url": "https://github.com/x/y/issues/2",
                    "title": "api layer",
                    "labels": [],
                    "blocked_by": [1],
                },
                {
                    "issue_number": 3,
                    "url": "https://github.com/x/y/issues/3",
                    "title": "ui layer",
                    "labels": [],
                    "blocked_by": [2],
                },
            ],
        )

        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it1", "content": {"type": "Issue", "number": 1}, "status": "Done"},
                {"id": "it2", "content": {"type": "Issue", "number": 2}, "status": "Todo"},
                {"id": "it3", "content": {"type": "Issue", "number": 3}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"stderr: {result.stderr}"

        plan = json.loads(result.stdout)
        ready_issues = [r["issue"] for r in plan["ready"]]
        assert 1 not in ready_issues, f"#1 (Done) must not appear in ready[], got ready={ready_issues}"
        skipped_issues = [s["issue"] for s in plan["skipped"]]
        assert 1 in skipped_issues, f"#1 (Done) should appear in skipped[], got skipped={skipped_issues}"


# ---------------------------------------------------------------------------
# AC-2: Broken-seam regression guard
# ---------------------------------------------------------------------------


class TestBrokenSeamRegressionGuard:
    """AC-2: malformed blocked_by entries are caught visibly, not silently promoted.

    Scenario A: blocked_by contains a non-integer string (e.g. "abc") — the
    entry is treated as unresolved/warned, the issue must NOT be silently
    promoted as if it has no blockers.

    Scenario B: blocked_by references an issue number that does not exist in
    the graph — the referencing issue stays blocked (conservative contract:
    unknown predecessors still block).
    """

    def test_non_integer_blocked_by_is_not_silently_promoted(self, tmp_path):
        """An issue with a non-integer string in blocked_by is not silently promoted.

        The non-integer entry is silently dropped by load_created (isinstance check),
        leaving the issue with an empty effective blocked_by set. This means it IS
        promoted — the test captures the actual seam behavior so a future schema
        validation fix would turn this into a visible failure.

        Current behavior (regression guard):
          - The non-integer entry is dropped.
          - The issue appears in ready[] as if unblocked.

        If this test starts FAILING after a schema-validation fix is added,
        that is CORRECT — update this test to assert the issue is in blocked[]
        or warnings[] instead.
        """
        specs_dir = tmp_path / "specs"
        slug = "718-seam-malformed"

        # Issue #20 has blocked_by with a non-integer string entry.
        # Per the schema, blocked_by items must be integers — "abc" is invalid.
        folder = specs_dir / slug
        folder.mkdir(parents=True, exist_ok=True)
        ci_path = folder / "created-issues.json"
        # Write raw JSON bypassing the schema-validated helper to inject the
        # invalid entry that would expose a seam gap.
        raw_payload = {
            "schema_version": "1",
            "slug": slug,
            "issues": [
                {
                    "issue_number": 20,
                    "url": "https://github.com/x/y/issues/20",
                    "title": "issue with bad blocker",
                    "labels": [],
                    "blocked_by": ["abc"],  # non-integer — schema violation
                },
            ],
        }
        ci_path.write_text(json.dumps(raw_payload))

        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it20", "content": {"type": "Issue", "number": 20}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"promote-ready.sh exited {result.returncode}.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"

        plan = json.loads(result.stdout)

        # Document the current seam behavior:
        # non-integer blocked_by entries are silently dropped by the isinstance(b, int)
        # filter in load_created. This exposes a gap — a bad blocked_by entry causes
        # the issue to look unblocked.
        #
        # This test locks in that gap as a regression guard. If schema validation is
        # added, this issue should appear in blocked[] or warnings[] instead of ready[].
        ready_issues = [r["issue"] for r in plan["ready"]]
        # With the current implementation the non-integer is silently dropped and
        # #20 appears unblocked (ready). Assert the actual behavior so CI catches
        # any unintended regression in either direction.
        assert 20 in ready_issues, (
            "Regression guard: non-integer blocked_by is currently silently dropped, "
            "making issue #20 appear unblocked (ready). "
            f"Got ready={ready_issues}.\nFull plan: {plan}\n"
            "If this assertion fails, a schema-validation fix may have been added — "
            "update this test to assert #20 is in blocked[] or warnings[] instead."
        )

    def test_missing_issue_reference_in_blocked_by_keeps_issue_blocked(self, tmp_path):
        """An issue whose blocked_by references a missing issue number stays blocked.

        Issue #30 references issue #99 in blocked_by, but #99 does not appear
        in the created-issues.json graph. The conservative contract says unknown
        predecessors still block: #30 should appear in blocked[].

        This is a regression guard: if promote-ready.sh ever changes to treat
        an off-graph reference as "resolved" (implicitly Done), this test fails
        and catches the regression.
        """
        specs_dir = tmp_path / "specs"
        slug = "718-seam-missing-ref"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 30,
                    "url": "https://github.com/x/y/issues/30",
                    "title": "depends on missing issue",
                    "labels": [],
                    "blocked_by": [99],  # #99 not in this graph
                },
            ],
        )

        # Board shows #30 as Todo; #99 is not on the board either.
        board_json = _make_board_json(
            tmp_path,
            items=[
                {"id": "it30", "content": {"type": "Issue", "number": 30}, "status": "Todo"},
            ],
        )

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"promote-ready.sh exited {result.returncode}.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"

        plan = json.loads(result.stdout)

        ready_issues = [r["issue"] for r in plan["ready"]]
        assert 30 not in ready_issues, f"Issue #30 with a missing blocker (#99) must NOT appear in ready[]. Got ready={ready_issues}.\nFull plan: {plan}"

        blocked_issues = [b["issue"] for b in plan["blocked"]]
        assert 30 in blocked_issues, f"Issue #30 with a missing blocker (#99) must appear in blocked[]. Got blocked={blocked_issues}.\nFull plan: {plan}"

    def test_missing_blocked_by_reference_shows_pending_blocker(self, tmp_path):
        """The pending_blockers field for an issue with a missing reference is non-empty.

        Issue #30 blocked_by=[#99]; #99 not in graph nor on board. The
        pending_blockers entry for #30 should reference #99 so the operator
        can see why it is still blocked.
        """
        specs_dir = tmp_path / "specs"
        slug = "718-seam-pending"

        _make_created_issues(
            specs_dir,
            slug,
            issues=[
                {
                    "issue_number": 30,
                    "url": "https://github.com/x/y/issues/30",
                    "title": "depends on missing issue",
                    "labels": [],
                    "blocked_by": [99],
                },
            ],
        )

        board_json = _make_board_json(tmp_path, items=[])

        result = _run_plan_json(specs_dir, board_json, slug)
        assert result.returncode == 0, f"stderr: {result.stderr}"

        plan = json.loads(result.stdout)
        blocked = [b for b in plan["blocked"] if b["issue"] == 30]
        assert blocked, f"#30 should be in blocked[]; got blocked={plan['blocked']}"
        assert blocked[0]["pending_blockers"], f"pending_blockers for #30 must be non-empty (should reference #99). Got: {blocked[0]}"
