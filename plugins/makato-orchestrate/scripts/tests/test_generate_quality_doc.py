"""Tests for generate_quality_doc.py — per-domain quality scorecard (#598).

Mirrors generate-quality-doc-smoke-tests.sh scenarios T1–T6.
Stdlib-only + pytest. Run from repo root:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_generate_quality_doc.py -v
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

from generate_quality_doc import (  # noqa: E402,I001
    aggregate_build_jsonl,
    aggregate_halt,
    build_scorecard_block,
    detect_domain,
    generate_quality_doc,
    update_or_create_scorecard,
)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

def _make_issue_folder(specs_dir: str, base: str, domain: str) -> str:
    """Create an issue folder with a plan.md declaring the given domain."""
    folder = os.path.join(specs_dir, base)
    os.makedirs(folder, exist_ok=True)
    plan = os.path.join(folder, "plan.md")
    with open(plan, "w") as fh:
        fh.write(f"# Test plan\ndomain: {domain}\n\n## Tasks\n- task one\n")
    return folder


def _write_build_jsonl(folder: str, tests_passing: int, sensor_findings: int) -> None:
    """Write a build.jsonl with test + sensor entries."""
    lines = [
        json.dumps({
            "ts": "2026-08-01T10:00:00.000Z",
            "skill": "build-implement-tdd",
            "step": "task",
            "status": "green",
            "data": {"tests_passing": tests_passing},
        }),
        json.dumps({
            "ts": "2026-08-01T10:05:00.000Z",
            "skill": "build-sensors",
            "step": "gate-sensors",
            "status": "ok",
            "data": {"findings": sensor_findings},
        }),
    ]
    with open(os.path.join(folder, "build.jsonl"), "w") as fh:
        fh.write("\n".join(lines) + "\n")


def _write_workflow_state(folder: str, issue: int, halt_audit: list) -> None:
    """Write a workflow-state-<issue>.json with halt_audit."""
    data = {
        "issue_number": issue,
        "current_phase": "done",
        "github_pr_number": 99,
        "halt_audit": halt_audit,
    }
    with open(os.path.join(folder, f"workflow-state-{issue}.json"), "w") as fh:
        json.dump(data, fh)


# ---------------------------------------------------------------------------
# T1: No issues in domain → empty table body, exit 0
# ---------------------------------------------------------------------------

class TestT1NoDomainIssues:
    """T1: No issues in domain → scorecard written with empty table body, exit 0."""

    def test_empty_domain_creates_scorecard(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        _make_issue_folder(specs_dir, "100-other-domain", "other")

        rc = generate_quality_doc("t1test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t1test-quality.md")
        assert os.path.isfile(master)
        content = open(master).read()
        # No data rows (no | #<N> | lines).
        data_rows = [row for row in content.splitlines() if row.startswith("| #")]
        assert data_rows == [], f"Expected no data rows, got: {data_rows}"


# ---------------------------------------------------------------------------
# T2: tests_passing=42, findings=0, no halts → 42/Yes/0/-/0
# ---------------------------------------------------------------------------

class TestT2FullMetrics:
    """T2: Single issue with full metrics → row shows 42/Yes/0/-/0."""

    def test_metrics_row(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        folder = _make_issue_folder(specs_dir, "200-feat-alpha", "t2test")
        _write_build_jsonl(folder, 42, 0)
        _write_workflow_state(folder, 200, [])

        rc = generate_quality_doc("t2test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t2test-quality.md")
        content = open(master).read()
        rows = [row for row in content.splitlines() if row.startswith("| #200")]
        assert rows, "Row for #200 not found"
        row = rows[0]
        assert "| 42 |" in row, f"tests_passing should be 42; row: {row}"
        assert "| Yes |" in row, f"sensor_clean should be Yes; row: {row}"
        assert "| 0 | - | 0 |" in row, f"HALTs=0, last=-, struct=0 expected; row: {row}"


# ---------------------------------------------------------------------------
# T3: gate-sensors findings=3 → sensor_clean = No
# ---------------------------------------------------------------------------

class TestT3SensorFindings:
    """T3: findings=3 → sensor_clean=No."""

    def test_sensor_no(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        folder = _make_issue_folder(specs_dir, "300-feat-beta", "t3test")
        _write_build_jsonl(folder, 5, 3)
        _write_workflow_state(folder, 300, [])

        rc = generate_quality_doc("t3test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t3test-quality.md")
        content = open(master).read()
        rows = [row for row in content.splitlines() if row.startswith("| #300")]
        assert rows, "Row for #300 not found"
        row = rows[0]
        assert "| No |" in row, f"sensor_clean should be No; row: {row}"


# ---------------------------------------------------------------------------
# T4: two halt_audit entries → HALTs=2, Last HALT=HALT-003
# ---------------------------------------------------------------------------

class TestT4HaltAudit:
    """T4: Two halt_audit entries → HALTs=2, Last HALT=HALT-003."""

    def test_halt_counts(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        folder = _make_issue_folder(specs_dir, "400-feat-gamma", "t4test")
        _write_build_jsonl(folder, 10, 0)
        _write_workflow_state(folder, 400, [
            {"code": "HALT-007", "ts": "2026-08-01T11:00:00.000Z"},
            {"code": "HALT-003", "ts": "2026-08-01T12:00:00.000Z"},
        ])

        rc = generate_quality_doc("t4test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t4test-quality.md")
        content = open(master).read()
        rows = [row for row in content.splitlines() if row.startswith("| #400")]
        assert rows, "Row for #400 not found"
        row = rows[0]
        assert "| 2 |" in row, f"HALTs should be 2; row: {row}"
        assert "HALT-003" in row, f"Last HALT should be HALT-003; row: {row}"


# ---------------------------------------------------------------------------
# T5: Re-run preserves Evolution Log, updates scorecard without duplication
# ---------------------------------------------------------------------------

class TestT5EvolutionLogPreserved:
    """T5: Re-run preserves Evolution Log section, updates scorecard, no duplication."""

    def test_evolution_log_preserved(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        folder = _make_issue_folder(specs_dir, "500-feat-delta", "t5test")
        _write_build_jsonl(folder, 7, 0)
        _write_workflow_state(folder, 500, [])

        # First run.
        rc = generate_quality_doc("t5test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t5test-quality.md")

        # Inject Evolution Log section.
        with open(master, "a") as fh:
            fh.write(
                "\n## Evolution Log\n\n"
                "| Date | Story | Action |\n"
                "|------|-------|--------|\n"
                "| 2026-08-01 | 500-feat-delta | archived |\n"
            )

        # Second run with updated metrics.
        _write_build_jsonl(folder, 99, 0)
        rc = generate_quality_doc("t5test", specs_dir)
        assert rc == 0

        content = open(master).read()
        assert "## Evolution Log" in content, "Evolution Log was destroyed"

        # Exactly one data row (no duplication).
        data_rows = [row for row in content.splitlines() if row.startswith("| #500")]
        assert len(data_rows) == 1, f"Expected 1 data row, got {len(data_rows)}"

        # Row reflects updated tests_passing=99.
        row = data_rows[0]
        assert "| 99 |" in row, f"Scorecard should show updated tests_passing=99; row: {row}"


# ---------------------------------------------------------------------------
# T6: build.jsonl absent → all metrics dash, exit 0
# ---------------------------------------------------------------------------

class TestT6MissingBuildJsonl:
    """T6: Absent build.jsonl → all metrics dash, exit 0."""

    def test_absent_build_jsonl_dash_metrics(self, tmp_path):
        specs_dir = str(tmp_path / "specs")
        folder = _make_issue_folder(specs_dir, "600-feat-epsilon", "t6test")
        # No build.jsonl, but workflow-state present.
        _write_workflow_state(folder, 600, [])

        rc = generate_quality_doc("t6test", specs_dir)
        assert rc == 0
        master = os.path.join(specs_dir, "master", "t6test-quality.md")
        assert os.path.isfile(master)
        content = open(master).read()
        rows = [row for row in content.splitlines() if row.startswith("| #600")]
        assert rows, "Row for #600 not found"
        row = rows[0]
        # Dash for tests_passing and sensor_clean (build-derived).
        assert "| - | - |" in row, f"Missing build.jsonl should produce - cells; row: {row}"


# ---------------------------------------------------------------------------
# Unit tests for individual functions
# ---------------------------------------------------------------------------

class TestDetectDomain:
    """Unit tests for detect_domain."""

    def test_reads_domain_from_plan_md(self, tmp_path):
        folder = str(tmp_path)
        with open(os.path.join(folder, "plan.md"), "w") as fh:
            fh.write("# Plan\ndomain: orchestrate\n")
        assert detect_domain(folder) == "orchestrate"

    def test_reads_domain_from_spec_md_when_no_plan(self, tmp_path):
        folder = str(tmp_path)
        with open(os.path.join(folder, "spec.md"), "w") as fh:
            fh.write("domain: build\n")
        assert detect_domain(folder) == "build"

    def test_defaults_to_general_when_absent(self, tmp_path):
        assert detect_domain(str(tmp_path)) == "general"

    def test_defaults_to_general_when_no_domain_line(self, tmp_path):
        folder = str(tmp_path)
        with open(os.path.join(folder, "plan.md"), "w") as fh:
            fh.write("# Plan\n## Tasks\n- do something\n")
        assert detect_domain(folder) == "general"


class TestAggregateBuildJsonl:
    """Unit tests for aggregate_build_jsonl."""

    def test_absent_file_returns_dashes(self, tmp_path):
        tp, sc, sf = aggregate_build_jsonl(str(tmp_path / "build.jsonl"))
        assert tp == "-"
        assert sc == "-"
        assert sf == 0

    def test_parses_tests_passing_from_green_entry(self, tmp_path):
        build_file = str(tmp_path / "build.jsonl")
        with open(build_file, "w") as fh:
            fh.write(json.dumps({"status": "green", "data": {"tests_passing": 17}}) + "\n")
        tp, _, _ = aggregate_build_jsonl(build_file)
        assert tp == "17"

    def test_sensor_clean_yes_when_findings_zero(self, tmp_path):
        build_file = str(tmp_path / "build.jsonl")
        with open(build_file, "w") as fh:
            fh.write(json.dumps({"step": "gate-sensors", "data": {"findings": 0}}) + "\n")
        _, sc, _ = aggregate_build_jsonl(build_file)
        assert sc == "Yes"

    def test_sensor_clean_no_when_findings_nonzero(self, tmp_path):
        build_file = str(tmp_path / "build.jsonl")
        with open(build_file, "w") as fh:
            fh.write(json.dumps({"step": "gate-sensors", "data": {"findings": 5}}) + "\n")
        _, sc, _ = aggregate_build_jsonl(build_file)
        assert sc == "No"

    def test_structural_failures_counted(self, tmp_path):
        build_file = str(tmp_path / "build.jsonl")
        entries = [
            {"skill": "build-verify", "status": "error", "data": {}},
            {"step": "build-verify", "status": "ok", "data": {"all_gates_passed": False}},
            {"skill": "build-verify", "status": "ok", "data": {"all_gates_passed": True}},
        ]
        with open(build_file, "w") as fh:
            for e in entries:
                fh.write(json.dumps(e) + "\n")
        _, _, sf = aggregate_build_jsonl(build_file)
        assert sf == 2


class TestAggregateHalt:
    """Unit tests for aggregate_halt."""

    def test_absent_state_file_returns_zero_dash(self, tmp_path):
        count, last = aggregate_halt(str(tmp_path), "999")
        assert count == 0
        assert last == "-"

    def test_reads_halt_count_and_last_code(self, tmp_path):
        folder = str(tmp_path)
        state = {
            "halt_audit": [
                {"code": "HALT-001"},
                {"code": "HALT-003"},
            ]
        }
        with open(os.path.join(folder, "workflow-state-42.json"), "w") as fh:
            json.dump(state, fh)
        count, last = aggregate_halt(folder, "42")
        assert count == 2
        assert last == "HALT-003"

    def test_empty_halt_audit_returns_zero_dash(self, tmp_path):
        folder = str(tmp_path)
        state = {"halt_audit": []}
        with open(os.path.join(folder, "workflow-state-1.json"), "w") as fh:
            json.dump(state, fh)
        count, last = aggregate_halt(folder, "1")
        assert count == 0
        assert last == "-"


class TestUpdateOrCreateScorecard:
    """Unit tests for update_or_create_scorecard."""

    def test_creates_new_file(self, tmp_path):
        output_file = str(tmp_path / "quality.md")
        update_or_create_scorecard(output_file, "## Quality Scorecard\n\ntable\n\n_Last updated: ts_")
        assert os.path.isfile(output_file)
        assert "## Quality Scorecard" in open(output_file).read()

    def test_replaces_section_in_existing_file(self, tmp_path):
        output_file = str(tmp_path / "quality.md")
        initial = "# Header\n\n## Quality Scorecard\n\nold table\n\n_Last updated: old_\n"
        with open(output_file, "w") as fh:
            fh.write(initial)
        update_or_create_scorecard(output_file, "## Quality Scorecard\n\nnew table\n\n_Last updated: new_")
        content = open(output_file).read()
        assert "new table" in content
        assert "old table" not in content

    def test_preserves_content_after_section(self, tmp_path):
        output_file = str(tmp_path / "quality.md")
        initial = (
            "## Quality Scorecard\n\nold table\n\n_Last updated: old_\n\n"
            "## Evolution Log\n\nlog content here\n"
        )
        with open(output_file, "w") as fh:
            fh.write(initial)
        update_or_create_scorecard(output_file, "## Quality Scorecard\n\nnew table\n\n_Last updated: new_")
        content = open(output_file).read()
        assert "## Evolution Log" in content
        assert "log content here" in content
        assert "new table" in content


class TestBuildScorecardBlock:
    """Unit tests for build_scorecard_block."""

    def test_block_structure(self):
        block = build_scorecard_block("orchestrate", [], "2026-01-01T00:00:00.000Z")
        assert "## Quality Scorecard" in block
        assert "| Issue | Story |" in block
        assert "_Last updated: 2026-01-01T00:00:00.000Z" in block

    def test_rows_included(self):
        rows = ["| #1 | foo | 10 | Yes | 0 | - | 0 |"]
        block = build_scorecard_block("build", rows, "2026-01-01T00:00:00.000Z")
        assert "| #1 |" in block
