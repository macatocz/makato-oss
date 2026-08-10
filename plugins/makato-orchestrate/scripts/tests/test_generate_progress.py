"""Tests for generate_progress.py — PROGRESS.md roadmap generator (#601).

Mirrors generate-progress-smoke-tests.sh scenarios T1–T6.
Stdlib-only + pytest. Run from repo root:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_generate_progress.py -v
"""

from __future__ import annotations

import json
import os
import sys

# Allow imports from scripts/ directory.
_SCRIPTS = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..")
)
if _SCRIPTS not in sys.path:
    sys.path.insert(0, _SCRIPTS)

from generate_progress import (  # noqa: E402,I001
    build_progress_md,
    classify_epics,
    read_loop_status,
    run,
)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

def _write_loop_status(state_dir: str, active: int | None, queue: list[int]) -> None:
    """Write a minimal loop-status.json fixture."""
    aw = None
    if active is not None:
        aw = {"issue": active, "started_at": "2026-08-01T10:00:00.000Z", "stalled": False}
    data = {
        "active_workflow": aw,
        "queue": queue,
        "updated_at": "2026-08-01T10:00:00.000Z",
    }
    os.makedirs(state_dir, exist_ok=True)
    with open(os.path.join(state_dir, "loop-status.json"), "w") as fh:
        json.dump(data, fh)


def _epics_file(sandbox: str, name: str, epics: list[dict]) -> str:
    """Write a JSON epics fixture file and return its path."""
    path = os.path.join(sandbox, name)
    with open(path, "w") as fh:
        json.dump(epics, fh)
    return path


# ---------------------------------------------------------------------------
# T1: No epics found → all sections empty-placeholder but present; exit 0
# ---------------------------------------------------------------------------

class TestT1NoEpics:
    """T1: No epics found — all sections present with placeholder text."""

    def test_all_sections_present_exit_0(self, tmp_path):
        state_dir = str(tmp_path / "state")
        out_file = str(tmp_path / "PROGRESS.md")
        gh_override = _epics_file(str(tmp_path), "epics.json", [])
        _write_loop_status(state_dir, None, [])

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=gh_override,
            out_file=out_file,
        )
        assert rc == 0
        assert os.path.isfile(out_file)
        content = open(out_file).read()
        assert "## Done" in content
        assert "## In Progress" in content
        assert "## Not Started" in content
        # At least one empty-placeholder line.
        assert any(phrase in content for phrase in [
            "_No closed epics found._",
            "_No epics currently in progress._",
            "_No open epics outside the loop queue._",
        ])
        assert "Last updated:" in content


# ---------------------------------------------------------------------------
# T2: Single closed epic → appears under ## Done
# ---------------------------------------------------------------------------

class TestT2ClosedEpic:
    """T2: Single closed epic → classified under Done."""

    def test_closed_epic_under_done(self, tmp_path):
        state_dir = str(tmp_path / "state")
        out_file = str(tmp_path / "PROGRESS.md")
        epics = [
            {"number": 42, "title": "Epic: Roadmap foundation", "state": "CLOSED", "closedAt": "2026-07-20T12:00:00Z"}
        ]
        gh_override = _epics_file(str(tmp_path), "epics.json", epics)
        _write_loop_status(state_dir, None, [])

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=gh_override,
            out_file=out_file,
        )
        assert rc == 0
        content = open(out_file).read()
        assert "#42" in content
        assert "Epic: Roadmap foundation" in content

        # Must be under ## Done section.
        done_start = content.find("## Done")
        assert done_start != -1
        done_section = content[done_start:]
        assert "#42" in done_section

        # Must NOT be under In Progress.
        ip_start = content.find("## In Progress")
        ns_start = content.find("## Not Started")
        assert ip_start != -1 and ns_start != -1
        ip_section = content[ip_start:ns_start]
        assert "#42" not in ip_section


# ---------------------------------------------------------------------------
# T3: Active workflow issue → ## In Progress
# ---------------------------------------------------------------------------

