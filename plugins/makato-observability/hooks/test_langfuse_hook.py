"""Unit tests for langfuse_hook.py — issue #12 tasks 1, 2, 3, 4, and 5.

Covered:
  - _read_build_signals(): all six signal paths, missing/empty file, edge cases
  - _derive_plan_success(): True / False / None from fixture JSONL
  - TraceContext.build_signals field wiring (task 2)
  - emit_turn() includes build_signals in trace_metadata when set (task 2)
  - _build_trace_tags(): CC_MODEL_ROLE (camelCase modelRole:) + CC_MODEL_ENDPOINT injection,
    and endpoint fallback via model-string pattern detection (task 3)

No live Langfuse credentials are required.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
    _check_langfuse_reachable,
    _derive_plan_success,
    _read_build_signals,
    emit_turn,
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
        # 6. merged_without_override → True  (override=False means no override applied)
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
        specs = _write_build_jsonl(tmp_path, "KEY-VF", json.dumps({"step": "verify", "status": "error", "data": {}}))
        assert _read_build_signals("KEY-VF", specs).verify_gate_passed is False

    def test_ci_failed(self, tmp_path: Path) -> None:
        specs = _write_build_jsonl(tmp_path, "KEY-CF", json.dumps({"step": "ci", "status": "error", "data": {}}))
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
        """A verify step that appears before any implement step must be skipped."""
        specs = self._specs(
            tmp_path,
            "PS-PRE",
            [
                json.dumps({"step": "verify", "status": "ok", "data": {}}),
                json.dumps({"step": "implement", "status": "ok", "data": {}}),
                json.dumps({"step": "verify", "status": "error", "data": {}}),
            ],
        )
        # Pre-implement verify is skipped; the post-implement one is "error"
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
# Task 2 — BuildSignals wired into TraceContext and emit_turn()
# ===========================================================================


class TestTraceContextBuildSignals:
    """Structural tests for the build_signals field on TraceContext (task 2)."""

    def test_trace_context_accepts_build_signals_field(self) -> None:
        """TraceContext can be constructed with a BuildSignals instance."""
        signals = BuildSignals(verify_gate_passed=True, ci_green=True)
        ctx = _minimal_ctx(build_signals=signals)
        assert ctx.build_signals is signals

    def test_trace_context_build_signals_defaults_to_none(self) -> None:
        """build_signals is None when not supplied — backwards-compatible default."""
        ctx = _minimal_ctx()
        assert ctx.build_signals is None

    def test_trace_context_build_signals_partial_population(self) -> None:
        """Only the fields that were set in BuildSignals are non-None."""
        signals = BuildSignals(verify_gate_passed=False)
        ctx = _minimal_ctx(build_signals=signals)
        assert ctx.build_signals is not None
        assert ctx.build_signals.verify_gate_passed is False
        assert ctx.build_signals.ci_green is None
        assert ctx.build_signals.review_critical_count is None


def _turn_with_assistant(model: str = "claude-3-sonnet") -> Turn:
    """Minimal Turn carrying one assistant message — enough for emit_turn()."""
    return Turn(
        user_msg={"type": "user", "message": {"role": "user", "content": "hi"}},
        assistant_msgs=[
            {
                "type": "assistant",
                "message": {"role": "assistant", "content": "hello", "model": model},
            }
        ],
        tool_results_by_id={},
    )


def test_emit_turn_adds_build_signals_to_trace_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """emit_turn() must add a 'build_signals' sub-key to the outer trace metadata
    when ctx.build_signals is set, containing only the non-None signal fields."""
    import contextlib
    from unittest.mock import MagicMock, patch

    captured: dict = {}

    @contextlib.contextmanager
    def fake_observation(**kwargs):  # type: ignore[no-untyped-def]
        # Capture the kwargs of the first (outer trace-span) call.
        if not captured:
            captured.update(kwargs)
        obs = MagicMock()
        obs.update = MagicMock()
        yield obs

    mock_langfuse = MagicMock()
    mock_langfuse.start_as_current_observation = fake_observation

    signals = BuildSignals(verify_gate_passed=True, ci_green=True, coder_retry_count=2)
    ctx = _minimal_ctx(build_signals=signals)
    turn = _turn_with_assistant()

    with patch("langfuse_hook.propagate_attributes", return_value=contextlib.nullcontext()):
        emit_turn(mock_langfuse, 1, turn, ctx)

    metadata = captured.get("metadata", {})
    assert "build_signals" in metadata, f"'build_signals' missing from metadata: {metadata}"
    bsig = metadata["build_signals"]
    assert bsig["verify_gate_passed"] is True
    assert bsig["ci_green"] is True
    assert bsig["coder_retry_count"] == 2
    # Fields that are None must be excluded from the sub-key (sparse representation).
    assert "review_critical_count" not in bsig
    assert "conflict_halt_count" not in bsig
    assert "merged_without_override" not in bsig


def test_emit_turn_omits_build_signals_key_when_ctx_is_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When ctx.build_signals is None the 'build_signals' key must be absent from metadata."""
    import contextlib
    from unittest.mock import MagicMock, patch

    captured: dict = {}

    @contextlib.contextmanager
    def fake_observation(**kwargs):  # type: ignore[no-untyped-def]
        if not captured:
            captured.update(kwargs)
        obs = MagicMock()
        obs.update = MagicMock()
        yield obs

    mock_langfuse = MagicMock()
    mock_langfuse.start_as_current_observation = fake_observation

    ctx = _minimal_ctx()  # build_signals defaults to None
    turn = _turn_with_assistant()

    with patch("langfuse_hook.propagate_attributes", return_value=contextlib.nullcontext()):
        emit_turn(mock_langfuse, 1, turn, ctx)

    assert "build_signals" not in captured.get("metadata", {})


