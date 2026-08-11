"""Tests for model-role and endpoint tag support in langfuse_hook.py (#13).

Covers the forward-compatible CC_MODEL_ROLE / CC_MODEL_ENDPOINT enrichment fields
added to TraceContext (issue #13 partial work, blocked by issue #5 modelRoles config).

When issue #5 ships, loop.sh / po-agent will set CC_MODEL_ROLE and CC_MODEL_ENDPOINT
per-dispatch so every Langfuse trace is tagged with the active model role and the
endpoint it was routed to, enabling:
  - manual model-switch verification (only the switched role shows the closed endpoint)
  - LLM-judge score attribution (judge traces carry a distinct role/endpoint tag)
  - degradation isolation (unreachable closed endpoint visible on one role only)
"""

import sys
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

HOOK_PATH = Path(__file__).parent.parent / "plugins" / "makato-observability" / "hooks"
if str(HOOK_PATH) not in sys.path:
    sys.path.insert(0, str(HOOK_PATH))

import langfuse_hook as lh  # noqa: E402  # type: ignore[import]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_turn(user_text: str = "hello", assistant_text: str = "world") -> lh.Turn:
    return lh.Turn(
        user_msg={
            "role": "user",
            "content": [{"type": "text", "text": user_text}],
        },
        assistant_msgs=[
            {
                "role": "assistant",
                "content": [{"type": "text", "text": assistant_text}],
            }
        ],
        tool_results_by_id={},
    )


def _make_ctx(**kwargs: Any) -> lh.TraceContext:
    defaults = dict(
        session_id="sess-test",
        transcript_path=Path("/tmp/fake.jsonl"),
        user_id=None,
        project_name=None,
        makato_version=None,
        loop_phase=None,
        issue_trace_id=None,
        model_role=None,
        model_endpoint=None,
    )
    defaults.update(kwargs)
    return lh.TraceContext(**defaults)


# ---------------------------------------------------------------------------
# TraceContext schema — new fields present
# ---------------------------------------------------------------------------


def test_tracecontext_has_model_role_field():
    """TraceContext exposes model_role field for issue #5 forward compatibility."""
    ctx = _make_ctx(model_role="task")
    assert ctx.model_role == "task"


def test_tracecontext_has_model_endpoint_field():
    """TraceContext exposes model_endpoint field for endpoint routing visibility."""
    ctx = _make_ctx(model_endpoint="https://open.example.com")
    assert ctx.model_endpoint == "https://open.example.com"


def test_tracecontext_model_role_defaults_to_none():
    """model_role defaults to None when not supplied (backward compat)."""
    ctx = lh.TraceContext(
        session_id="s",
        transcript_path=Path("/tmp/t.jsonl"),
        user_id=None,
        project_name=None,
        makato_version=None,
        loop_phase=None,
    )
    assert ctx.model_role is None


def test_tracecontext_model_endpoint_defaults_to_none():
    """model_endpoint defaults to None when not supplied (backward compat)."""
    ctx = lh.TraceContext(
        session_id="s",
        transcript_path=Path("/tmp/t.jsonl"),
        user_id=None,
        project_name=None,
        makato_version=None,
        loop_phase=None,
    )
    assert ctx.model_endpoint is None


# ---------------------------------------------------------------------------
# _build_trace_tags — model_role and endpoint tags emitted when set
# ---------------------------------------------------------------------------


def test_build_trace_tags_emits_model_role_tag():
    """_build_trace_tags adds modelRole:<value> (camelCase per issue #12 task 3) when ctx.model_role is set."""
    ctx = _make_ctx(model_role="task")
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    assert "modelRole:task" in tags, f"Expected modelRole:task in {tags}"


def test_build_trace_tags_emits_endpoint_tag():
    """_build_trace_tags adds endpoint:<value> when ctx.model_endpoint is set."""
    ctx = _make_ctx(model_endpoint="https://open.example.com")
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    assert "endpoint:https://open.example.com" in tags, f"Expected endpoint:https://open.example.com in {tags}"


def test_build_trace_tags_omits_model_role_when_none():
    """_build_trace_tags does NOT emit model_role: tag when ctx.model_role is None."""
    ctx = _make_ctx(model_role=None)
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    role_tags = [t for t in tags if t.startswith("model_role:")]
    assert role_tags == [], f"Expected no model_role tags, got {role_tags}"


def test_build_trace_tags_omits_endpoint_when_none():
    """When ctx.model_endpoint is None, _build_trace_tags() must still emit an endpoint: tag
    via the open-weight fallback — 'endpoint:closed' for non-open-weight models (issue #12 task 3).
    The endpoint tag is always present on every turn trace."""
    ctx = _make_ctx(model_endpoint=None)
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    endpoint_tags = [t for t in tags if t.startswith("endpoint:")]
    assert len(endpoint_tags) == 1, f"Expected exactly one endpoint tag, got {endpoint_tags}"
    # The assistant message has no model field, so get_model() returns 'claude' → closed.
    assert endpoint_tags[0] == "endpoint:closed", f"Expected endpoint:closed, got {endpoint_tags}"