class TestT3ActiveWorkflowIssue:
    """T3: Open epic matching active_workflow.issue → In Progress."""

    def test_active_epic_under_in_progress(self, tmp_path):
        state_dir = str(tmp_path / "state")
        out_file = str(tmp_path / "PROGRESS.md")
        epics = [{"number": 55, "title": "Epic: Auth overhaul", "state": "OPEN", "closedAt": None}]
        gh_override = _epics_file(str(tmp_path), "epics.json", epics)
        _write_loop_status(state_dir, 55, [])

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=gh_override,
            out_file=out_file,
        )
        assert rc == 0
        content = open(out_file).read()
        assert "#55" in content

        ip_start = content.find("## In Progress")
        ns_start = content.find("## Not Started")
        assert ip_start != -1 and ns_start != -1
        ip_section = content[ip_start:ns_start]
        assert "#55" in ip_section


# ---------------------------------------------------------------------------
# T4: Open epic not in loop queue → ## Not Started
# ---------------------------------------------------------------------------

class TestT4NotStartedEpic:
    """T4: Open epic not in loop queue → Not Started."""

    def test_unqueued_epic_under_not_started(self, tmp_path):
        state_dir = str(tmp_path / "state")
        out_file = str(tmp_path / "PROGRESS.md")
        epics = [{"number": 99, "title": "Epic: Future work", "state": "OPEN", "closedAt": None}]
        gh_override = _epics_file(str(tmp_path), "epics.json", epics)
        _write_loop_status(state_dir, None, [])

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=gh_override,
            out_file=out_file,
        )
        assert rc == 0
        content = open(out_file).read()
        assert "#99" in content

        ns_start = content.find("## Not Started")
        done_start = content.find("## Done")
        assert ns_start != -1 and done_start != -1
        ns_section = content[ns_start:done_start]
        assert "#99" in ns_section


# ---------------------------------------------------------------------------
# T5: loop-status.json absent → falls back to gh data alone; exits 0
# ---------------------------------------------------------------------------

class TestT5MissingLoopStatus:
    """T5: Absent loop-status.json → graceful fallback, warning comment, exit 0."""

    def test_absent_loop_status_graceful(self, tmp_path):
        state_dir = str(tmp_path / "state")
        os.makedirs(state_dir, exist_ok=True)
        # Do NOT write loop-status.json
        out_file = str(tmp_path / "PROGRESS.md")
        epics = [{"number": 77, "title": "Epic: Standalone", "state": "OPEN", "closedAt": None}]
        gh_override = _epics_file(str(tmp_path), "epics.json", epics)

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=gh_override,
            out_file=out_file,
        )
        assert rc == 0
        assert os.path.isfile(out_file)
        content = open(out_file).read()
        assert "## Done" in content
        assert "## In Progress" in content
        assert "## Not Started" in content
        assert "#77" in content
        # Warning comment must appear.
        assert "PROGRESS.md generation warning:" in content


# ---------------------------------------------------------------------------
# T6: gh unavailable → PROGRESS.md written with warning; exits 0
# ---------------------------------------------------------------------------

class TestT6GhUnavailable:
    """T6: gh CLI unavailable → PROGRESS.md written with warning comment, exit 0."""

    def test_no_gh_override_missing_file(self, tmp_path):
        """Passing a non-existent gh override triggers the warning path."""
        state_dir = str(tmp_path / "state")
        _write_loop_status(state_dir, None, [])
        out_file = str(tmp_path / "PROGRESS.md")
        non_existent = str(tmp_path / "does-not-exist.json")

        rc = run(
            repo_root=str(tmp_path),
            state_dir=state_dir,
            gh_override=non_existent,
            out_file=out_file,
        )
        assert rc == 0
        assert os.path.isfile(out_file)
        content = open(out_file).read()
        assert "PROGRESS.md generation warning:" in content
        assert "## Done" in content
        assert "## In Progress" in content
        assert "## Not Started" in content
        assert "Last updated:" in content


# ---------------------------------------------------------------------------
# Unit tests for individual functions
# ---------------------------------------------------------------------------

