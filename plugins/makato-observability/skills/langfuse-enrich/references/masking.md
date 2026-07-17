# Masking

Redact PII and sensitive payloads before spans leave the process. The `mask_otel_spans`
hook is the only hook that covers raw OTel spans — including every LangGraph node span
and any third-party auto-instrumentation span. The legacy `mask=` hook does NOT cover
these; do not use it for LangGraph-via-OTel setups.

## Hook shape

```python
from langfuse.types import MaskOtelSpansParams, MaskOtelSpansResult, OtelSpanPatch
from langfuse import Langfuse
import json

def mask_otel_spans(params: MaskOtelSpansParams) -> MaskOtelSpansResult | None:
    try:
        patches: dict = {}
        for identifier, span in params.spans.items():
            attrs = span.attributes or {}
            delete_keys = []
            set_attrs = {}

            for key, value in attrs.items():
                scrubbed = _scrub(key, value)
                if scrubbed is None:
                    delete_keys.append(key)
                elif scrubbed != value:
                    set_attrs[key] = scrubbed

            if delete_keys or set_attrs:
                patches[identifier] = OtelSpanPatch(
                    delete_attributes=tuple(delete_keys),
                    set_attributes=set_attrs,
                )
        return MaskOtelSpansResult(span_patches=patches)
    except Exception:
        return None  # safe fallback — passes batch through unmodified
```

Wire the hook at Langfuse client construction:

```python
Langfuse(mask_otel_spans=mask_otel_spans)
```

## Scrub helper — delegate to your project's PII layer

```python
def _scrub(key: str, value) -> str | None:
    """
    Delegate to your project's PII tokenizer.
    Return the redacted value, or None to delete the attribute entirely.
    Sentinel strings for payload replacement:
      [CONTENT SCRUBBED]  — replaces input/prompt payloads
      [OUTPUT SCRUBBED]   — replaces output/completion payloads
    """
    if "input" in key or "prompt" in key:
        return "[CONTENT SCRUBBED]"
    if "output" in key or "completion" in key:
        return "[OUTPUT SCRUBBED]"
    return value  # pass through unchanged
```

Use the exact sentinel strings `[CONTENT SCRUBBED]` and `[OUTPUT SCRUBBED]` (see
span-attribute-conventions.md). Do not invent alternatives — downstream test assertions
match on these exact strings.

## OtelSpanPatch semantics

| Field | Effect |
|---|---|
| `delete_attributes` | Removes listed keys from the span. Runs first. |
| `set_attributes` | Adds or overwrites keys. Runs after delete — wins on collision. |
| Return `None` | Passes the entire batch through unmodified (safe fallback). |
| Sparse dict | Only include spans that need changes; absent spans pass through. |

Values in `set_attributes` must be OTel scalar types: `str`, `bool`, `int`, `float`,
or a homogeneous sequence of those. A `dict`, nested object, or `None` drops the span
from the export silently.

## Gotchas

| Gotcha | Detail |
|---|---|
| Batch ≠ trace | The hook receives one export batch at a time. A single trace's spans may arrive in separate batches — do not assume all spans for one request are co-present. |
| Exception = silent batch loss | Any uncaught exception drops the entire batch with no error surface and no retry. Always `try/except → return None`. |
| Worker-thread blocking | The hook runs on the BatchSpanProcessor worker thread. Slow masking (e.g. external tokenizer calls) backs up the export queue and delays all span delivery. |
| Cannot change structure | `mask_otel_spans` can only modify span attributes. Span name, IDs, parent-child relationships, resource attributes, events, and links cannot be changed. |
| Legacy hook gap | `Langfuse(mask=...)` fires only at Langfuse-SDK attribute-creation time. It does NOT intercept raw OTel spans from LangGraph nodes or third-party auto-instrumentation. |
| Per-exporter scope | The hook only masks spans exported by this Langfuse client. A second OTel exporter registered on the same TracerProvider receives its own unmasked copy. |
