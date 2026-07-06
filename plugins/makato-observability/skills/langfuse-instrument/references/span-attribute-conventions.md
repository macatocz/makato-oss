# Span attribute conventions

Every span this skill produces uses attribute names from the OpenTelemetry semantic-conventions catalogue. Do NOT invent names — the Langfuse dashboard groups observations by these attribute keys, and diverging from the standard breaks the trace tree rendering.

## Core LLM attributes (`gen_ai.*`)

The OTel `gen_ai` semantic convention (formerly `llm.*`, migrated in Q1 2026) is the canonical namespace for LLM observations.

| Attribute | Type | Value example | Required? |
|---|---|---|---|
| `gen_ai.system` | string | `"openai"`, `"anthropic"`, `"vertex_ai"` | Yes for LLM spans |
| `gen_ai.request.model` | string | `"claude-4.5-sonnet"`, `"gpt-4-turbo"` | Yes for LLM spans |
| `gen_ai.request.temperature` | double | `0.0` | Recommended |
| `gen_ai.request.max_tokens` | int | `4096` | Recommended |
| `gen_ai.response.model` | string | Actual model returned (may differ from requested) | Yes when known |
| `gen_ai.usage.input_tokens` | int | `142` | Yes |
| `gen_ai.usage.output_tokens` | int | `287` | Yes |
| `gen_ai.response.finish_reasons` | string[] | `["stop"]`, `["tool_use"]` | Recommended |

## Tool-call attributes

| Attribute | Type | Value example |
|---|---|---|
| `tool.name` | string | `"retrieve_context"` |
| `tool.call_id` | string | Provider-issued call ID for correlation |
| `tool.args_hash` | string | Optional — sha256 of args when args are sensitive |

## Graph-node attributes (this skill's convention)

| Attribute | Type | Value example |
|---|---|---|
| `graph.node.name` | string | `"understand_request"` |
| `graph.node.type` | string | `"llm"`, `"tool"`, `"router"`, `"terminal"` |

Set these on every node's outer span. They let the dashboard filter observations by graph position.

## Perimeter tags (data-sensitivity)

Consumer apps that carry a data-sensitivity perimeter (Brain/Body split, tenant-scope, PII zones) tag spans with a perimeter attribute:

| Attribute | Type | Value example |
|---|---|---|
| `perimeter` | string | `"brain"`, `"body"`, `"shared"`, or consumer-specific |

**Scrub sentinels.** When a node runs on a perimeter that forbids raw payload capture in traces, replace input/output with sentinel strings:

```python
if perimeter_forbids_raw_payload:
    span.set_attribute("input", "[CONTENT SCRUBBED]")
    span.set_attribute("output", "[OUTPUT SCRUBBED]")
else:
    span.set_attribute("input", raw_input)
    span.set_attribute("output", raw_output)
```

The sentinel strings are the canonical convention (matches the pattern used in test-side scrub-leak assertions across consumer stacks). Do not invent alternative sentinels — downstream test assertions match on the exact strings `[CONTENT SCRUBBED]` and `[OUTPUT SCRUBBED]`.

The consumer's context supplies which perimeter tag applies to which node — this skill does NOT choose the perimeter mapping. If the consumer has no perimeter concept, skip the scrub logic entirely and capture inputs/outputs directly.

## Error attributes

For failed spans, use the OTel error convention:

```python
try:
    result = llm.call(...)
except Exception as exc:
    span.record_exception(exc)
    span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
    raise
```

`span.record_exception` captures type + message + stack trace as span events. Do NOT log raw payloads in the exception — sensitive input can leak that way. Sanitise before raising.
