# Environment and tags

## Environments

Environments separate dev, staging, and production data within one Langfuse project.

### OTel path (primary — no langfuse package required)

**Option A — process-wide resource attribute (recommended):**

```bash
export OTEL_RESOURCE_ATTRIBUTES="langfuse.environment=staging"
```

Tags every span from every LangGraph node automatically. Set alongside `LANGFUSE_HOST`.

**Option B — per-span attribute:**

```python
span.set_attribute("langfuse.environment", "staging")
```

Accepted aliases: `deployment.environment.name`, `deployment.environment`.

**Option C — `LANGFUSE_TRACING_ENVIRONMENT` env var:**
Only effective when the `langfuse` Python package is also initialised. On the
pure-OTel path use Option A or B.

### Environment gotchas

**Regex `^(?!langfuse)[a-z0-9-_]+$`, max 40 chars — violations silently dropped.**
A single typo (e.g. `producton`) creates a **permanent undeletable environment**.
Validate before deploying.

**Unset → `"default"` bucket silently.** Easy to mix prod and dev data.

**Constructor beats env var silently.** When both `LANGFUSE_TRACING_ENVIRONMENT`
and the SDK `environment=` constructor param are set, the constructor wins.

**`LANGFUSE_HOST` and `LANGFUSE_TRACING_ENVIRONMENT` are independent knobs.**
Forgetting `LANGFUSE_HOST` lets the SDK fall back to its built-in remote default
silently — data lands in the wrong Langfuse instance entirely, not just the wrong
environment. Always set `LANGFUSE_HOST` to your self-hosted/local instance URL.

**Key must be exact.** Bare `"environment"`, `"env"`, `"langfuse.env"` are
silently ignored and the event lands in `"default"`.

## Tags

Tags categorise and filter traces in the Langfuse UI. Tags on any observation are
aggregated up to the trace automatically.

### OTel path (primary)

```python
span.set_attribute("langfuse.trace.tags", ["env:staging", "node:router"])
```

Key must be exactly `"langfuse.trace.tags"`. Value is a **native OTel string
array** — pass a Python `list[str]` directly. Do NOT `json.dumps` it; the OTel
attribute type is `string[]`, and a JSON-string blob lands in the metadata
catch-all instead of the trace `tags` field.

Set tags **at span open time** — Langfuse's immutable data model means tags cannot
be added after the span is exported.

### Optional — Langfuse SDK

```python
from langfuse import propagate_attributes

with propagate_attributes(tags=["env:staging", "node:router"]):
    result = graph.invoke(state)
```

`propagate_attributes()` only affects observations created **within** its context
scope. It does not retroactively tag an already-started parent span.

### Tag gotchas

**Tags immutable after span creation** — set at open time, not after `graph.invoke()`.

**Each tag max 200 chars — silently dropped if exceeded.** Use short fixed-vocabulary
tags (`"tier:premium"`), not dynamic values like full user names.

**Key is `langfuse.trace.tags`, value is a native `string[]`.** The bare key
`"langfuse.tags"` is silently ignored, and a `json.dumps([...])` string value
lands in the metadata catch-all rather than the trace `tags` field. Pass the
Python list directly: `span.set_attribute("langfuse.trace.tags", ["a", "b"])`.

## Verification

```bash
curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  "$LANGFUSE_HOST/api/public/traces?limit=1" \
  | jq '.data[0] | {environment, tags}'
```
