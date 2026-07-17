# Distributed tracing

Covers cross-service spans only. Intra-process async propagation (parallel LangGraph node
edges, `asyncio.create_task`) is handled automatically — see `langgraph-otel-integration.md`.

---

## Deterministic trace IDs

Produce the same 32-hex W3C trace ID from any stable seed (chat ID, ticket ID, request ID)
so both sides of a service boundary can reference it without passing it over the wire.

```python
from langfuse import get_client

langfuse = get_client()
trace_id = langfuse.create_trace_id(seed=chat_id)   # same seed → same ID every time
```

A 32-character lowercase hex correlation ID is already a valid W3C trace ID — rename, do
not reformat it.

---

## Attaching a new span to an existing trace (OTel manual injection)

Use when a service receives an upstream trace ID (from a request header, a queue message,
or a deterministic seed) and must nest new spans under it without a live parent span object.

```python
from opentelemetry import trace
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

incoming_trace_id = int(trace_id_hex, 16)          # 32-hex string → int
dummy_span_id     = 0x0000000000000001             # syntactically valid; value is irrelevant

ctx = trace.set_span_in_context(
    NonRecordingSpan(
        SpanContext(
            trace_id=incoming_trace_id,
            span_id=dummy_span_id,
            is_remote=True,
            trace_flags=TraceFlags.SAMPLED,         # NEVER omit — unsampled spans are silently dropped
        )
    )
)

with _tracer.start_as_current_span("entry_node", context=ctx) as span:
    # span is now a child of trace_id_hex in Langfuse
    ...
```

---

## Cross-service W3C propagation

Wire the W3C `traceparent` header so both sides of an HTTP boundary land in the same trace.

```python
# Caller — inject
from opentelemetry.propagate import inject
headers = {}
inject(carrier=headers)              # populates traceparent (+ baggage if set)
response = httpx.post(downstream_url, headers=headers, json=payload)

# Server — extract
from opentelemetry.propagate import extract
ctx = extract(carrier=dict(request.headers))
with _tracer.start_as_current_span("handle_request", context=ctx) as span:
    ...
```

To carry Langfuse metadata (userId, sessionId) across the boundary, add `as_baggage=True`:

```python
from langfuse import propagate_attributes
with propagate_attributes(user_id=uid, session_id=sid, as_baggage=True):
    headers = {}
    inject(carrier=headers)
    httpx.post(downstream_url, headers=headers, json=payload)
```

**Scope `as_baggage` tightly** — baggage attaches to ALL outbound requests in context,
including third-party API calls. Do not activate it at process scope.

---

## Gotchas

| Trap | Detail |
|---|---|
| `TraceFlags.SAMPLED` mandatory | Omitting it marks the context unsampled; Langfuse silently drops every span with no error. |
| dummy `span_id` must be valid | Pass any 16-char hex int (`0x0000000000000001`). An empty value or `None` detaches the span and creates an orphan trace. |
| `as_baggage` scope leak | Baggage rides **all** outbound headers in context, including third-party API calls. Always narrow the `propagate_attributes` context manager to the specific downstream call. |
| Env var split | `LANGFUSE_HOST` is read by the Python `OTLPSpanExporter`; `LANGFUSE_BASE_URL` is read by JS `@langfuse/otel`. On a self-hosted instance set both to the same URL — a mismatch silently routes JS spans to the cloud endpoint. |
| `BatchSpanProcessor` buffer lost | Buffers up to ~5 s; without `atexit.register(lambda: trace.get_tracer_provider().shutdown())` spans are silently lost on process exit. Register once at startup. |
| Deterministic seed ID | `create_trace_id(seed=...)` is idempotent — call again at scoring time to recover the ID without storing it. |
