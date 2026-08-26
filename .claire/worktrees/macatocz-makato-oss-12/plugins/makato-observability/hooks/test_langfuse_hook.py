"""Unit tests for langfuse_hook.py — issue #12 tasks 1, 4, and 5.

Covered:
  - _read_build_signals(): all six signal paths, missing/empty file, edge cases
  - _derive_plan_success(): True / False / None from fixture JSONL
  - _build_trace_tags(): CC_MODEL_ROLE + CC_MODEL_ENDPOINT env-var injection
    (the modelRole: camelCase format is xfail pending goal-mode task 3)

No live Langfuse credentials are required.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Import the hook module.
# The module-level try/except around `from langfuse import ...` calls
# sys.exit(0) when langfuse is absent.  We assume langfuse is installed in
# the test environment (it is listed in installed packages with a pydantic
# compatibility warning).
# ---------------------------------------------------------------------------
sys.path.insert(0, str(Path(__file__).parent))
from langfuse_hook import (  # noqa: E402
    BuildSignals,
    TraceContext,
    Turn,
    _build_trace_tags,
    _derive_plan_success,
    _read_build_signals,
)

# ---------------------------------------------------------------------------
# Shared fixture helpers
# ---------------------------------------------------------------------------

#: JSONL fixture covering all six build-signal paths.
FIXTURE_JSONL_ALL_SIGNALS: str = "\n".join(
    [
        # 1. verify_gate_passed → True
        json.dumps({"step": "verify", "status": "ok", "data": {}}),
        # 2. ci_green → True
        json.dumps({"step": "ci", "status": "ok", "data": {}}),
        # 3. review_critical_count → 2
        json.dumps({"step": "review", "status": "ok", "data": {"critical_count": 2}}),
        # 4. coder_retry_count → 1
        json.dumps({"step": "coder-retry", "status": "decision", "data": {}}),
        # 5. conflict_halt_count → 1
        json.dumps({"step": "resolve-conflict", "status": "halt", "data": {}}),
        # 6. merged_without_override → True  (override=False means no override)
        json.dumps({"step": "merge", "status": "ok", "data": {"override": False}}),
    ]
)


def _write_build_jsonl(tmp_path: Path, key: str, content: str) -> Path:
    """Create ``tmp_path/<key>-slug/build.jsonl`` and return ``tmp_path``."""
    slug_dir = tmp_path / f"{key}-slug"
    slug_dir.mkdir(parents=True, exist_ok=True)
    (slug_dir / "build.jsonl").write_text(content, encoding="utf-8")
    return tmp_path


def _minimal_turn() -> Turn:
    return Turn(user_msg={}, assistant_msgs=[], tool_results_by_id={})


def _minimal_ctx(**overrides: Any) -> TraceContext:
    defaults: dict[str, Any] = dict(
        session_id="s-test",
        transcript_path=Path("/tmp/test.jsonl"),
        user_id=None,
        project_name=None,
        makato_version=None,
        loop_phase=None,
    )
    defaults.update(overrides)
    return TraceContext(**defaults)


# ===========================================================================
# Task 1 — _read_build_signals()
# ===========================================================================


class TestReadBuildSignals:
    """Tests for _read_build_signals() (issue #12 task 1)."""

    def test_all_six_signal_paths(self, tmp_path: Path) -> None:
        """Fixture covers every signal field; all should be populated."""
        specs = _write_build_jsonl(tmp_path, "KEY-1", FIXTURE_JSONL_ALL_SIGNALS)
        signals = _read_build_signals("KEY-1", specs)

        assert signals.verify_gate_passed is True
        assert signals.ci_green is True
        assert signals.review_critical_count == 2
        assert signals.coder_retry_count == 1
        assert signals.conflict_halt_count == 1
        assert signals.merged_without_override is True

    def test_verify_gate_failed(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(
            tmp_path, "KEY-VF", json.dumps({"step": "verify", "status": "error", "data": {}})
        )
        assert _read_build_signals("KEY-VF", specs).verify_gate_passed is False

    def test_ci_failed(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(
            tmp_path, "KEY-CF", json.dumps({"step": "ci", "status": "error", "data": {}})
        )
        assert _read_build_signals("KEY-CF", specs).ci_green is False

    def test_merge_with_override_sets_flag_false(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(
            tmp_path,
            "KEY-OVR",
            json.dumps({"step": "merge", "status": "ok", "data": {"override": True}}),
        )
        assert _read_build_signals("KEY-OVR", specs).merged_without_override is False

    def test_missing_file_returns_zero_filled_signals(self, tmp_path: Path) -> None:
        """No build.jsonl present — every field must be None."""
        signals = _read_build_signals("MISSING-99", tmp_path)

        assert signals == BuildSignals()
        assert signals.verify_gate_passed is None
        assert signals.ci_green is None
        assert signals.review_critical_count is None
        assert signals.coder_retry_count is None
        assert signals.conflict_halt_count is None
        assert signals.merged_without_override is None

    def test_empty_file_returns_zero_filled_signals(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(tmp_path, "KEY-EMPTY", "")
        assert _read_build_signals("KEY-EMPTY", specs) == BuildSignals()

    def test_malformed_jsonl_lines_are_skipped(self, tmp_path: Path) -> None:
        content = "not-json\n" + json.dumps({"step": "verify", "status": "ok", "data": {}})
        specs = _write_build_jsonl(tmp_path, "KEY-BAD", content)
        assert _read_build_signals("KEY-BAD", specs).verify_gate_passed is True

    def test_first_verify_wins_subsequent_ignored(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"step": "verify", "status": "ok", "data": {}}),
            json.dumps({"step": "verify", "status": "error", "data": {}}),
        ]
        specs = _write_build_jsonl(tmp_path, "KEY-FV", "\n".join(lines))
        assert _read_build_signals("KEY-FV", specs).verify_gate_passed is True

    def test_first_ci_wins_subsequent_ignored(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"step": "ci", "status": "ok", "data": {}}),
            json.dumps({"step": "ci", "status": "error", "data": {}}),
        ]
        specs = _write_build_jsonl(tmp_path, "KEY-FCI", "\n".join(lines))
        assert _read_build_signals("KEY-FCI", specs).ci_green is True

    def test_multiple_review_critical_counts_accumulate(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"step": "review", "status": "ok", "data": {"critical_count": 1}}),
            json.dumps({"step": "review", "status": "ok", "data": {"critical_count": 2}}),
        ]
        specs = _write_build_jsonl(tmp_path, "KEY-REV", "\n".join(lines))
        assert _read_build_signals("KEY-REV", specs).review_critical_count == 3

    def test_multiple_coder_retries_counted(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"step": "coder-retry", "status": "decision", "data": {}}),
            json.dumps({"step": "coder-retry", "status": "decision", "data": {}}),
        ]
        specs = _write_build_jsonl(tmp_path, "KEY-CRT", "\n".join(lines))
        assert _read_build_signals("KEY-CRT", specs).coder_retry_count == 2

    def test_multiple_conflict_halts_counted(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"step": "resolve-conflict", "status": "halt", "data": {}}),
            json.dumps({"step": "resolve-conflict", "status": "halt", "data": {}}),
        ]
        specs = _write_build_jsonl(tmp_path, "KEY-HALT", "\n".join(lines))
        assert _read_build_signals("KEY-HALT", specs).conflict_halt_count == 2

    def test_resolve_conflict_non_halt_not_counted(self, tmp_path: Path) -> None:
        """Only status:'halt' entries increment conflict_halt_count."""
        line = json.dumps({"step": "resolve-conflict", "status": "ok", "data": {}})
        specs = _write_build_jsonl(tmp_path, "KEY-RCONF", line)
        assert _read_build_signals("KEY-RCONF", specs).conflict_halt_count is None


