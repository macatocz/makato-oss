"""Tests for emit_needs_planning_signal.py — emit Needs Planning signal (#348).

Mirrors emit-needs-planning-signal-smoke-tests.sh scenarios T1–T7.
Stdlib-only + pytest. Run from repo root:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_emit_needs_planning_signal.py -v
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

# Allow imports from scripts/ directory.
_SCRIPTS = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _SCRIPTS not in sys.path:
    sys.path.insert(0, _SCRIPTS)

from emit_needs_planning_signal import (  # noqa: E402,I001
    get_item_id,
    item_add,
    main,
    read_needs_planning_option,
)


# ---------------------------------------------------------------------------
# Test constants.
# ---------------------------------------------------------------------------

KEY = "348-makato-orchestrate-emit-a-durable-needs"
ISSUE_NUM = "348"


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _write_state(spec_dir: str, issue: str, cycles: int, repo: str = "macatocz/makato") -> None:
    """Write a workflow-state-<issue>.json fixture."""
    data = {
        "repo": repo,
        "branch": f"feat/{issue}",
        "worktree_path": None,
        "worktree_retained": False,
        "worktree_retain_reason": None,
        "issue_number": int(issue),
        "sub_tasks": [],
        "current_phase": "done",
        "outer_iteration": 3,
        "budget_consumed_tokens": 150000,
        "session_baseline_tokens": 0,
        "session_count": 1,
        "structural_halt_cycles": cycles,
        "halt_audit": [],
        "lessons_learned": [],
    }
    os.makedirs(spec_dir, exist_ok=True)
    with open(os.path.join(spec_dir, f"workflow-state-{issue}.json"), "w") as fh:
        json.dump(data, fh)


def _write_config_with_option(config_file: str) -> None:
    """Write config.json with needs_planning option ID."""
    cfg = {
        "github_project": {
            "owner": "macatocz",
            "number": 4,
            "status_field_id": "PVTSSF_lADOEZFnDM4BbvspzhWeA8w",
            "fields": {
                "status": {
                    "options": {
                        "needs_planning": "abc12345",
                    }
                }
            },
            "options": {
                "needs_planning": "abc12345",
            },
        }
    }
    os.makedirs(os.path.dirname(config_file) or ".", exist_ok=True)
    with open(config_file, "w") as fh:
        json.dump(cfg, fh)


def _write_config_null_option(config_file: str) -> None:
    """Write config.json with needs_planning=null."""
    cfg = {
        "github_project": {
            "owner": "macatocz",
            "number": 4,
            "status_field_id": "PVTSSF_lADOEZFnDM4BbvspzhWeA8w",
            "fields": {
                "status": {
                    "options": {
                        "needs_planning": None,
                    }
                }
            },
            "options": {
                "needs_planning": None,
            },
        }
    }
    os.makedirs(os.path.dirname(config_file) or ".", exist_ok=True)
    with open(config_file, "w") as fh:
        json.dump(cfg, fh)


def _run_in_sandbox(
    tmp_path,
    cycles: int,
    config_writer,
    threshold: str = "2",
    env_extra: dict | None = None,
) -> tuple[int, str]:
    """Run emit_needs_planning_signal as a subprocess with sandboxed env.

    Returns (returncode, stdout).
    Uses MAKATO_EMIT_NPS_GH_DRY_RUN=1 so no real gh calls are made.
    """
    specs_dir = str(tmp_path / "specs")
    config_file = str(tmp_path / "config.json")
    spec_dir = os.path.join(specs_dir, KEY)

    _write_state(spec_dir, ISSUE_NUM, cycles)
    config_writer(config_file)

    script = os.path.join(_SCRIPTS, "emit_needs_planning_signal.py")
    env = os.environ.copy()
    env["MAKATO_EMIT_NPS_SPECS_DIR"] = specs_dir
    env["MAKATO_EMIT_NPS_CONFIG_FILE"] = config_file
    env["MAKATO_EMIT_NPS_GH_DRY_RUN"] = "1"
    env["MAKATO_STRUCTURAL_RESHAPE_THRESHOLD"] = threshold
    # Remove any stale test hooks from parent env.
    for hook in ["MAKATO_EMIT_NPS_GH_ITEM_ID", "MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT", "MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL"]:
        env.pop(hook, None)
    if env_extra:
        env.update(env_extra)

    result = subprocess.run(
        [sys.executable, script, KEY, ISSUE_NUM],
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout


def test_consumer_repo_uses_installed_workflow_and_build_log_helpers(tmp_path):
    repo = tmp_path / "consumer"
    repo.mkdir()
    subprocess.run(["git", "init", "--quiet", str(repo)], check=True)

    key = "348-consumer"
    specs_dir = repo / "specs"
    _write_state(str(specs_dir / key), ISSUE_NUM, cycles=2)
    config_file = repo / ".claude" / "config.json"
    _write_config_null_option(str(config_file))

    # Force the emitter to use workflow-state.sh for its read while the helper
    # uses the consumer repo's canonical specs/ tree.
    script = os.path.join(_SCRIPTS, "emit_needs_planning_signal.py")
    env = os.environ.copy()
    env["MAKATO_EMIT_NPS_SPECS_DIR"] = str(repo / "empty-specs")
    env["MAKATO_EMIT_NPS_CONFIG_FILE"] = str(config_file)
    env["MAKATO_EMIT_NPS_GH_DRY_RUN"] = "1"
    env["MAKATO_STRUCTURAL_RESHAPE_THRESHOLD"] = "2"
    for name in (
        "MAKATO_BUILD_ROOT",
        "MAKATO_ORCHESTRATE_ROOT",
        "MAKATO_TARGET_REPO_ROOT",
        "MAKATO_SPECS_DIR",
        "SPECS_DIR",
    ):
        env.pop(name, None)

    result = subprocess.run(
        [sys.executable, script, key, ISSUE_NUM],
        cwd=repo,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert not (repo / "plugins").exists()
    log_path = specs_dir / key / "build.jsonl"
    entries = [json.loads(line) for line in log_path.read_text().splitlines()]
    assert any(entry.get("step") == "emit-needs-planning" for entry in entries)


# ---------------------------------------------------------------------------
# T1: Below threshold → no-op; exits 0
# ---------------------------------------------------------------------------


class TestT1BelowThreshold:
    """T1: cycles=1, threshold=2 → no-op, exits 0."""

    def test_below_threshold_exits_0_no_output(self, tmp_path):
        rc, stdout = _run_in_sandbox(tmp_path, cycles=1, config_writer=_write_config_with_option)
        assert rc == 0
        # No gh commands should be echoed.
        assert "gh issue edit" not in stdout


# ---------------------------------------------------------------------------
# T2: At threshold → label applied, board path exercised
# ---------------------------------------------------------------------------


class TestT2AtThreshold:
    """T2: cycles=2, threshold=2 → label applied + item-add + item-edit echoed."""

    def test_at_threshold_board_path(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=2,
            config_writer=_write_config_with_option,
            env_extra={
                "MAKATO_EMIT_NPS_GH_ITEM_ID": "",
                "MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT": "PVTI_mock123",
            },
        )
        assert rc == 0
        assert "gh issue edit" in stdout
        assert "gh project item-add" in stdout
        assert "gh project item-edit" in stdout


# ---------------------------------------------------------------------------
# T3: Above threshold → same as T2
# ---------------------------------------------------------------------------


class TestT3AboveThreshold:
    """T3: cycles=5, threshold=2 → label + item-add + item-edit echoed."""

    def test_above_threshold_board_path(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=5,
            config_writer=_write_config_with_option,
            env_extra={
                "MAKATO_EMIT_NPS_GH_ITEM_ID": "",
                "MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT": "PVTI_mock123",
            },
        )
        assert rc == 0
        assert "gh issue edit" in stdout
        assert "gh project item-add" in stdout
        assert "gh project item-edit" in stdout


# ---------------------------------------------------------------------------
# T4: Degrade-label-only when needs_planning option ID is null
# ---------------------------------------------------------------------------


class TestT4DegradeLabelOnly:
    """T4: needs_planning=null → label applied, board skipped."""

    def test_degrade_label_only(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=2,
            config_writer=_write_config_null_option,
        )
        assert rc == 0
        assert "gh issue edit" in stdout
        assert "gh project item-edit" not in stdout


# ---------------------------------------------------------------------------
# T5: Idempotent — item already on board
# ---------------------------------------------------------------------------


class TestT5Idempotent:
    """T5: Item already on board (ITEM_ID set) → exit 0, item-edit echoed, no item-add."""

    def test_idempotent_item_on_board(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=3,
            config_writer=_write_config_with_option,
            env_extra={
                "MAKATO_EMIT_NPS_GH_ITEM_ID": "PVTI_existing456",
            },
        )
        assert rc == 0
        assert "gh project item-edit" in stdout
        # item-add should NOT appear because item is already on board.
        assert "gh project item-add" not in stdout


# ---------------------------------------------------------------------------
# T6: Board item not found → item-add succeeds → board_applied=true
# ---------------------------------------------------------------------------


class TestT6ItemAddFallbackSuccess:
    """T6: No item on board → item-add succeeds → board path exercised."""

    def test_item_add_fallback_success(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=2,
            config_writer=_write_config_with_option,
            env_extra={
                "MAKATO_EMIT_NPS_GH_ITEM_ID": "",
                "MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT": "PVTI_new789",
            },
        )
        assert rc == 0
        assert "gh project item-add" in stdout
        assert "gh project item-edit" in stdout


# ---------------------------------------------------------------------------
# T7: Board item not found → item-add also fails → exit 0 (graceful warn)
# ---------------------------------------------------------------------------


class TestT7ItemAddFallbackFail:
    """T7: item-add fails → graceful warn, no item-edit, exit 0."""

    def test_item_add_failure_graceful(self, tmp_path):
        rc, stdout = _run_in_sandbox(
            tmp_path,
            cycles=2,
            config_writer=_write_config_with_option,
            env_extra={
                "MAKATO_EMIT_NPS_GH_ITEM_ID": "",
                "MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL": "1",
            },
        )
        assert rc == 0
        assert "gh project item-edit" not in stdout


# ---------------------------------------------------------------------------
# Exit code tests
# ---------------------------------------------------------------------------


class TestExitCodes:
    """Test exit codes from main()."""

    def test_missing_args_exits_1(self):
        rc = main([])
        assert rc == 1

    def test_invalid_issue_number_exits_1(self):
        rc = main(["some-key", "not-a-number"])
        assert rc == 1

    def test_zero_issue_number_exits_1(self):
        rc = main(["some-key", "0"])
        assert rc == 1

    def test_negative_issue_number_exits_1(self):
        rc = main(["some-key", "-5"])
        assert rc == 1


# ---------------------------------------------------------------------------
# Unit tests for read_needs_planning_option
# ---------------------------------------------------------------------------


class TestReadNeedsPlanningOption:
    """Unit tests for read_needs_planning_option."""

    def test_reads_option_id(self, tmp_path):
        config_file = str(tmp_path / "config.json")
        _write_config_with_option(config_file)
        np_id, owner, number, sf_id = read_needs_planning_option(config_file)
        assert np_id == "abc12345"
        assert owner == "macatocz"
        assert number == "4"
        assert sf_id == "PVTSSF_lADOEZFnDM4BbvspzhWeA8w"

    def test_null_option_returns_empty(self, tmp_path):
        config_file = str(tmp_path / "config.json")
        _write_config_null_option(config_file)
        np_id, _, _, _ = read_needs_planning_option(config_file)
        assert np_id == ""

    def test_missing_file_returns_empty(self, tmp_path):
        config_file = str(tmp_path / "nonexistent.json")
        np_id, owner, number, sf_id = read_needs_planning_option(config_file)
        assert np_id == ""
        assert owner == ""


# ---------------------------------------------------------------------------
# Unit tests for get_item_id (test hook behaviour)
# ---------------------------------------------------------------------------


class TestGetItemId:
    """Unit tests for get_item_id with MAKATO_EMIT_NPS_GH_ITEM_ID hook."""

    def test_env_hook_returns_value(self, monkeypatch):
        monkeypatch.setenv("MAKATO_EMIT_NPS_GH_ITEM_ID", "PVTI_test123")
        result = get_item_id("4", "macatocz", "348", dry_run=True)
        assert result == "PVTI_test123"

    def test_env_hook_empty_string_returns_empty(self, monkeypatch):
        monkeypatch.setenv("MAKATO_EMIT_NPS_GH_ITEM_ID", "")
        result = get_item_id("4", "macatocz", "348", dry_run=True)
        assert result == ""


# ---------------------------------------------------------------------------
# Unit tests for item_add (dry-run mode)
# ---------------------------------------------------------------------------


class TestItemAdd:
    """Unit tests for item_add dry-run mode."""

    def test_dry_run_add_fail_returns_empty(self, monkeypatch):
        monkeypatch.setenv("MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL", "1")
        monkeypatch.delenv("MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT", raising=False)
        result = item_add("4", "macatocz", "macatocz/makato", "348", dry_run=True)
        assert result == ""

    def test_dry_run_add_success_returns_id(self, monkeypatch, capsys):
        monkeypatch.delenv("MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL", raising=False)
        monkeypatch.setenv("MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT", "PVTI_new999")
        result = item_add("4", "macatocz", "macatocz/makato", "348", dry_run=True)
        assert result == "PVTI_new999"
        out = capsys.readouterr().out
        assert "gh project item-add" in out
