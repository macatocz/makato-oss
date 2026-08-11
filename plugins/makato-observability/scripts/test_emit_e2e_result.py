"""test_emit_e2e_result.py — Unit tests for emit_e2e_result.py.

Tests run without a live Langfuse instance and without a running sagibeast
stack — all network I/O is mocked.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Add the scripts directory to sys.path so the module imports cleanly.
_SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(_SCRIPTS_DIR))

import emit_e2e_result as mod  # noqa: E402  (after path manipulation)


# ---------------------------------------------------------------------------
# _parse_dotenv
# ---------------------------------------------------------------------------

def test_parse_dotenv_simple(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("LANGFUSE_PUBLIC_KEY=pk_test\nLANGFUSE_SECRET_KEY=sk_test\n")
    result = mod._parse_dotenv(env_file)
    assert result["LANGFUSE_PUBLIC_KEY"] == "pk_test"
    assert result["LANGFUSE_SECRET_KEY"] == "sk_test"


def test_parse_dotenv_ignores_comments(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("# comment\nKEY=value\n")
    result = mod._parse_dotenv(env_file)
    assert result == {"KEY": "value"}


def test_parse_dotenv_missing_file() -> None:
    result = mod._parse_dotenv(Path("/nonexistent/.env"))
    assert result == {}


# ---------------------------------------------------------------------------
# _resolve_credentials — env-var priority
# ---------------------------------------------------------------------------

def test_resolve_credentials_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LANGFUSE_PUBLIC_KEY", "pk_env")
    monkeypatch.setenv("LANGFUSE_SECRET_KEY", "sk_env")
    monkeypatch.setenv("LANGFUSE_HOST", "http://langfuse.example.com")
    pk, sk, host = mod._resolve_credentials()
    assert pk == "pk_env"
    assert sk == "sk_env"
    assert host == "http://langfuse.example.com"


def test_resolve_credentials_missing_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("LANGFUSE_PUBLIC_KEY", raising=False)
    monkeypatch.delenv("LANGFUSE_SECRET_KEY", raising=False)
    monkeypatch.delenv("LANGFUSE_HOST", raising=False)
    with patch.object(mod, "_find_dotenv", return_value={}):
        with patch.object(mod, "_read_zshrc_exports", return_value={}):
            pk, sk, host = mod._resolve_credentials()
    assert pk is None
    assert sk is None
    assert host == ""


# ---------------------------------------------------------------------------
# _check_langfuse_reachable
# ---------------------------------------------------------------------------

def test_check_langfuse_reachable_ok() -> None:
    mock_resp = MagicMock()
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)
    mock_resp.read.return_value = b'{"status":"ok"}'
    with patch("urllib.request.urlopen", return_value=mock_resp):
        assert mod._check_langfuse_reachable("http://langfuse.example.com") is True


def test_check_langfuse_reachable_timeout() -> None:
    with patch("urllib.request.urlopen", side_effect=TimeoutError("timeout")):
        assert mod._check_langfuse_reachable("http://langfuse.example.com") is False


def test_check_langfuse_reachable_missing_status_field() -> None:
    mock_resp = MagicMock()
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)
    mock_resp.read.return_value = b'{"error":"not found"}'
    with patch("urllib.request.urlopen", return_value=mock_resp):
        assert mod._check_langfuse_reachable("http://langfuse.example.com") is False


# ---------------------------------------------------------------------------
# _find_build_jsonl
# ---------------------------------------------------------------------------

def test_find_build_jsonl_with_key(tmp_path: Path) -> None:
    specs = tmp_path / "specs"
    spec_dir = specs / "mykey-some-feature"
    spec_dir.mkdir(parents=True)
    jsonl = spec_dir / "build.jsonl"
    jsonl.write_text("")
    result = mod._find_build_jsonl("mykey", specs)
    assert result == jsonl


def test_find_build_jsonl_no_key_picks_most_recent(tmp_path: Path) -> None:
    specs = tmp_path / "specs"
    old_dir = specs / "old-feature"
    new_dir = specs / "new-feature"
    old_dir.mkdir(parents=True)
    new_dir.mkdir(parents=True)
    old_jsonl = old_dir / "build.jsonl"
    new_jsonl = new_dir / "build.jsonl"
    old_jsonl.write_text("")
    new_jsonl.write_text("")
    # Touch new_jsonl to make it newer
    import time; time.sleep(0.01)
    new_jsonl.touch()
    result = mod._find_build_jsonl(None, specs)
    assert result == new_jsonl


def test_find_build_jsonl_returns_none_when_absent(tmp_path: Path) -> None:
    specs = tmp_path / "specs"
    specs.mkdir()
    assert mod._find_build_jsonl("nonexistent", specs) is None


# ---------------------------------------------------------------------------
# _read_last_runtime_qa_finding
# ---------------------------------------------------------------------------

def test_read_last_runtime_qa_finding_returns_last(tmp_path: Path) -> None:
    jsonl_path = tmp_path / "build.jsonl"
    entries = [
        {"ts": "2026-01-01T00:00:00Z", "step": "runtime-qa-findings", "data": {"outcome": "pass"}},
        {"ts": "2026-01-01T01:00:00Z", "step": "some-other-step", "data": {}},
        {"ts": "2026-01-01T02:00:00Z", "step": "runtime-qa-findings", "data": {"outcome": "fail"}},
    ]
    jsonl_path.write_text("\n".join(json.dumps(e) for e in entries))
    result = mod._read_last_runtime_qa_finding(jsonl_path)
    assert result is not None
    assert result["data"]["outcome"] == "fail"


def test_read_last_runtime_qa_finding_returns_none_when_absent(tmp_path: Path) -> None:
    jsonl_path = tmp_path / "build.jsonl"
    jsonl_path.write_text(json.dumps({"step": "verify", "data": {}}))
    result = mod._read_last_runtime_qa_finding(jsonl_path)
    assert result is None


def test_read_last_runtime_qa_finding_skips_malformed_lines(tmp_path: Path) -> None:
    jsonl_path = tmp_path / "build.jsonl"
    jsonl_path.write_text(
        'not-json\n{"step":"runtime-qa-findings","data":{"outcome":"pass"}}\n'
    )
    result = mod._read_last_runtime_qa_finding(jsonl_path)
    assert result is not None
    assert result["data"]["outcome"] == "pass"


# ---------------------------------------------------------------------------
# _emit_trace (dry-run path)
# ---------------------------------------------------------------------------

def test_emit_trace_dry_run_prints_payload(capsys: pytest.CaptureFixture[str]) -> None:
    finding = {
        "ts": "2026-01-01T00:00:00Z",
        "story": "test-story",
        "step": "runtime-qa-findings",
        "data": {"outcome": "pass", "critical_count": 0, "summary": "All checks passed"},
    }
    mod._emit_trace("pk", "sk", "http://langfuse.example.com", finding, dry_run=True)
    captured = capsys.readouterr()
    payload = json.loads(captured.out.replace("[emit_e2e_result] DRY-RUN — trace payload:\n", "").strip())
    assert payload["name"] == "e2e-result:test-story"
    assert payload["metadata"]["outcome"] == "pass"


def test_emit_trace_live_calls_langfuse(monkeypatch: pytest.MonkeyPatch) -> None:
    mock_trace = MagicMock()
    mock_trace.id = "trace-abc-123"
    mock_client = MagicMock()
    mock_client.trace.return_value = mock_trace
    mock_langfuse_cls = MagicMock(return_value=mock_client)

    finding = {
        "ts": "2026-01-01T00:00:00Z",
        "story": "my-story",
        "step": "runtime-qa-findings",
        "data": {"outcome": "fail", "critical_count": 1},
    }

    with patch.dict(sys.modules, {"langfuse": MagicMock(Langfuse=mock_langfuse_cls)}):
        mod._emit_trace("pk", "sk", "http://langfuse.example.com", finding, dry_run=False)

    mock_langfuse_cls.assert_called_once_with(
        public_key="pk", secret_key="sk", host="http://langfuse.example.com"
    )
    mock_client.trace.assert_called_once()
    mock_client.flush.assert_called_once()