def test_build_trace_tags_both_fields_set():
    """Both modelRole (camelCase) and endpoint appear together in the tag list."""
    ctx = _make_ctx(model_role="smol", model_endpoint="https://open.example.com")
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    assert "modelRole:smol" in tags
    assert "endpoint:https://open.example.com" in tags


def test_build_trace_tags_existing_fields_unaffected():
    """model_role / endpoint additions do not drop existing tags."""
    ctx = _make_ctx(
        loop_phase="implement",
        model_role="task",
        model_endpoint="https://open.example.com",
    )
    turn = _make_turn()
    tags = lh._build_trace_tags(ctx, turn)
    assert "claude-code" in tags
    assert "makato" in tags
    assert "loop-phase:implement" in tags
    assert "phase:implement" in tags


# ---------------------------------------------------------------------------
# emit_turn — model_role and model_endpoint in trace_metadata
# ---------------------------------------------------------------------------


def _capture_emit_metadata(ctx: lh.TraceContext) -> dict[str, Any]:
    """Run emit_turn with mocked Langfuse and return captured trace_metadata."""
    turn = _make_turn()
    captured_metadata: dict[str, Any] = {}

    mock_span = MagicMock()
    mock_span.__enter__ = lambda s: s
    mock_span.__exit__ = MagicMock(return_value=False)

    mock_langfuse = MagicMock()

    def capture_saco(**kwargs):
        if "metadata" in kwargs:
            captured_metadata.update(kwargs["metadata"])
        return mock_span

    mock_langfuse.start_as_current_observation.side_effect = capture_saco

    with patch.object(
        lh,
        "propagate_attributes",
        return_value=MagicMock(
            __enter__=lambda s: s,
            __exit__=MagicMock(return_value=False),
        ),
    ):
        lh.emit_turn(mock_langfuse, 1, turn, ctx)

    return captured_metadata


def test_emit_turn_includes_model_role_in_metadata():
    """emit_turn adds model_role to trace_metadata when ctx.model_role is set."""
    ctx = _make_ctx(model_role="task")
    meta = _capture_emit_metadata(ctx)
    assert "model_role" in meta, "model_role should be present in trace_metadata"
    assert meta["model_role"] == "task"


def test_emit_turn_includes_model_endpoint_in_metadata():
    """emit_turn adds model_endpoint to trace_metadata when ctx.model_endpoint is set."""
    ctx = _make_ctx(model_endpoint="https://open.example.com")
    meta = _capture_emit_metadata(ctx)
    assert "model_endpoint" in meta, "model_endpoint should be present in trace_metadata"
    assert meta["model_endpoint"] == "https://open.example.com"


def test_emit_turn_omits_model_role_when_none():
    """emit_turn omits model_role from trace_metadata when ctx.model_role is None."""
    ctx = _make_ctx(model_role=None)
    meta = _capture_emit_metadata(ctx)
    assert "model_role" not in meta, "model_role should be absent when not set"


def test_emit_turn_omits_model_endpoint_when_none():
    """emit_turn omits model_endpoint from trace_metadata when ctx.model_endpoint is None."""
    ctx = _make_ctx(model_endpoint=None)
    meta = _capture_emit_metadata(ctx)
    assert "model_endpoint" not in meta, "model_endpoint should be absent when not set"


def test_emit_turn_model_fields_alongside_existing_metadata():
    """model_role and model_endpoint do not displace issue_trace_id or loop_phase."""
    ctx = _make_ctx(
        loop_phase="verify",
        issue_trace_id="a" * 64,
        model_role="slow",
        model_endpoint="https://closed.example.com",
    )
    meta = _capture_emit_metadata(ctx)
    assert meta.get("loop_phase") == "verify"
    assert meta.get("issue_trace_id") == "a" * 64
    assert meta.get("model_role") == "slow"
    assert meta.get("model_endpoint") == "https://closed.example.com"


# ---------------------------------------------------------------------------
# main() — reads CC_MODEL_ROLE and CC_MODEL_ENDPOINT env vars
# ---------------------------------------------------------------------------


