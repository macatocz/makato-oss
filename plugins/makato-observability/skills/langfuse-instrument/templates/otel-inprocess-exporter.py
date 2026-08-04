"""
In-process OpenTelemetry exporter for unit tests.

Registers a session-scoped TracerProvider that writes finished spans into a
plain Python list, so tests can assert on span attributes without a running
Langfuse.

Place this file at the consumer's test-helpers directory (e.g.
tests/_helpers/otel_inprocess.py) and add it to conftest.py's import path,
or import the fixtures directly:

    from tests._helpers.otel_inprocess import _inprocess_tracer, captured_spans

Every test module using `captured_spans` gets the TracerProvider registered
automatically (session-scoped autouse fixture).

Requires:
    opentelemetry-api>=1.25
    opentelemetry-sdk>=1.25
    pytest
"""

from __future__ import annotations

import pytest
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

# Module-level exporter holder so per-test fixtures can clear it.
_EXPORTER: InMemorySpanExporter | None = None


@pytest.fixture(scope="session", autouse=True)
def _inprocess_tracer():
    """Register a session-scoped TracerProvider writing to an in-memory exporter.

    autouse=True so every test module in the pytest session gets the tracer
    installed without importing this file explicitly.
    """
    global _EXPORTER
    _EXPORTER = InMemorySpanExporter()

    resource = Resource.create(
        {
            "service.name": "test",
            "service.version": "0.0.0",
            "deployment.environment": "test",
        }
    )
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(_EXPORTER))
    trace.set_tracer_provider(provider)

    yield


@pytest.fixture(autouse=True)
def _reset_spans_between_tests():
    """Clear captured spans before each test so assertions are isolated."""
    if _EXPORTER is not None:
        _EXPORTER.clear()
    yield


@pytest.fixture
def captured_spans():
    """Return the list of ReadableSpan objects finished in the current test.

    Example:
        def test_llm_span_carries_model(captured_spans, run_agent):
            run_agent("hello")
            llm_spans = [
                s for s in captured_spans
                if s.attributes.get("gen_ai.system")
            ]
            assert llm_spans, "no gen_ai spans captured"
            assert llm_spans[0].attributes["gen_ai.request.model"]
    """
    return list(_EXPORTER.get_finished_spans()) if _EXPORTER else []
