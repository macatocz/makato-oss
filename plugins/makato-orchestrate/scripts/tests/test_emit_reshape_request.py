"""Tests for emit_reshape_request.py — ported from emit-reshape-request-smoke-tests.sh.

Scenario coverage (>= 12 scenarios, T1–T12):
  T1:  missing args exits 1 and prints usage error to stderr
  T2:  missing workflow-state file exits 1
  T3:  valid workflow-state with structural halts produces reshape-request.json
  T4:  halt_history contains only structural HALT entries
  T5:  non-structural HALTs excluded from halt_history
  T6:  lessons_trail contains only entries with trigger=="halt"
  T7:  last_critical_errors populated with CRITICAL-containing strings from last sub_task
  T8:  last_critical_errors absent when no CRITICAL errors in last sub_task
  T9:  reshape-request.json written atomically (no .tmp leftover)
  T10: reshape_cycles increments from prior reshape-request.json
  T11: valid output passes JSON schema validation
  T12: orchestrate.jsonl entry appended with step "emit-reshape-request"
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

# Allow import whether discovery runs from repo root or this directory.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS_DIR = os.path.join(_HERE, "..")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from emit_reshape_request import (  # noqa: E402
    build_reshape_request,
    extract_last_critical_errors,
    filter_lessons_trail,
    filter_structural_halts,
    is_structural_halt,
    main,
    resolve_spec_folder,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _find_repo_root() -> str:
    """Walk up from _HERE to find the repo root (contains pyproject.toml)."""
    cur = _HERE
    for _ in range(8):
        if os.path.isfile(os.path.join(cur, "pyproject.toml")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return _HERE


_REPO_ROOT = _find_repo_root()
_SCHEMA_PATH = os.path.join(
    _REPO_ROOT,
    "plugins",
    "makato-orchestrate",
    "scripts",
    "emit-reshape-request.schema.json",
)


def _now() -> str:
    n = datetime.now(timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond // 1000:03d}Z"


def _make_workflow_state(issue_number: int = 349, with_critical: bool = True) -> dict:
    """Build a minimal workflow-state fixture dict."""
    now = _now()
    state: dict = {
        "repo": "macatocz/makato",
        "branch": "feat/349",
        "worktree_path": None,
        "worktree_retained": False,
        "worktree_retain_reason": None,
        "issue_number": issue_number,
        "sub_tasks": [
            {
                "id": "task-1",
                "title": "Task 1",
                "status": "complete",
                "agent_result": {
                    "schema": "r1",
                    "agent": "coder",
                    "status": "failure",
                    "summary": "structural blocker",
                    "files_changed": [],
                    "tests_written": [],
                    "errors": (["CRITICAL: some fatal error", "another error without keyword"] if with_critical else ["some warning", "another note"]),
                    "tool_calls_used": 10,
                    "data": {},
                },
            }
        ],
        "current_phase": "implement",
        "resume_point": None,
        "budget_consumed_tokens": 50000,
        "session_baseline_tokens": 0,
        "budget_limit_tokens": 500000,
        "context_warn_tokens": 150000,
        "outer_iteration": 1,
        "merge_conflict_cycles": 0,
        "ci_failure_cycles": 0,
        "halt_audit": [
            {"code": "HALT-003", "ts": now, "data": {"reason": "critical diff finding"}, "retryable": False, "origin": "human"},
            {"code": "HALT-STRUCTURAL", "ts": now, "data": {"escalation": "refine"}, "retryable": False, "origin": "human"},
            {"code": "HALT-010", "ts": now, "data": {"human_review_cycles": 3}},
            {"code": "HALT-008", "ts": now, "data": {"origin": "outer_iteration", "reason": "budget exhausted"}, "retryable": True, "origin": "auto", "retry_after_secs": 60},
            {"code": "HALT-007", "ts": now, "data": {"reason": "cost ceiling"}},
            {"code": "HALT-008", "ts": now, "data": {"origin": "merge_conflict", "reason": "irreconcilable"}},
        ],
        "human_review_cycles": 3,
        "github_pr_number": None,
        "progress_comment_id": None,
        "lessons_learned": [
            {
                "ts": now,
                "cycle": 1,
                "trigger": "halt",
                "description": "HALT-003 fired after coder returned failure with refine escalation",
                "files_affected": ["plugins/makato-orchestrate/scripts/emit_reshape_request.py"],
            },
            {
                "ts": now,
                "cycle": 0,
                "trigger": "ci_failure",
                "description": "CI failed on linting",
                "files_affected": [],
            },
            {
                "ts": now,
                "cycle": 1,
                "trigger": "halt",
                "description": "HALT-010 hit max human review cycles",
                "files_affected": [],
            },
        ],
        "session_summary": None,
        "session_count": 1,
        "handoff_reason": None,
        "restart_failed": False,
        "spawned_pid": None,
        "resume_ack": None,
        "created_at": now,
        "updated_at": now,
    }
    return state


class TestStructuralHaltFilter(unittest.TestCase):
    """Unit tests for is_structural_halt and filter_structural_halts."""

    def test_halt_003_is_structural(self) -> None:
        self.assertTrue(is_structural_halt({"code": "HALT-003", "ts": "t", "data": {}}))

    def test_halt_structural_is_structural(self) -> None:
        self.assertTrue(is_structural_halt({"code": "HALT-STRUCTURAL", "ts": "t", "data": {}}))

    def test_halt_010_is_structural(self) -> None:
        self.assertTrue(is_structural_halt({"code": "HALT-010", "ts": "t", "data": {}}))

    def test_halt_008_outer_iteration_is_structural(self) -> None:
        self.assertTrue(is_structural_halt({"code": "HALT-008", "ts": "t", "data": {"origin": "outer_iteration"}}))

    def test_halt_007_is_not_structural(self) -> None:
        self.assertFalse(is_structural_halt({"code": "HALT-007", "ts": "t", "data": {}}))

    def test_halt_008_merge_conflict_is_not_structural(self) -> None:
        self.assertFalse(is_structural_halt({"code": "HALT-008", "ts": "t", "data": {"origin": "merge_conflict"}}))

    def test_filter_structural_halts_count(self) -> None:
        """T4/T5: filter keeps 4 structural entries, drops HALT-007 and HALT-008/merge_conflict."""
        halt_audit = _make_workflow_state()["halt_audit"]
        structural = filter_structural_halts(halt_audit)
        codes = [e["code"] for e in structural]
        self.assertEqual(len(structural), 4)
        self.assertIn("HALT-003", codes)
        self.assertIn("HALT-STRUCTURAL", codes)
        self.assertIn("HALT-010", codes)
        # HALT-008 (outer_iteration) must be present.
        outer_008 = [e for e in structural if e["code"] == "HALT-008"]
        self.assertEqual(len(outer_008), 1)
        self.assertEqual(outer_008[0]["data"]["origin"], "outer_iteration")

    def test_halt_007_excluded(self) -> None:
        """T5: HALT-007 must not appear in halt_history."""
        halt_audit = _make_workflow_state()["halt_audit"]
        structural = filter_structural_halts(halt_audit)
        codes = [e["code"] for e in structural]
        self.assertNotIn("HALT-007", codes)

    def test_halt_008_merge_conflict_excluded(self) -> None:
        """T5: HALT-008/merge_conflict must not appear in halt_history."""
        halt_audit = _make_workflow_state()["halt_audit"]
        structural = filter_structural_halts(halt_audit)
        merge_008 = [e for e in structural if e["code"] == "HALT-008" and e.get("data", {}).get("origin") == "merge_conflict"]
        self.assertEqual(len(merge_008), 0)


class TestLessonsTrailFilter(unittest.TestCase):
    """Unit tests for filter_lessons_trail."""

    def test_only_halt_triggered_lessons_kept(self) -> None:
        """T6: lessons_trail contains only trigger=='halt' entries."""
        lessons = _make_workflow_state()["lessons_learned"]
        trail = filter_lessons_trail(lessons)
        self.assertEqual(len(trail), 2)
        for entry in trail:
            self.assertEqual(entry["trigger"], "halt")

    def test_ci_failure_lesson_excluded(self) -> None:
        lessons = _make_workflow_state()["lessons_learned"]
        trail = filter_lessons_trail(lessons)
        triggers = [e["trigger"] for e in trail]
        self.assertNotIn("ci_failure", triggers)


class TestCriticalErrors(unittest.TestCase):
    """Unit tests for extract_last_critical_errors."""

    def test_critical_strings_extracted(self) -> None:
        """T7: CRITICAL-containing strings are extracted from last sub_task."""
        sub_tasks = _make_workflow_state(with_critical=True)["sub_tasks"]
        errors = extract_last_critical_errors(sub_tasks)
        self.assertEqual(len(errors), 1)
        self.assertIn("CRITICAL", errors[0].upper())

    def test_non_critical_strings_excluded(self) -> None:
        """T7: strings without CRITICAL are excluded."""
        sub_tasks = _make_workflow_state(with_critical=True)["sub_tasks"]
        errors = extract_last_critical_errors(sub_tasks)
        # "another error without keyword" must not be in results.
        self.assertFalse(any("another error" in e for e in errors), "non-CRITICAL error must not appear in last_critical_errors")

    def test_no_critical_errors_returns_empty(self) -> None:
        """T8: returns empty list when no CRITICAL errors."""
        sub_tasks = _make_workflow_state(with_critical=False)["sub_tasks"]
        errors = extract_last_critical_errors(sub_tasks)
        self.assertEqual(errors, [])

    def test_null_agent_result_skipped(self) -> None:
        sub_tasks = [
            {"id": "t1", "agent_result": None},
            {"id": "t2", "agent_result": {"errors": ["CRITICAL: real error"]}},
        ]
        errors = extract_last_critical_errors(sub_tasks)
        self.assertEqual(len(errors), 1)


class TestBuildReshapeRequest(unittest.TestCase):
    """Unit tests for build_reshape_request."""

    def setUp(self) -> None:
        self.state = _make_workflow_state()
        self.payload = build_reshape_request(
            key="349-makato-orchestrate-serialize-structural",
            issue_number=349,
            state=self.state,
            reshape_cycles=0,
            emitted_at=_now(),
        )

    def test_schema_version_is_v1(self) -> None:
        self.assertEqual(self.payload["schema_version"], "v1")

    def test_issue_slug_derived_correctly(self) -> None:
        """Strips leading '<number>-' prefix from KEY."""
        self.assertEqual(
            self.payload["issue_slug"],
            "makato-orchestrate-serialize-structural",
        )

    def test_structural_halt_cycles_count(self) -> None:
        self.assertEqual(self.payload["structural_halt_cycles"], 4)

    def test_reshape_cycles_zero_on_first_emit(self) -> None:
        self.assertEqual(self.payload["reshape_cycles"], 0)

    def test_halt_history_contains_structural_only(self) -> None:
        """T4: halt_history contains only structural HALT entries."""
        codes = [e["code"] for e in self.payload["halt_history"]]
        self.assertIn("HALT-003", codes)
        self.assertNotIn("HALT-007", codes)

    def test_lessons_trail_halt_only(self) -> None:
        """T6: lessons_trail trigger == 'halt' only."""
        for entry in self.payload["lessons_trail"]:
            self.assertEqual(entry["trigger"], "halt")

    def test_last_critical_errors_present_when_critical(self) -> None:
        """T7: last_critical_errors populated."""
        self.assertIn("last_critical_errors", self.payload)
        self.assertGreater(len(self.payload["last_critical_errors"]), 0)

    def test_last_critical_errors_absent_when_no_critical(self) -> None:
        """T8: last_critical_errors absent when no CRITICAL errors."""
        state_no_critical = _make_workflow_state(with_critical=False)
        payload = build_reshape_request(
            key="100-no-critical",
            issue_number=100,
            state=state_no_critical,
            reshape_cycles=0,
            emitted_at=_now(),
        )
        self.assertNotIn("last_critical_errors", payload, "last_critical_errors should be absent when no CRITICAL errors")


class TestMainIntegration(unittest.TestCase):
    """Integration tests for main() — write to temp specs dir."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory(prefix="emit-reshape-test-")
        self.specs_dir = os.path.join(self._tmpdir.name, "specs")
        os.makedirs(self.specs_dir)
        self.key = "349-makato-orchestrate-serialize-structural"
        self.issue_num = 349
        self.spec_dir = os.path.join(self.specs_dir, self.key)
        os.makedirs(self.spec_dir)
        # Write fixture workflow-state.
        state = _make_workflow_state(issue_number=self.issue_num)
        state_path = os.path.join(self.spec_dir, f"workflow-state-{self.issue_num}.json")
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump(state, fh)

    def tearDown(self) -> None:
        self._tmpdir.cleanup()

    def _run_main(self, key: str | None = None, issue: str | None = None) -> int:
        env_backup = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR")
        os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = self.specs_dir
        try:
            args = [key or self.key, issue or str(self.issue_num)]
            return main(args)
        finally:
            if env_backup is None:
                os.environ.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            else:
                os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = env_backup

    def test_missing_args_exits_non_zero(self) -> None:
        """T1: missing args → non-zero exit."""
        env_backup = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR")
        os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = self.specs_dir
        try:
            with self.assertRaises(SystemExit) as cm:
                main([])
            self.assertNotEqual(cm.exception.code, 0)
        except SystemExit as e:
            self.assertNotEqual(e.code, 0)
        finally:
            if env_backup is None:
                os.environ.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            else:
                os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = env_backup

    def test_invalid_issue_number_exits_1(self) -> None:
        """T1: non-positive-integer ISSUE_NUMBER exits 1."""
        env_backup = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR")
        os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = self.specs_dir
        try:
            rc = main(["some-key", "abc"])
            self.assertEqual(rc, 1)
        finally:
            if env_backup is None:
                os.environ.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            else:
                os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = env_backup

    def test_missing_workflow_state_exits_1(self) -> None:
        """T2: missing workflow-state file exits 1."""
        env_backup = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR")
        os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = self.specs_dir
        try:
            rc = main(["999-no-such-issue", "999"])
            self.assertEqual(rc, 1)
        finally:
            if env_backup is None:
                os.environ.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            else:
                os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = env_backup

    def test_produces_reshape_request_json(self) -> None:
        """T3: valid workflow-state produces reshape-request.json."""
        rc = self._run_main()
        self.assertEqual(rc, 0)
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        self.assertTrue(os.path.isfile(reshape_path), "reshape-request.json must be created")

    def test_no_tmp_files_leftover(self) -> None:
        """T9: no .tmp files remain after atomic write."""
        self._run_main()
        tmp_files = list(Path(self.spec_dir).glob("reshape-request.json.*"))
        self.assertEqual(len(tmp_files), 0, f"tmp files remain: {tmp_files}")

    def test_reshape_cycles_increments(self) -> None:
        """T10: reshape_cycles increments from prior reshape-request.json."""
        self._run_main()
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        data_0 = json.loads(Path(reshape_path).read_text())
        self.assertEqual(data_0["reshape_cycles"], 0)

        self._run_main()
        data_1 = json.loads(Path(reshape_path).read_text())
        self.assertEqual(data_1["reshape_cycles"], 1)

    def test_output_passes_schema_validation(self) -> None:
        """T11: valid output passes JSON schema validation."""
        self._run_main()
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        data = json.loads(Path(reshape_path).read_text())

        if not os.path.isfile(_SCHEMA_PATH):
            self.skipTest(f"Schema not found at {_SCHEMA_PATH}")

        try:
            import jsonschema  # type: ignore

            schema = json.loads(Path(_SCHEMA_PATH).read_text())
            # Should not raise.
            jsonschema.validate(data, schema)
        except ImportError:
            # Without jsonschema, just verify required fields present.
            required = [
                "schema_version",
                "issue_key",
                "issue_number",
                "issue_slug",
                "structural_halt_cycles",
                "reshape_cycles",
                "halt_history",
                "lessons_trail",
                "emitted_at",
            ]
            for field in required:
                self.assertIn(field, data, f"required field missing: {field}")
            self.assertEqual(data["schema_version"], "v1")

    def test_orchestrate_jsonl_entry_appended(self) -> None:
        """T12: orchestrate.jsonl entry appended with step 'emit-reshape-request'."""
        self._run_main()
        log_path = os.path.join(self.spec_dir, "orchestrate.jsonl")
        self.assertTrue(os.path.isfile(log_path), "orchestrate.jsonl must be created")
        entries = [json.loads(line) for line in Path(log_path).read_text().splitlines() if line.strip()]
        steps = [e.get("step") for e in entries]
        self.assertIn("emit-reshape-request", steps)

    def test_halt_history_structural_only_from_file(self) -> None:
        """T4+T5: reshape-request.json halt_history contains only structural entries."""
        self._run_main()
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        data = json.loads(Path(reshape_path).read_text())
        codes = [e["code"] for e in data["halt_history"]]
        # All 4 structural codes must be present.
        self.assertIn("HALT-003", codes)
        self.assertIn("HALT-STRUCTURAL", codes)
        self.assertIn("HALT-010", codes)
        outer_008 = [e for e in data["halt_history"] if e["code"] == "HALT-008" and e["data"].get("origin") == "outer_iteration"]
        self.assertEqual(len(outer_008), 1)
        # Non-structural must be absent.
        self.assertNotIn("HALT-007", codes)
        merge_008 = [e for e in data["halt_history"] if e["code"] == "HALT-008" and e["data"].get("origin") == "merge_conflict"]
        self.assertEqual(len(merge_008), 0)
        self.assertEqual(len(data["halt_history"]), 4)

    def test_halt_history_keeps_halt_classification_fields(self) -> None:
        """Structural entries carrying retryable/origin (as po-agent writes them) round-trip into halt_history."""
        rc = self._run_main()
        self.assertEqual(rc, 0)
        data = json.loads(Path(self.spec_dir, "reshape-request.json").read_text())
        by_code = {e["code"]: e for e in data["halt_history"]}
        self.assertEqual((by_code["HALT-STRUCTURAL"]["retryable"], by_code["HALT-STRUCTURAL"]["origin"]), (False, "human"))
        self.assertEqual(by_code["HALT-008"]["retry_after_secs"], 60)
        self.assertNotIn("origin", by_code["HALT-010"])

    def test_halt_history_item_schema_accepts_every_halt_audit_field(self) -> None:
        """Every field a valid workflow-state halt_audit entry may carry is allowed in halt_history."""
        state_schema_path = Path(_REPO_ROOT, "plugins", "makato-orchestrate", "skills", "workflow-state", "references", "workflow-state.schema.json")
        halt_audit_item = json.loads(state_schema_path.read_text())["properties"]["halt_audit"]["items"]
        halt_history_item = json.loads(Path(_SCHEMA_PATH).read_text())["properties"]["halt_history"]["items"]
        self.assertEqual(set(halt_audit_item["properties"]), set(halt_history_item["properties"]))

    def test_lessons_trail_halt_only_from_file(self) -> None:
        """T6: reshape-request.json lessons_trail only trigger=='halt'."""
        self._run_main()
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        data = json.loads(Path(reshape_path).read_text())
        self.assertEqual(len(data["lessons_trail"]), 2)
        for entry in data["lessons_trail"]:
            self.assertEqual(entry["trigger"], "halt")

    def test_last_critical_errors_present_in_file(self) -> None:
        """T7: last_critical_errors present in output file."""
        self._run_main()
        reshape_path = os.path.join(self.spec_dir, "reshape-request.json")
        data = json.loads(Path(reshape_path).read_text())
        self.assertIn("last_critical_errors", data)
        self.assertEqual(len(data["last_critical_errors"]), 1)
        self.assertIn("CRITICAL", data["last_critical_errors"][0].upper())

    def test_last_critical_errors_absent_when_no_critical_in_file(self) -> None:
        """T8: last_critical_errors absent/null/empty when no CRITICAL errors."""
        no_crit_key = "100-no-critical"
        no_crit_dir = os.path.join(self.specs_dir, no_crit_key)
        os.makedirs(no_crit_dir)
        state = _make_workflow_state(issue_number=100, with_critical=False)
        state_path = os.path.join(no_crit_dir, "workflow-state-100.json")
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump(state, fh)

        env_backup = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR")
        os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = self.specs_dir
        try:
            rc = main([no_crit_key, "100"])
        finally:
            if env_backup is None:
                os.environ.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            else:
                os.environ["MAKATO_EMIT_RESHAPE_SPECS_DIR"] = env_backup

        self.assertEqual(rc, 0)
        reshape_path = os.path.join(no_crit_dir, "reshape-request.json")
        data = json.loads(Path(reshape_path).read_text())
        # last_critical_errors should be absent, null, or empty.
        val = data.get("last_critical_errors", None)
        self.assertTrue(val is None or val == [], f"last_critical_errors should be absent/null/empty, got: {val!r}")