# ===========================================================================
# Task 4 — _derive_plan_success()
# ===========================================================================


class TestDerivePlanSuccess:
    """Tests for _derive_plan_success() (issue #12 task 4)."""

    def _specs(self, tmp_path: Path, key: str, lines: list[str]) -> Path:
        return _write_build_jsonl(tmp_path, key, "\n".join(lines))

    def test_returns_true_when_first_verify_after_implement_is_ok(self, tmp_path: Path) -> None:
        specs = self._specs(
            tmp_path,
            "PS-T",
            [
                json.dumps({"step": "implement", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "ok", "data": {}}),
            ],
        )
        assert _derive_plan_success("PS-T", specs) is True

    def test_returns_false_when_first_verify_after_implement_is_error(self, tmp_path: Path) -> None:
        specs = self._specs(
            tmp_path,
            "PS-F",
            [
                json.dumps({"step": "implement", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "error", "data": {}}),
            ],
        )
        assert _derive_plan_success("PS-F", specs) is False

    def test_returns_none_when_no_implement_entry(self, tmp_path: Path) -> None:
        specs = self._specs(
            tmp_path,
            "PS-NI",
            [json.dumps({"step": "verify", "status": "ok", "data": {}})],
        )
        assert _derive_plan_success("PS-NI", specs) is None

    def test_returns_none_when_no_verify_after_implement(self, tmp_path: Path) -> None:
        specs = self._specs(
            tmp_path,
            "PS-NV",
            [json.dumps({"step": "implement", "status": "ok", "data": {}})],
        )
        assert _derive_plan_success("PS-NV", specs) is None

    def test_returns_none_on_missing_file(self, tmp_path: Path) -> None:
        assert _derive_plan_success("MISSING-PS", tmp_path) is None

    def test_verify_before_implement_is_not_counted(self, tmp_path: Path) -> None:
        """A verify step that appears *before* any implement step must not be returned."""
        specs = self._specs(
            tmp_path,
            "PS-PRE",
            [
                json.dumps({"step": "verify", "status": "ok", "data": {}}),
                json.dumps({"step": "implement", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "error", "data": {}}),
            ],
        )
        # The pre-implement verify is skipped; the post-implement one is "error"
        assert _derive_plan_success("PS-PRE", specs) is False

    def test_only_first_verify_after_implement_is_used(self, tmp_path: Path) -> None:
        specs = self._specs(
            tmp_path,
            "PS-FF",
            [
                json.dumps({"step": "implement", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "error", "data": {}}),
            ],
        )
        assert _derive_plan_success("PS-FF", specs) is True

    def test_returns_none_on_empty_file(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(tmp_path, "PS-EMPTY", "")
        assert _derive_plan_success("PS-EMPTY", specs) is None


# ===========================================================================
# Task 5 — _build_trace_tags(): CC_MODEL_ROLE + CC_MODEL_ENDPOINT injection
# ===========================================================================


def test_build_trace_tags_endpoint_open_tag_present(monkeypatch: pytest.MonkeyPatch) -> None:
    """When CC_MODEL_ENDPOINT='open', an endpoint:open tag must appear."""
    monkeypatch.setenv("CC_MODEL_ENDPOINT", "open")
    ctx = _minimal_ctx(
        model_role=os.environ.get("CC_MODEL_ROLE", "").strip() or None,
        model_endpoint=os.environ.get("CC_MODEL_ENDPOINT", "").strip() or None,
    )
    tags = _build_trace_tags(ctx, _minimal_turn())
    assert "endpoint:open" in tags


@pytest.mark.xfail(
    strict=False,
    reason=(
        "Task 3 (goal-mode, issue #12): _build_trace_tags() not yet using "
        "camelCase 'modelRole:<role>' format — currently emits 'model_role:<role>'. "
        "Remove this xfail once goal-mode task 3 renames the tag to modelRole:."
    ),
)
def test_build_trace_tags_model_role_uses_camel_case_modelRole(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When CC_MODEL_ROLE='coder', a modelRole:coder tag must appear (camelCase)."""
    monkeypatch.setenv("CC_MODEL_ROLE", "coder")
    monkeypatch.setenv("CC_MODEL_ENDPOINT", "open")
    ctx = _minimal_ctx(
        model_role=os.environ.get("CC_MODEL_ROLE", "").strip() or None,
        model_endpoint=os.environ.get("CC_MODEL_ENDPOINT", "").strip() or None,
    )
    tags = _build_trace_tags(ctx, _minimal_turn())
    # Checks for camelCase format as specified by task 3 (goal-mode).
    assert "modelRole:coder" in tags
    assert "endpoint:open" in tags