def test_emit_turn_omits_build_signals_key_when_all_fields_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When build_signals is set but every field is None, the 'build_signals' key must be absent
    (the sparse representation omits the sub-key entirely rather than emitting an empty dict)."""
    import contextlib
    from unittest.mock import MagicMock, patch

    captured: dict = {}

    @contextlib.contextmanager
    def fake_observation(**kwargs):  # type: ignore[no-untyped-def]
        if not captured:
            captured.update(kwargs)
        obs = MagicMock()
        obs.update = MagicMock()
        yield obs

    mock_langfuse = MagicMock()
    mock_langfuse.start_as_current_observation = fake_observation

    ctx = _minimal_ctx(build_signals=BuildSignals())  # all fields None
    turn = _turn_with_assistant()

    with patch("langfuse_hook.propagate_attributes", return_value=contextlib.nullcontext()):
        emit_turn(mock_langfuse, 1, turn, ctx)

    assert "build_signals" not in captured.get("metadata", {})


# ===========================================================================
# Task 3 — _build_trace_tags(): modelRole camelCase + endpoint fallback
# ===========================================================================


def test_build_trace_tags_endpoint_fallback_open_for_llama_model() -> None:
    """When CC_MODEL_ENDPOINT is unset and the model identifier contains 'llama',
    _build_trace_tags() must emit 'endpoint:open' via the fallback path."""
    ctx = _minimal_ctx(model_role=None, model_endpoint=None)
    turn = Turn(
        user_msg={},
        assistant_msgs=[{"message": {"role": "assistant", "model": "meta-llama-3-8b-instruct"}}],
        tool_results_by_id={},
    )
    tags = _build_trace_tags(ctx, turn)
    assert "endpoint:open" in tags


def test_build_trace_tags_endpoint_fallback_closed_for_claude_model() -> None:
    """When CC_MODEL_ENDPOINT is unset and the model identifier does not match any
    open-weight pattern, _build_trace_tags() must emit 'endpoint:closed'."""
    ctx = _minimal_ctx(model_role=None, model_endpoint=None)
    turn = Turn(
        user_msg={},
        assistant_msgs=[{"message": {"role": "assistant", "model": "claude-3-5-sonnet-20241022"}}],
        tool_results_by_id={},
    )
    tags = _build_trace_tags(ctx, turn)
    assert "endpoint:closed" in tags


def test_build_trace_tags_explicit_endpoint_overrides_fallback() -> None:
    """An explicit ctx.model_endpoint value takes precedence over the model-string fallback."""
    ctx = _minimal_ctx(model_role=None, model_endpoint="open")
    # Even though the model is 'claude-*' (which would default to 'closed'),
    # the explicit endpoint value must win.
    turn = Turn(
        user_msg={},
        assistant_msgs=[{"message": {"role": "assistant", "model": "claude-3-sonnet"}}],
        tool_results_by_id={},
    )
    tags = _build_trace_tags(ctx, turn)
    assert "endpoint:open" in tags


def test_build_trace_tags_endpoint_always_present_even_without_role() -> None:
    """endpoint: tag must appear on every trace turn, even when model_role is not set."""
    ctx = _minimal_ctx(model_role=None, model_endpoint=None)
    tags = _build_trace_tags(ctx, _minimal_turn())
    endpoint_tags = [t for t in tags if t.startswith("endpoint:")]
    assert len(endpoint_tags) == 1


# ===========================================================================
# Task 5 — _build_trace_tags(): CC_MODEL_ROLE + CC_MODEL_ENDPOINT injection
# ===========================================================================


def test_build_trace_tags_endpoint_open_tag_present(monkeypatch: pytest.MonkeyPatch) -> None:
    """When CC_MODEL_ENDPOINT='open', an 'endpoint:open' tag must appear."""
    monkeypatch.setenv("CC_MODEL_ENDPOINT", "open")
    ctx = _minimal_ctx(
        model_role=os.environ.get("CC_MODEL_ROLE", "").strip() or None,
        model_endpoint=os.environ.get("CC_MODEL_ENDPOINT", "").strip() or None,
    )
    tags = _build_trace_tags(ctx, _minimal_turn())
    assert "endpoint:open" in tags


def test_build_trace_tags_model_role_uses_camel_case_modelRole(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When CC_MODEL_ROLE='coder', a 'modelRole:coder' tag must appear (camelCase)."""
    monkeypatch.setenv("CC_MODEL_ROLE", "coder")
    monkeypatch.setenv("CC_MODEL_ENDPOINT", "open")
    ctx = _minimal_ctx(
        model_role=os.environ.get("CC_MODEL_ROLE", "").strip() or None,
        model_endpoint=os.environ.get("CC_MODEL_ENDPOINT", "").strip() or None,
    )
    tags = _build_trace_tags(ctx, _minimal_turn())
    # Checks for camelCase format as specified by task 3 (goal-mode, issue #12).
    assert "modelRole:coder" in tags
    assert "endpoint:open" in tags


