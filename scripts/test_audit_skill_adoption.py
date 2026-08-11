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
from datetime import datetime, timedelta, timezone
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


# ---------------------------------------------------------------------------
# Task 1 — D16 state sidecar: load/init + atomic save
# ---------------------------------------------------------------------------


class TestD16StateSidecar(unittest.TestCase):
    """Tests for the .claude/state/audit-state.json sidecar (D16)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_load_missing_returns_empty(self):
        """Absent state file → empty dict, never raises."""
        state = _mod._load_state(self.tmp / "nonexistent.json")
        self.assertEqual(state, {})

    def test_load_unparseable_returns_empty(self):
        """Corrupt/unparseable state file → empty dict, never raises."""
        p = self.tmp / "audit-state.json"
        p.write_text("{not json")
        self.assertEqual(_mod._load_state(p), {})

    def test_save_then_load_round_trips(self):
        """State saved is state loaded back, byte-for-value identical."""
        p = self.tmp / "state" / "audit-state.json"  # nested dir must be created
        state = {
            "makato-build:build-refine": {
                "consecutive_clean": 2,
                "consecutive_dirty": 0,
                "current_sample_size": 10,
                "last_window_end": "2026-07-11T00:00:00Z",
            }
        }
        _mod._save_state(state, p)
        self.assertTrue(p.exists())
        self.assertEqual(_mod._load_state(p), state)

    def test_save_is_atomic_no_partial_temp_left(self):
        """After save, only the target file exists — no stray tempfiles."""
        p = self.tmp / "audit-state.json"
        _mod._save_state({"x": {"consecutive_clean": 1}}, p)
        siblings = list(self.tmp.iterdir())
        self.assertEqual([s.name for s in siblings], ["audit-state.json"])


# ---------------------------------------------------------------------------
# Task 2 — adaptive sample sizing + clean/dirty counters
# ---------------------------------------------------------------------------


class TestAdaptiveWindows(unittest.TestCase):
    """Tests for _evaluate_windows (D16 stateful adaptive sizing)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.now = datetime(2026, 7, 11, 12, 0, 0, tzinfo=timezone.utc)

    def _entries(self, skill, n_recent, n_old=0):
        """Build valid entries: n_recent within 7d, n_old outside 7d."""
        out = []
        recent_ts = (self.now - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        old_ts = (self.now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(n_recent):
            out.append(
                {
                    "ts": recent_ts,
                    "session_id": f"r-{skill}-{i}",
                    "agent_id": "a",
                    "agent_name": "coder",
                    "parent_agent_id": "p",
                    "task_id": "t",
                    "skill": skill,
                    "plugin": "makato-build",
                    "event": "invoked",
                }
            )
        for i in range(n_old):
            out.append(
                {
                    "ts": old_ts,
                    "session_id": f"o-{skill}-{i}",
                    "agent_id": "a",
                    "agent_name": "coder",
                    "parent_agent_id": "p",
                    "task_id": "t",
                    "skill": skill,
                    "plugin": "makato-build",
                    "event": "invoked",
                }
            )
        return out

    def test_dirty_window_increments_dirty_and_grows_sample(self):
        """>=5 recent sessions, rate<50% → dirty; dirty counter +1, sample +5."""
        # 2 recent of 10 total → 7-day rate 20% < 50%, sessions_7d=2 ... need >=5 recent
        # Use 6 recent + 4 old = rate 60%? No — rate is recent/total. Want rate<0.5 AND recent>=5.
        # 5 recent + 6 old = total 11, rate 5/11 ≈ 45% < 50%, recent(sessions_7d)=5 >= floor.
        valid = self._entries("s", n_recent=5, n_old=6)
        prior = {}
        new_state, results = _mod._evaluate_windows(valid, prior, now=self.now)
        r = results["s"]
        self.assertEqual(r["classification"], "dirty")
        self.assertEqual(new_state["s"]["consecutive_dirty"], 1)
        self.assertEqual(new_state["s"]["consecutive_clean"], 0)
        # sample grows from init 10 to 15 on first dirty
        self.assertEqual(new_state["s"]["current_sample_size"], 15)

    def test_sample_size_caps_at_30(self):
        """Repeated dirty windows cap current_sample_size at 30."""
        valid = self._entries("s", n_recent=5, n_old=6)
        prior = {
            "s": {
                "consecutive_dirty": 4,
                "consecutive_clean": 0,
                "current_sample_size": 30,
                "last_window_end": "",
            }
        }
        new_state, _ = _mod._evaluate_windows(valid, prior, now=self.now)
        self.assertEqual(new_state["s"]["current_sample_size"], 30)
        self.assertEqual(new_state["s"]["consecutive_dirty"], 5)

    def test_clean_window_resets_dirty(self):
        """Healthy rate → clean; clean counter +1, dirty reset to 0."""
        # 9 recent of 10 total → rate 90% >= 50% → clean
        valid = self._entries("s", n_recent=9, n_old=1)
        prior = {
            "s": {
                "consecutive_dirty": 2,
                "consecutive_clean": 0,
                "current_sample_size": 20,
                "last_window_end": "",
            }
        }
        new_state, results = _mod._evaluate_windows(valid, prior, now=self.now)
        self.assertEqual(results["s"]["classification"], "clean")
        self.assertEqual(new_state["s"]["consecutive_dirty"], 0)
        self.assertEqual(new_state["s"]["consecutive_clean"], 1)

    def test_insufficient_sessions_no_action(self):
        """<5 recent sessions → insufficient; counters unchanged, no signal (AC-2)."""
        valid = self._entries("s", n_recent=3, n_old=0)
        prior = {
            "s": {
                "consecutive_dirty": 1,
                "consecutive_clean": 0,
                "current_sample_size": 15,
                "last_window_end": "",
            }
        }
        new_state, results = _mod._evaluate_windows(valid, prior, now=self.now)
        self.assertEqual(results["s"]["classification"], "insufficient")
        # counters preserved (no-op)
        self.assertEqual(new_state["s"]["consecutive_dirty"], 1)
        self.assertEqual(new_state["s"]["consecutive_clean"], 0)

    def test_three_dirty_flags_escalation(self):
        """Third consecutive dirty window sets escalate=True."""
        valid = self._entries("s", n_recent=5, n_old=6)
        prior = {
            "s": {
                "consecutive_dirty": 2,
                "consecutive_clean": 0,
                "current_sample_size": 20,
                "last_window_end": "",
            }
        }
        _, results = _mod._evaluate_windows(valid, prior, now=self.now)
        self.assertTrue(results["s"]["escalate"])
        self.assertEqual(results["s"]["consecutive_dirty"], 3)

    def test_three_clean_relaxes_threshold(self):
        """Third consecutive clean window relaxes/suspends (relaxed flag set)."""
        valid = self._entries("s", n_recent=9, n_old=1)
        prior = {
            "s": {
                "consecutive_dirty": 0,
                "consecutive_clean": 2,
                "current_sample_size": 10,
                "last_window_end": "",
            }
        }
        _, results = _mod._evaluate_windows(valid, prior, now=self.now)
        self.assertTrue(results["s"].get("relaxed"))


# ---------------------------------------------------------------------------
# Task 3 — D14 3-dirty escalation: auto-open issue + tracker-unreachable
# ---------------------------------------------------------------------------


class TestRefinementEscalation(unittest.TestCase):
    """Tests for _open_refinement_issue and tracker-unreachable handling."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_escalation_invokes_runner_with_label(self):
        """On escalation, issue runner called with type:audit-refinement label."""
        calls = []

        def runner(cmd):
            calls.append(cmd)

            class R:  # noqa: N801
                returncode = 0
                stdout = "https://github.com/x/y/issues/1"
                stderr = ""

            return R()

        ok = _mod._open_refinement_issue("makato-build:foo", 0.2, issue_runner=runner)
        self.assertTrue(ok)
        self.assertEqual(len(calls), 1)
        flat = " ".join(calls[0])
        self.assertIn("type:audit-refinement", flat)
        self.assertIn("makato-build:foo", flat)

    def test_runner_failure_returns_false_not_raise(self):
        """Runner raising (tracker unreachable) → returns False, no exception."""

        def runner(cmd):
            raise OSError("gh not reachable")

        ok = _mod._open_refinement_issue("s", 0.1, issue_runner=runner)
        self.assertFalse(ok)

    def test_process_writes_note_even_when_tracker_unreachable(self):
        """AC-4: escalation with failing runner still writes audit note + warns."""
        import io

        state_path = self.tmp / "audit-state.json"
        anomaly_path = self.tmp / "skill-audit-notes.md"
        # prior: 2 dirty so this window (dirty) escalates
        state_path.write_text(
            json.dumps(
                {
                    "s": {
                        "consecutive_dirty": 2,
                        "consecutive_clean": 0,
                        "current_sample_size": 20,
                        "last_window_end": "",
                    }
                }
            )
        )
        valid = _AdaptiveHelper_entries("s", n_recent=5, n_old=6)

        def failing_runner(cmd):
            raise OSError("unreachable")

        stderr = io.StringIO()
        _mod.run_adaptive_audit(
            valid=valid,
            state_path=state_path,
            anomaly_path=anomaly_path,
            dry_run=False,
            issue_runner=failing_runner,
            stderr=stderr,
            now=datetime(2026, 7, 11, 12, 0, 0, tzinfo=timezone.utc),
        )
        # note recorded despite tracker failure
        self.assertTrue(anomaly_path.exists())
        self.assertIn("makato-build".split(":")[0] if False else "s", anomaly_path.read_text())
        # operator warned
        self.assertIn("warn", stderr.getvalue().lower())

    def test_below_three_dirty_does_not_invoke_runner(self):
        """< 3 dirty windows → runner NOT invoked."""
        state_path = self.tmp / "audit-state.json"
        anomaly_path = self.tmp / "skill-audit-notes.md"
        state_path.write_text(
            json.dumps(
                {
                    "s": {
                        "consecutive_dirty": 0,
                        "consecutive_clean": 0,
                        "current_sample_size": 10,
                        "last_window_end": "",
                    }
                }
            )
        )
        valid = _AdaptiveHelper_entries("s", n_recent=5, n_old=6)
        calls = []

        def runner(cmd):
            calls.append(cmd)

            class R:
                returncode = 0
                stdout = ""
                stderr = ""

            return R()

        _mod.run_adaptive_audit(
            valid=valid,
            state_path=state_path,
            anomaly_path=anomaly_path,
            dry_run=False,
            issue_runner=runner,
            now=datetime(2026, 7, 11, 12, 0, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(calls, [])


# ---------------------------------------------------------------------------
# Task 4 — --dry-run suppresses state writes and gh calls
# ---------------------------------------------------------------------------


class TestDryRunSuppression(unittest.TestCase):
    """AC-3: dry-run reports signal but performs no writes and no gh calls."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_dry_run_no_state_no_issue_no_note(self):
        import io

        state_path = self.tmp / "audit-state.json"
        anomaly_path = self.tmp / "skill-audit-notes.md"
        state_path.write_text(
            json.dumps(
                {
                    "s": {
                        "consecutive_dirty": 2,
                        "consecutive_clean": 0,
                        "current_sample_size": 20,
                        "last_window_end": "",
                    }
                }
            )
        )
        state_before = state_path.read_text()
        valid = _AdaptiveHelper_entries("s", n_recent=5, n_old=6)
        calls = []

        def runner(cmd):
            calls.append(cmd)

            class R:
                returncode = 0
                stdout = ""
                stderr = ""

            return R()

        stdout = io.StringIO()
        _mod.run_adaptive_audit(
            valid=valid,
            state_path=state_path,
            anomaly_path=anomaly_path,
            dry_run=True,
            issue_runner=runner,
            stdout=stdout,
            now=datetime(2026, 7, 11, 12, 0, 0, tzinfo=timezone.utc),
        )
        # no gh call
        self.assertEqual(calls, [])
        # state file unchanged
        self.assertEqual(state_path.read_text(), state_before)
        # no note written
        self.assertFalse(anomaly_path.exists())
        # signal reported to stdout
        self.assertIn("s", stdout.getvalue())


# ---------------------------------------------------------------------------
# INTEGRATE — generate_dashboard(run_adaptive=True) end-to-end
# ---------------------------------------------------------------------------


class TestGenerateDashboardAdaptiveIntegration(unittest.TestCase):
    """INTEGRATE: adaptive pass wired through the public dashboard entry point."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_adaptive_pass_runs_from_generate_dashboard(self):
        """run_adaptive=True escalates on 3-dirty and writes note + state via the
        public dashboard entry point (real log file on disk, injected runner)."""
        log_path = self.tmp / "skill-invocations.log"
        lines = [json.dumps(e) for e in _AdaptiveHelper_entries("s", 5, 6)]
        log_path.write_text("\n".join(lines))
        output_path = self.tmp / "skill-adoption.md"
        state_path = self.tmp / "audit-state.json"
        anomaly_path = self.tmp / "skill-audit-notes.md"
        # seed 2 prior dirty so this window is the 3rd → escalation
        state_path.write_text(
            json.dumps(
                {
                    "s": {
                        "consecutive_dirty": 2,
                        "consecutive_clean": 0,
                        "current_sample_size": 20,
                        "last_window_end": "",
                    }
                }
            )
        )
        calls = []

        def runner(cmd):
            calls.append(cmd)

            class R:
                returncode = 0
                stdout = "https://github.com/x/y/issues/9"
                stderr = ""

            return R()

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
            anomaly_path=anomaly_path,
            run_adaptive=True,
            state_path=state_path,
            issue_runner=runner,
        )

        self.assertTrue(output_path.exists())
        self.assertIsNotNone(result["adaptive"])
        self.assertIn("s", result["adaptive"]["escalated"])
        self.assertEqual(result["adaptive"]["issues_opened"], 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("type:audit-refinement", " ".join(calls[0]))
        self.assertTrue(anomaly_path.exists())
        self.assertEqual(_mod._load_state(state_path)["s"]["consecutive_dirty"], 3)

    def test_adaptive_not_run_when_flag_false(self):
        """Default run_adaptive=False → adaptive summary is None, no state written."""
        log_path = self.tmp / "skill-invocations.log"
        lines = [json.dumps(e) for e in _AdaptiveHelper_entries("s", 5, 6)]
        log_path.write_text("\n".join(lines))
        output_path = self.tmp / "skill-adoption.md"
        state_path = self.tmp / "audit-state.json"
        anomaly_path = self.tmp / "skill-audit-notes.md"  # keep base D15 write inside tmp

        result = _mod.generate_dashboard(
            log_path=log_path,
            output_path=output_path,
            dry_run=False,
            anomaly_path=anomaly_path,
            state_path=state_path,
        )
        self.assertIsNone(result["adaptive"])
        self.assertFalse(state_path.exists())


def _AdaptiveHelper_entries(skill, n_recent, n_old=0):
    """Module-level twin of TestAdaptiveWindows._entries for cross-class reuse."""
    now = datetime(2026, 7, 11, 12, 0, 0, tzinfo=timezone.utc)
    out = []
    recent_ts = (now - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    old_ts = (now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    for i in range(n_recent):
        out.append(
            {
                "ts": recent_ts,
                "session_id": f"r-{skill}-{i}",
                "agent_id": "a",
                "agent_name": "coder",
                "parent_agent_id": "p",
                "task_id": "t",
                "skill": skill,
                "plugin": "makato-build",
                "event": "invoked",
            }
        )
    for i in range(n_old):
        out.append(
            {
                "ts": old_ts,
                "session_id": f"o-{skill}-{i}",
                "agent_id": "a",
                "agent_name": "coder",
                "parent_agent_id": "p",
                "task_id": "t",
                "skill": skill,
                "plugin": "makato-build",
                "event": "invoked",
            }
        )
    return out


if __name__ == "__main__":
    unittest.main()