class TestReadLoopStatus:
    """Unit tests for read_loop_status."""

    def test_missing_file_returns_empty_with_warning(self, tmp_path):
        state_dir = str(tmp_path / "state")
        os.makedirs(state_dir)
        active, queue, warnings = read_loop_status(os.path.join(state_dir, "loop-status.json"))
        assert active == ""
        assert queue == []
        assert len(warnings) == 1
        assert "absent" in warnings[0]

    def test_parses_active_and_queue(self, tmp_path):
        state_dir = str(tmp_path / "state")
        _write_loop_status(state_dir, 42, [10, 20])
        active, queue, warnings = read_loop_status(os.path.join(state_dir, "loop-status.json"))
        assert active == "42"
        assert set(queue) == {10, 20}
        assert warnings == []

    def test_null_active_workflow(self, tmp_path):
        state_dir = str(tmp_path / "state")
        data = {"active_workflow": None, "queue": [], "updated_at": "2026-01-01T00:00:00.000Z"}
        os.makedirs(state_dir, exist_ok=True)
        with open(os.path.join(state_dir, "loop-status.json"), "w") as fh:
            json.dump(data, fh)
        active, queue, warnings = read_loop_status(os.path.join(state_dir, "loop-status.json"))
        assert active == ""
        assert queue == []


class TestClassifyEpics:
    """Unit tests for classify_epics."""

    def test_closed_epic_goes_to_done(self):
        epics = [{"number": 1, "title": "Done epic", "state": "CLOSED", "closedAt": "2026-01-01"}]
        done, ip, ns = classify_epics(epics, "", [])
        assert len(done) == 1
        assert "#1" in done[0]
        assert ip == []
        assert ns == []

    def test_active_issue_goes_to_in_progress(self):
        epics = [{"number": 5, "title": "Active epic", "state": "OPEN", "closedAt": None}]
        done, ip, ns = classify_epics(epics, "5", [])
        assert len(ip) == 1
        assert "#5" in ip[0]
        assert done == []
        assert ns == []

    def test_queue_item_goes_to_in_progress(self):
        epics = [{"number": 7, "title": "Queued epic", "state": "OPEN", "closedAt": None}]
        done, ip, ns = classify_epics(epics, "", [7])
        assert len(ip) == 1
        assert "#7" in ip[0]

    def test_unqueued_open_goes_to_not_started(self):
        epics = [{"number": 99, "title": "Future epic", "state": "OPEN", "closedAt": None}]
        done, ip, ns = classify_epics(epics, "", [])
        assert len(ns) == 1
        assert "#99" in ns[0]

    def test_empty_epics(self):
        done, ip, ns = classify_epics([], "5", [1, 2])
        assert done == []
        assert ip == []
        assert ns == []


class TestBuildProgressMd:
    """Unit tests for build_progress_md."""

    def test_structure_has_all_sections(self):
        content = build_progress_md([], [], [], [], "2026-01-01T00:00:00.000Z")
        assert "## In Progress" in content
        assert "## Not Started" in content
        assert "## Done" in content
        assert "Last updated:" in content
        assert "2026-01-01T00:00:00.000Z" in content

    def test_warning_comment_appears_before_heading(self):
        content = build_progress_md([], [], [], ["some warning"], "2026-01-01T00:00:00.000Z")
        warning_pos = content.find("<!-- PROGRESS.md generation warning: some warning -->")
        heading_pos = content.find("# Roadmap Progress")
        assert warning_pos != -1
        assert warning_pos < heading_pos

    def test_entries_appear_in_correct_sections(self):
        done = ["- **[Done epic](#1)** (#1)"]
        ip = ["- **[Active epic](#5)** (#5)"]
        ns = ["- **[Future epic](#99)** (#99)"]
        content = build_progress_md(done, ip, ns, [], "2026-01-01T00:00:00.000Z")
        ip_start = content.find("## In Progress")
        ns_start = content.find("## Not Started")
        done_start = content.find("## Done")
        assert content.find("#5") > ip_start
        assert content.find("#99") > ns_start
        assert content.find("#1") > done_start

    def test_placeholder_for_empty_done(self):
        content = build_progress_md([], [], [], [], "2026-01-01T00:00:00.000Z")
        assert "_No closed epics found._" in content

    def test_placeholder_for_empty_in_progress(self):
        content = build_progress_md([], [], [], [], "2026-01-01T00:00:00.000Z")
        assert "_No epics currently in progress._" in content

    def test_placeholder_for_empty_not_started(self):
        content = build_progress_md([], [], [], [], "2026-01-01T00:00:00.000Z")
        assert "_No open epics outside the loop queue._" in content
