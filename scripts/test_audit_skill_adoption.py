"""Unit tests for audit-skill-adoption.py.

Run from repo root:
    python3 -m pytest scripts/test_audit_skill_adoption.py -v

Mirrors the test_skill_routing.py precedent — Path(__file__).parent.resolve()
for module discovery, unittest.TestCase with tempfile.mkdtemp(), if __name__
guard.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))


# Import the module under test — will raise ImportError if it doesn't exist,
# which is the expected RED state.
import audit_skill_adoption as _mod  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_REQUIRED_FIELDS = [
    "ts",
    "session_id",
    "agent_id",
    "agent_name",
    "parent_agent_id",
    "task_id",
    "skill",
    "plugin",
    "event",
]


def _make_valid_line(**overrides) -> str:
    """Return a JSON-encoded D31-valid JSONL line."""
    entry = {
        "ts": "2026-07-08T10:00:00Z",
        "session_id": "sess-1",
        "agent_id": "agent-1",
        "agent_name": "coder",
        "parent_agent_id": "po-agent",
        "task_id": "task-1",
        "skill": "makato-build:build-implement-tdd",
        "plugin": "makato-build",
        "event": "invoked",
    }
    entry.update(overrides)
    return json.dumps(entry)


# ---------------------------------------------------------------------------
# TestAuditSkillAdoption
# ---------------------------------------------------------------------------


class TestAuditSkillAdoption(unittest.TestCase):
    """Tests for audit_skill_adoption module logic."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    # ------------------------------------------------------------------
    # Test 1 — empty / absent log → "no invocation data available"
    # ------------------------------------------------------------------

    def test_empty_log_produces_no_data_notice(self):
        """Empty JSONL log (zero lines) → dashboard contains no-data notice, exit 0."""
        log_path = self.tmp / "skill-invocations.log"
        log_path.write_text("")  # empty file
        output_path = self.tmp / "skill-adoption.md"

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
        )

        self.assertEqual(result["malformed_count"], 0)
        self.assertEqual(result["valid_count"], 0)
        dashboard = output_path.read_text()
        self.assertIn("no invocation data available", dashboard.lower())

    def test_absent_log_produces_no_data_notice(self):
        """Missing JSONL log file → dashboard contains no-data notice, exit 0."""
        log_path = self.tmp / "nonexistent.log"
        output_path = self.tmp / "skill-adoption.md"

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
        )

        self.assertEqual(result["valid_count"], 0)
        dashboard = output_path.read_text()
        self.assertIn("no invocation data available", dashboard.lower())

    # ------------------------------------------------------------------
    # Test 2 — 10 valid lines → correct counts in dashboard
    # ------------------------------------------------------------------

    def test_ten_valid_lines_reflect_correct_counts(self):
        """10 valid JSONL lines → per-skill and per-agent counts reflected in dashboard."""
        log_path = self.tmp / "skill-invocations.log"
        lines = []
        for i in range(7):
            lines.append(
                _make_valid_line(
                    session_id=f"sess-{i}",
                    agent_id=f"agent-{i}",
                    skill="makato-build:build-implement-tdd",
                    agent_name="coder",
                )
            )
        for i in range(3):
            lines.append(
                _make_valid_line(
                    session_id=f"sess-b-{i}",
                    agent_id=f"agent-b-{i}",
                    skill="makato-build:build-refine",
                    agent_name="refine-agent",
                )
            )
        log_path.write_text("\n".join(lines))
        output_path = self.tmp / "skill-adoption.md"

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
        )

        self.assertEqual(result["valid_count"], 10)
        self.assertEqual(result["malformed_count"], 0)

        dashboard = output_path.read_text()
        # Per-skill counts
        self.assertIn("build-implement-tdd", dashboard)
        self.assertIn("build-refine", dashboard)
        # Per-agent counts
        self.assertIn("coder", dashboard)
        self.assertIn("refine-agent", dashboard)
        # Exact counts appear in dashboard
        self.assertIn("7", dashboard)
        self.assertIn("3", dashboard)

    # ------------------------------------------------------------------
    # Test 3 — 1 malformed + 10 valid → correct split; stderr warning
    # ------------------------------------------------------------------

    def test_malformed_line_counted_and_valid_processed(self):
        """1 malformed + 10 valid lines → valid_count=10, malformed_count=1, stderr notice."""
        log_path = self.tmp / "skill-invocations.log"
        lines = [_make_valid_line(session_id=f"s-{i}") for i in range(10)]
        lines.append("{bad json: }")  # malformed
        log_path.write_text("\n".join(lines))
        output_path = self.tmp / "skill-adoption.md"

        import io
        stderr_capture = io.StringIO()
        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
            stderr=stderr_capture,
        )

        self.assertEqual(result["valid_count"], 10)
        self.assertEqual(result["malformed_count"], 1)
        # stderr should mention malformed
        stderr_capture.seek(0)
        stderr_text = stderr_capture.read()
        self.assertIn("malformed", stderr_text.lower())

        # Dashboard must report malformed count
        dashboard = output_path.read_text()
        self.assertIn("1", dashboard)

    # ------------------------------------------------------------------
    # Test 4 — --dry-run → no file written; output to stdout
    # ------------------------------------------------------------------

    def test_dry_run_writes_to_stdout_not_file(self):
        """--dry-run flag → output goes to stdout, output_path NOT created."""
        log_path = self.tmp / "skill-invocations.log"
        lines = [_make_valid_line()]
        log_path.write_text("\n".join(lines))
        output_path = self.tmp / "skill-adoption.md"

        import io
        stdout_capture = io.StringIO()
        _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=True,
            stdout=stdout_capture,
        )

        # File must NOT have been written
        self.assertFalse(output_path.exists(), "dry-run must not write output file")
        # Stdout must have content
        stdout_capture.seek(0)
        stdout_text = stdout_capture.read()
        self.assertGreater(len(stdout_text.strip()), 0)

    # ------------------------------------------------------------------
    # Test 5 — D31 field validation: missing 'skill' → malformed
    # ------------------------------------------------------------------

    def test_line_missing_skill_field_is_malformed(self):
        """D31 field validation: JSONL line missing 'skill' field → treated as malformed."""
        log_path = self.tmp / "skill-invocations.log"
        # Remove 'skill' from an otherwise-valid line
        entry = json.loads(_make_valid_line())
        del entry["skill"]
        malformed_line = json.dumps(entry)
        valid_line = _make_valid_line(session_id="s-valid")
        log_path.write_text(f"{malformed_line}\n{valid_line}")
        output_path = self.tmp / "skill-adoption.md"

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
        )

        self.assertEqual(result["valid_count"], 1)
        self.assertEqual(result["malformed_count"], 1)

    # ------------------------------------------------------------------
    # Test 6 — malformed count reported in dashboard
    # ------------------------------------------------------------------

    def test_malformed_count_reported_in_dashboard(self):
        """Malformed count is surfaced in the written dashboard."""
        log_path = self.tmp / "skill-invocations.log"
        valid = _make_valid_line()
        # Missing required field 'agent_id'
        entry = json.loads(_make_valid_line())
        del entry["agent_id"]
        bad = json.dumps(entry)
        log_path.write_text(f"{valid}\n{bad}")
        output_path = self.tmp / "skill-adoption.md"

        _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
        )

        dashboard = output_path.read_text()
        self.assertIn("malformed", dashboard.lower())


if __name__ == "__main__":
    unittest.main()
