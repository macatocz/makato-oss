# Session and user propagation

Attach a `sessionId` to group multiple traces into a single conversation replay,
and a `userId` to attribute traces to individual end-users. Both are optional
additive fields — omitting either causes silent invisibility in the Sessions /
Users views without any error.

## Primary path — OTel SDK (no langfuse package required)

Set both attributes **once** at the graph entry point (route handler or the
`graph.invoke()` call site). OTel context propagation carries them to all child
spans automatically. Do NOT set them inside individual node functions.

```python
from opentelemetry import trace

# At graph.invoke() call site — e.g. FastAPI route handler
with tracer.start_as_current_span("graph_root") as root:
    root.set_attribute("langfuse.session.id", session_id)
    root.set_attribute("langfuse.user.id", user_id)
    result = graph.invoke(state)
```

`langfuse.session.id` and `langfuse.user.id` are the OTel span attribute keys
Langfuse maps to `sessionId` and `userId` on ingestion. They belong in the
shared `span-attribute-conventions.md` catalogue — reference that file, do not
define a parallel table here.

## Gotchas

**Session ID silently dropped if > 200 chars US-ASCII.**
No error is raised; traces are written but not grouped. Validate length before
passing, especially when composing IDs from user-supplied data:

```python
assert len(session_id) <= 200 and session_id.isascii(), "session_id invalid"
```

**Session IDs must be US-ASCII only.**
Unicode characters (e.g. international user names embedded in the ID) silently
cause session grouping to fail. Use opaque UUID-style IDs.

**Set ONCE at graph entry — not inside node functions.**
Setting the attribute on the root span before `graph.invoke()` is sufficient;
OTel propagates it to all child node spans. Adding it inside each node creates
redundant writes and misses the root observation.

**`asyncio.create_task` escaping context loses attributes.**
If a LangGraph node spawns a background task via `asyncio.create_task()` or
`ThreadPoolExecutor`, OTel context (including these attributes) does NOT
propagate automatically. Use OTel `Baggage` with a `BaggageSpanProcessor` for
those paths:

```python
from opentelemetry.baggage import set_baggage
from opentelemetry import context as otel_context

ctx = set_baggage("langfuse.session.id", session_id)
ctx = set_baggage("langfuse.user.id", user_id, context=ctx)
token = otel_context.attach(ctx)
try:
    result = await asyncio.gather(node_a(), node_b())
finally:
    otel_context.detach(token)
```

**Missing `user_id` → empty Users view, no error.**
Traces land correctly but are invisible in the Users drill-down. Check day one.

## Optional — Langfuse SDK (`propagate_attributes`)

Available only when `langfuse>=2.0` is a declared dependency AND an active
Langfuse SDK observation context is running on the same thread/async context as
the node invocations. The OTel-SDK primary path above does not require this.

```python
from langfuse import get_client, propagate_attributes

langfuse = get_client()
with langfuse.start_as_current_observation(as_type="span", name="graph_root"):
    with propagate_attributes(session_id=session_id, user_id=user_id):
        result = graph.invoke(state)
```

`propagate_attributes()` uses Python `contextvars`. It does NOT propagate into
`asyncio.create_task()` or `ThreadPoolExecutor` — use OTel Baggage for those
paths regardless of which SDK path you choose.

## Verification

```bash
curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  "$LANGFUSE_HOST/api/public/traces?limit=1" \
  | jq '.data[0] | {id, sessionId, userId}'
```

Expected: `sessionId` and `userId` non-null on the trace.