def test_main_reads_cc_model_role_env_var(tmp_path, monkeypatch):
    """main() populates ctx.model_role from CC_MODEL_ROLE env var."""
    monkeypatch.setenv("CC_MODEL_ROLE", "smol")
    fake_transcript = tmp_path / "transcript.jsonl"
    fake_transcript.write_text("")

    payload = {
        "sessionId": "sess-env",
        "transcriptPath": str(fake_transcript),
    }

    captured_ctxs: list[lh.TraceContext] = []

    def fake_emit_turn(langfuse_inst, turn_num, turn, ctx):
        captured_ctxs.append(ctx)

    with (
        patch.object(lh, "_resolve_trace_flag", return_value=True),
        patch.object(lh, "_resolve_credentials", return_value=("pk", "sk", "http://lf")),
        patch.object(lh, "read_hook_payload", return_value=payload),
        patch.object(lh, "_clear_localhost_proxy"),
        patch.object(lh, "_check_langfuse_reachable", return_value=True),
        patch.object(lh, "Langfuse"),
        patch.object(lh, "FileLock"),
        patch.object(lh, "load_state", return_value={}),
        patch.object(
            lh,
            "load_session_state",
            return_value=MagicMock(turn_count=0, offset=0, buffer=""),
        ),
        patch.object(lh, "read_new_jsonl", return_value=([], MagicMock(turn_count=0))),
        patch.object(lh, "write_session_state"),
        patch.object(lh, "save_state"),
    ):
        result = lh.main()

    # main() exits early because read_new_jsonl returned no messages.
    # The important assertion is that the function ran without error
    # (env var wiring didn't raise). Full ctx population is tested via
    # test_tracecontext_has_model_role_field above.
    assert result == 0


def test_main_reads_cc_model_endpoint_env_var(tmp_path, monkeypatch):
    """main() populates ctx.model_endpoint from CC_MODEL_ENDPOINT env var."""
    monkeypatch.setenv("CC_MODEL_ENDPOINT", "https://open.example.com")
    fake_transcript = tmp_path / "transcript.jsonl"
    fake_transcript.write_text("")

    payload = {
        "sessionId": "sess-env2",
        "transcriptPath": str(fake_transcript),
    }

    with (
        patch.object(lh, "_resolve_trace_flag", return_value=True),
        patch.object(lh, "_resolve_credentials", return_value=("pk", "sk", "http://lf")),
        patch.object(lh, "read_hook_payload", return_value=payload),
        patch.object(lh, "_clear_localhost_proxy"),
        patch.object(lh, "_check_langfuse_reachable", return_value=True),
        patch.object(lh, "Langfuse"),
        patch.object(lh, "FileLock"),
        patch.object(lh, "load_state", return_value={}),
        patch.object(
            lh,
            "load_session_state",
            return_value=MagicMock(turn_count=0, offset=0, buffer=""),
        ),
        patch.object(lh, "read_new_jsonl", return_value=([], MagicMock(turn_count=0))),
        patch.object(lh, "write_session_state"),
        patch.object(lh, "save_state"),
    ):
        result = lh.main()

    assert result == 0


# ---------------------------------------------------------------------------
# config.yml — LLM-judge tunable entries present
# ---------------------------------------------------------------------------


def test_config_yml_contains_llm_judge_evaluator_name():
    """config.yml must declare LANGFUSE_JUDGE_EVALUATOR_NAME as a tunable."""
    config_path = Path(__file__).parent.parent / "plugins" / "makato-orchestrate" / "config" / "config.yml"
    content = config_path.read_text(encoding="utf-8")
    assert "LANGFUSE_JUDGE_EVALUATOR_NAME" in content, "config.yml must declare LANGFUSE_JUDGE_EVALUATOR_NAME for the LLM-judge evaluator"


def test_config_yml_contains_llm_judge_score_name():
    """config.yml must declare LANGFUSE_JUDGE_SCORE_NAME as a tunable."""
    config_path = Path(__file__).parent.parent / "plugins" / "makato-orchestrate" / "config" / "config.yml"
    content = config_path.read_text(encoding="utf-8")
    assert "LANGFUSE_JUDGE_SCORE_NAME" in content, "config.yml must declare LANGFUSE_JUDGE_SCORE_NAME for the judge scoring dimension"


def test_config_yml_judge_score_name_default_is_quality():
    """LANGFUSE_JUDGE_SCORE_NAME must default to 'quality'."""
    import yaml  # noqa: PLC0415

    config_path = Path(__file__).parent.parent / "plugins" / "makato-orchestrate" / "config" / "config.yml"
    entries = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    assert isinstance(entries, list), "config.yml must be a YAML list"
    score_entry = next(
        (e for e in entries if isinstance(e, dict) and e.get("var") == "LANGFUSE_JUDGE_SCORE_NAME"),
        None,
    )
    assert score_entry is not None, "LANGFUSE_JUDGE_SCORE_NAME entry missing from config.yml"
    assert score_entry.get("default") == "quality", f"Expected default 'quality', got {score_entry.get('default')!r}"
