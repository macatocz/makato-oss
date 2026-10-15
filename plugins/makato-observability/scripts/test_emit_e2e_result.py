"""test_emit_e2e_result.py — Unit tests for emit_e2e_result.py.

Tests run without a live Langfuse instance or a running sagibeast stack.
Health endpoint probes use isolated local HTTP servers; external Langfuse I/O is mocked.
"""

from __future__ import annotations

import json
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
    mock_resp.status = 200
    mock_resp.read.return_value = b'{"status":"ok"}'
    mock_opener = MagicMock()
    mock_opener.open.return_value = mock_resp
    with patch("urllib.request.build_opener", return_value=mock_opener):
        assert mod._check_langfuse_reachable("http://langfuse.example.com") is True


def test_check_langfuse_reachable_timeout() -> None:
    mock_opener = MagicMock()
    mock_opener.open.side_effect = TimeoutError("timeout")
    with patch("urllib.request.build_opener", return_value=mock_opener):
        assert mod._check_langfuse_reachable("http://langfuse.example.com") is False
        assert mock_opener.open.call_args.kwargs["timeout"] == 3.0


def test_check_langfuse_reachable_missing_status_field() -> None:
    mock_resp = MagicMock()
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)
    mock_resp.status = 200
    mock_resp.read.return_value = b'{"error":"not found"}'
    mock_opener = MagicMock()
    mock_opener.open.return_value = mock_resp
    with patch("urllib.request.build_opener", return_value=mock_opener):
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
    import time

    time.sleep(0.01)
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
    jsonl_path.write_text('not-json\n{"step":"runtime-qa-findings","data":{"outcome":"pass"}}\n')
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


def test_emit_trace_exports_real_sdk_span(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    import gzip
    import uuid

    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest

    payloads: list[bytes] = []

    class Collector(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            payloads.append(body)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, format: str, *args: object) -> None:
            return

    monkeypatch.setenv("LANGFUSE_TRACING_ENABLED", "true")
    monkeypatch.setenv("LANGFUSE_SAMPLE_RATE", "1")
    monkeypatch.delenv("OTEL_SDK_DISABLED", raising=False)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Collector)
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    worker.start()
    finding = {"story": "my-story", "data": {"outcome": "fail", "critical_count": 1, "summary": "Regression caught"}}
    try:
        mod._emit_trace(f"pk-test-{uuid.uuid4().hex}", "sk-test-local", f"http://127.0.0.1:{server.server_port}", finding, dry_run=False)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()

    spans = [span for body in payloads for resource in ExportTraceServiceRequest.FromString(body).resource_spans for scope in resource.scope_spans for span in scope.spans]
    emitted = [span for span in spans if span.name == "e2e-result:my-story"]
    assert len(emitted) == 1
    attributes = {attribute.key: attribute.value.string_value for attribute in emitted[0].attributes}
    assert json.loads(attributes["langfuse.observation.output"]) == {"outcome": "fail", "summary": "Regression caught"}
    audit = json.loads(capsys.readouterr().err.splitlines()[-1])
    assert audit["data"] == {"trace_id": emitted[0].trace_id.hex(), "outcome": "fail", "critical_count": 1}


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

        def log_message(self, format: str, *_args: object) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.01},
        daemon=True,
    )
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_check_langfuse_reachable_http_success() -> None:
    with _health_server() as host:
        assert mod._check_langfuse_reachable(host, timeout=1) is True


def test_check_langfuse_reachable_http_failure_and_missing_status() -> None:
    with _health_server(status=503) as host:
        assert mod._check_langfuse_reachable(host, timeout=1) is False
    with _health_server(body=b'{"error":"unhealthy"}') as host:
        assert mod._check_langfuse_reachable(host, timeout=1) is False


def test_check_langfuse_reachable_rejects_file_and_ftp_schemes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    health_file = tmp_path / "api" / "public" / "health"
    health_file.parent.mkdir(parents=True)
    health_file.write_text('{"status":"ok"}', encoding="utf-8")
    attempts: list[object] = []

    def record_opener(*args: object) -> object:
        attempts.append(args)
        return object()

    monkeypatch.setattr("urllib.request.build_opener", record_opener)

    assert mod._check_langfuse_reachable(tmp_path.as_uri()) is False
    assert mod._check_langfuse_reachable("ftp://127.0.0.1:0") is False
    assert attempts == []


def test_check_langfuse_reachable_accepts_https(monkeypatch: pytest.MonkeyPatch) -> None:
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
    assert mod._check_langfuse_reachable("https://langfuse.example", timeout=0.25) is True


def test_check_langfuse_reachable_passes_timeout_and_fails_open(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class TimedOutOpener:
        def open(self, _request: object, timeout: float) -> None:
            assert timeout == 0.01
            raise TimeoutError("timeout")

    monkeypatch.setattr("urllib.request.build_opener", lambda _handler: TimedOutOpener())
    assert mod._check_langfuse_reachable("http://langfuse.example", timeout=0.01) is False


def test_check_langfuse_reachable_allows_same_origin_redirect() -> None:
    with _health_server(location="/health-redirect-target") as host:
        assert mod._check_langfuse_reachable(host, timeout=1) is True


def test_check_langfuse_reachable_rejects_cross_origin_redirect() -> None:
    target_paths: list[str] = []
    with _health_server(paths=target_paths) as target:
        with _health_server(location=f"{target}/api/public/health") as source:
            assert mod._check_langfuse_reachable(source, timeout=1) is False
    assert target_paths == []


def test_check_langfuse_reachable_rejects_file_redirect(tmp_path: Path) -> None:
    health_file = tmp_path / "redirect-health.json"
    health_file.write_text('{"status":"ok"}', encoding="utf-8")
    with _health_server(location=health_file.as_uri()) as host:
        assert mod._check_langfuse_reachable(host, timeout=1) is False
