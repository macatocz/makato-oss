# Metadata and log levels

## Attaching metadata to spans

### OTel path (primary — no Langfuse SDK required)

Set at span open. `BatchSpanProcessor` exports on span end; attribute mutations after export
scheduling can race — set metadata immediately inside the `with` block.

Metadata uses a **per-key prefix**, one OTel attribute per metadata field. Choose the
scope prefix:

- `langfuse.trace.metadata.<key>` — promotes the key to the **trace** top-level metadata (filterable in the UI).
- `langfuse.observation.metadata.<key>` — attaches the key to this **observation** only.

```python
with _tracer.start_as_current_span("router_node") as span:
    span.set_attribute("langfuse.trace.metadata.run_id", run_id)
    span.set_attribute("langfuse.observation.metadata.node_version", "2")
    # ... node body ...
```

Each value is a plain string (or OTel scalar). Do NOT pack the whole dict into a single
`langfuse.metadata` attribute — that bare key is not recognised and the data lands in the
`metadata.attributes` catch-all instead of being filterable. One attribute per key.

### Langfuse-SDK path (if SDK co-installed alongside OTel)

```python
from langfuse import propagate_attributes

with propagate_attributes(metadata={"runId": run_id, "nodeVersion": "2"}):
    # all child observations inherit these keys
```

**NEVER** use `_`, `-`, or `.` inside a single propagated metadata **key name** on the
SDK path — silently dropped (alphanumeric only). Values >200 chars are also silently
dropped. The OTel `langfuse.trace.metadata.<key>` / `langfuse.observation.metadata.<key>`
path has neither restriction (the prefix dots are structural, not part of the key name).

---

## Log levels

Level is set on **observations** (spans/generations), not the parent trace.
Valid literals: `DEBUG` `DEFAULT` `WARNING` `ERROR`.

### OTel path — no Langfuse SDK required

```python
from opentelemetry.trace import StatusCode

def my_node(state):
    with _tracer.start_as_current_span("my_node") as span:
        try:
            result = do_work(state)
            return result
        except Exception as exc:
            span.record_exception(exc)                         # type + message + stack as span events
            span.set_status(StatusCode.ERROR, description=str(exc))
            raise
```

Do NOT pass raw payload inside `exc` — sanitize before raising if the message could carry PII.

### Langfuse-SDK path

```python
from langfuse import update_current_span  # inside @observe()-decorated node

try:
    ...
except Exception as exc:
    update_current_span(level="ERROR", status_message=str(exc))
    raise
```

---

## Gotchas

| Trap | Detail |
|---|---|
| `DEFAULT` is implicit | Unset level = `DEFAULT`, not `DEBUG`. OTel nodes have no auto-level (unlike the LangChain callback path) — set `DEBUG` explicitly where needed. |
| Language naming | Python: `status_message` (snake_case). JS/TS: `statusMessage` (camelCase). Wrong casing silently drops the message. |
| Update-after-flush race | Calling `update_current_span()` after the `with` block exits races `BatchSpanProcessor` export. Set level inside the block or at creation time. |
| Level scope | No trace-level log level field exists. UI filtering is per-observation only. |
| `langfuse.*.metadata.<key>` per-key | Metadata is one OTel attribute per key under `langfuse.trace.metadata.<key>` or `langfuse.observation.metadata.<key>`. A single bare `langfuse.metadata` blob is NOT recognised — it lands in the `metadata.attributes` catch-all. Values must be OTel scalars. |