# ---------------------------------------------------------------------------
# Health endpoint security boundaries
# ---------------------------------------------------------------------------


@contextmanager
def _health_server(
    *,
    status: int = 200,
    body: bytes = b'{"status":"ok"}',
    location: str | None = None,
    paths: list[str] | None = None,
) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if paths is not None:
                paths.append(self.path)
            if self.path == "/api/public/health" and location is not None:
                self.send_response(302)
                self.send_header("Location", location)
                self.end_headers()
                return
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *_args: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_check_langfuse_reachable_http_success() -> None:
    with _health_server() as host:
        assert _check_langfuse_reachable(host, timeout=1) is True


def test_check_langfuse_reachable_http_failure_and_missing_status() -> None:
    with _health_server(status=503) as host:
        assert _check_langfuse_reachable(host, timeout=1) is False
    with _health_server(body=b'{"error":"unhealthy"}') as host:
        assert _check_langfuse_reachable(host, timeout=1) is False


def test_check_langfuse_reachable_rejects_file_and_ftp_schemes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    health_file = tmp_path / "api" / "public" / "health"
    health_file.parent.mkdir(parents=True)
    health_file.write_text('{"status":"ok"}', encoding="utf-8")
    attempts: list[object] = []

    def record_opener(*args: object) -> object:
        attempts.append(args)
        return object()

    monkeypatch.setattr("urllib.request.build_opener", record_opener)

    assert _check_langfuse_reachable(tmp_path.as_uri()) is False
    assert _check_langfuse_reachable("ftp://127.0.0.1:0") is False
    assert attempts == []


def test_check_langfuse_reachable_accepts_https(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Response:
        status = 200

        def __enter__(self) -> Response:
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def read(self) -> bytes:
            return b'{"status":"ok"}'

    class Opener:
        def open(self, _request: object, timeout: float) -> Response:
            assert timeout == 0.25
            return Response()

    monkeypatch.setattr("urllib.request.build_opener", lambda _handler: Opener())
    assert _check_langfuse_reachable("https://langfuse.example", timeout=0.25) is True


def test_check_langfuse_reachable_passes_timeout_and_fails_open(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class TimedOutOpener:
        def open(self, _request: object, timeout: float) -> None:
            assert timeout == 0.01
            raise TimeoutError("timeout")

    monkeypatch.setattr("urllib.request.build_opener", lambda _handler: TimedOutOpener())
    assert _check_langfuse_reachable("http://langfuse.example", timeout=0.01) is False


def test_check_langfuse_reachable_allows_same_origin_redirect() -> None:
    with _health_server(location="/health-redirect-target") as host:
        assert _check_langfuse_reachable(host, timeout=1) is True


def test_check_langfuse_reachable_rejects_cross_origin_redirect() -> None:
    target_paths: list[str] = []
    with _health_server(paths=target_paths) as target:
        with _health_server(location=f"{target}/api/public/health") as source:
            assert _check_langfuse_reachable(source, timeout=1) is False
    assert target_paths == []


def test_check_langfuse_reachable_rejects_file_redirect(tmp_path: Path) -> None:
    health_file = tmp_path / "redirect-health.json"
    health_file.write_text('{"status":"ok"}', encoding="utf-8")
    with _health_server(location=health_file.as_uri()) as host:
        assert _check_langfuse_reachable(host, timeout=1) is False
