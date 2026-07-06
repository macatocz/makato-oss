# In-process exporter for unit tests

Unit tests need to assert on emitted spans **without** a running Langfuse. The OTel SDK ships `InMemorySpanExporter` for exactly this — spans are captured in a Python list the test can inspect directly.

## Registration (session scope)

Register the exporter once per pytest session so the TracerProvider isn't reset per test (that would drop the graph module's Tracer instance):

```python
# tests/_helpers/otel_inprocess.py — see templates/otel-inprocess-exporter.py
import pytest
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.sdk.resources import Resource

_EXPORTER: InMemorySpanExporter | None = None


@pytest.fixture(scope="session", autouse=True)
def _inprocess_tracer():
    global _EXPORTER
    _EXPORTER = InMemorySpanExporter()
    provider = TracerProvider(resource=Resource.create({"service.name": "test"}))
    provider.add_span_processor(SimpleSpanProcessor(_EXPORTER))
    trace.set_tracer_provider(provider)
    yield
    # session cleanup — TracerProvider does not need explicit shutdown here
```

**Key choices:**

- `SimpleSpanProcessor`, not `BatchSpanProcessor`. Tests exercise a node and then immediately inspect spans; batching hides them for 5 seconds.
- `autouse=True` on the session fixture. Every test module gets the tracer registered without explicit imports.

## Per-test reset

Each test starts with an empty span list. Add a per-test fixture that resets the exporter:

```python
@pytest.fixture(autouse=True)
def _reset_spans():
    if _EXPORTER is not None:
        _EXPORTER.clear()
    yield
```

## Reading spans from a test

The `captured_spans` fixture returns a list of `ReadableSpan` objects:

```python
@pytest.fixture
def captured_spans():
    return _EXPORTER.get_finished_spans() if _EXPORTER else []
```

Assert on attributes, names, status, events:

```python
def test_llm_node_emits_gen_ai_attrs(captured_spans, run_agent):
    run_agent("hello")
    llm_spans = [s for s in captured_spans if s.attributes.get("gen_ai.system")]
    assert llm_spans, "no gen_ai spans captured"
    assert llm_spans[0].attributes["gen_ai.request.model"] == "expected-model"
```

## Interaction with the production TracerProvider

The session fixture calls `trace.set_tracer_provider(...)`, which registers the test-side provider globally. That means production wiring code (from `templates/otel-setup.py`) MUST NOT overwrite the provider a second time in tests — the template already guards with a silent no-op when `LANGFUSE_PUBLIC_KEY` is unset, which is the standard test-environment posture. If a test explicitly wants to test the production wiring, it sets `LANGFUSE_PUBLIC_KEY=test-no-op` and the wiring skips the OTLP exporter but still uses the InMemory exporter registered here.

## What NOT to do

- Do NOT wrap the entire pytest session in an `atexit.register(shutdown)` — the session fixture yields, then pytest tears down, then the interpreter exits. Explicit shutdown races the fixture teardown and truncates trailing spans.
- Do NOT `InMemorySpanExporter()` per-test. The TracerProvider is set globally; a fresh exporter per test disconnects from the already-registered provider.
