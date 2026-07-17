# User feedback

Attach human quality signals to traces so Langfuse can surface per-turn thumbs scores,
drive annotation queues, and feed LLM-as-a-Judge pipelines.

## Extract the trace ID on the backend

The trace ID must be returned to the frontend in the streaming response so the browser
can submit a score against it. Extract it from the active OTel span at response time:

```python
from opentelemetry import trace

def get_trace_id_hex() -> str:
    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x")  # 32-char lowercase W3C hex
```

**NEVER** call `get_trace_id_hex()` after the root span has ended — it returns the
invalid-span sentinel and `format()` will produce `"00000000000000000000000000000000"`.
Call it inside the active span, before `graph.invoke()` returns.

Each `graph.invoke()` call MUST open a fresh root span so every turn produces a
distinct trace ID. Reusing a span across turns merges all feedback scores onto one trace.

## Server-side score creation

```python
from langfuse import get_client

langfuse = get_client()

langfuse.create_score(
    trace_id=trace_id,           # 32-char hex from get_trace_id_hex()
    name="user-feedback",
    value=1,                     # 1 = positive, 0 = negative
    data_type="BOOLEAN",
    id=f"user-feedback-{trace_id}",  # deterministic — prevents duplicate on retry
)
```

The `id` field is the idempotency key. Without it, every call (including accidental
double-submits) creates a duplicate score — aggregates become meaningless.

## Frontend score submission

Use `@langfuse/browser` with the **public key only**. The secret key must never appear
in browser JavaScript.

```typescript
import { LangfuseBrowserClient } from "@langfuse/browser";

const langfuse = new LangfuseBrowserClient({
  publicKey: process.env.NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY!,
  baseUrl: process.env.NEXT_PUBLIC_LANGFUSE_HOST,  // self-hosted LANGFUSE_HOST value
});

async function submitFeedback(traceId: string, positive: boolean) {
  await langfuse.score({
    traceId,
    id: `user-feedback-${traceId}`,  // same deterministic id as server side
    name: "user-feedback",
    value: positive ? 1 : 0,
    dataType: "BOOLEAN",
  });
}
```

## Gotchas

| Gotcha | Detail |
|---|---|
| CORS silent fail | Self-hosted Langfuse must have CORS configured for the browser frontend's origin. `LangfuseBrowserClient.score()` silently fails with no JS error if CORS is missing. |
| `getActiveTraceId` null guard | The `@langfuse/tracing` helper returns `null` outside an active span. An empty traceId produces an orphan score with no trace link — validate before submitting. |
| Secret key in browser | The `/api/public/scores` endpoint is public-write by design and accepts only the public key. Passing the secret key exposes it in client JavaScript. |
| Per-turn distinct trace | Each `graph.invoke()` must produce a new root span. A session-spanning root span means all turns share one traceId and feedback scores overwrite each other when `id` is derived from traceId. |
| OTel trace ID format | LangGraph-via-OTel produces a 32-char lowercase hex trace ID (W3C format). Langfuse accepts it for OTel-originated traces; confirm the format matches before wiring the frontend score call. |