class TestInstalledPluginPaths(unittest.TestCase):
    """Integration coverage when the installed plugin runs in a consumer repo."""

    def test_emits_schema_valid_request_without_target_plugins_directory(self) -> None:
        import jsonschema

        with tempfile.TemporaryDirectory(prefix="emit-reshape-consumer-") as tmpdir:
            repo = Path(tmpdir) / "consumer"
            repo.mkdir()
            subprocess.run(["git", "init", "--quiet", str(repo)], check=True)

            key = "913-consumer-repo"
            issue_number = 913
            spec_dir = repo / "specs" / key
            spec_dir.mkdir(parents=True)
            state = _make_workflow_state(issue_number=issue_number)
            (spec_dir / f"workflow-state-{issue_number}.json").write_text(
                json.dumps(state), encoding="utf-8"
            )

            script = (Path(_SCRIPTS_DIR) / "emit_reshape_request.py").resolve()
            env = os.environ.copy()
            env.pop("MAKATO_EMIT_RESHAPE_SPECS_DIR", None)
            result = subprocess.run(
                [sys.executable, str(script), key, str(issue_number)],
                cwd=repo,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((repo / "plugins").exists())
            request_path = spec_dir / "reshape-request.json"
            self.assertTrue(request_path.is_file())
            schema_path = script.parent / "emit-reshape-request.schema.json"
            jsonschema.validate(
                json.loads(request_path.read_text(encoding="utf-8")),
                json.loads(schema_path.read_text(encoding="utf-8")),
            )


class TestResolveSpecFolder(unittest.TestCase):
    """Unit tests for resolve_spec_folder."""

    def test_finds_key_dash_slug_folder(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "349-some-slug")
            os.makedirs(target)
            result = resolve_spec_folder(tmpdir, "349")
            self.assertEqual(result, target)

    def test_falls_back_to_key_only_folder(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "349")
            os.makedirs(target)
            result = resolve_spec_folder(tmpdir, "349")
            self.assertEqual(result, target)

    def test_returns_fallback_when_neither_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            result = resolve_spec_folder(tmpdir, "999")
            self.assertEqual(result, os.path.join(tmpdir, "999"))


if __name__ == "__main__":
    unittest.main()
