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

## Langfuse enrichment attributes

The `langfuse-enrich` skill layers these Langfuse-native enrichment keys onto already-instrumented OTel spans. They are the canonical names — `langfuse-enrich` references this table rather than defining its own. Set on the OTel span via `span.set_attribute(...)`; the Langfuse OTLP receiver maps each key to its trace/observation field.

| Attribute | Type | Value example | Notes |
|---|---|---|---|
| `langfuse.session.id` | string | `"chat-thread-42"` | Groups traces into one conversation. Max 200 chars, US-ASCII, else silently dropped. Set once at the graph entry point. |
| `langfuse.user.id` | string | `"user-9f3a"` | Attributes the trace to an end-user. Missing → empty Users view, no error. |
| `langfuse.trace.tags` | string[] | `["node:router", "tier:prod"]` | Native OTel string array (NOT a JSON string, NOT the bare key `langfuse.tags`). Immutable after span open. Each tag max 200 chars. |
| `langfuse.trace.metadata.<key>` | string | `langfuse.trace.metadata.run_id = "…"` | One OTel attribute per metadata key → filterable trace-level metadata. Use `langfuse.observation.metadata.<key>` for observation-scoped keys. A single bare `langfuse.metadata` blob is not recognised. |
| `langfuse.environment` | string | `"production"` | Deployment-stage label. Must match `^(?!langfuse)[a-z0-9-_]+$`, max 40 chars. Aliases: `deployment.environment.name`, `deployment.environment`. Unset → `"default"` bucket. |
| `langfuse.observation.level` | string | `"ERROR"` | Log level `DEBUG`/`DEFAULT`/`WARNING`/`ERROR` on the observation (also inferred from `span.status.code`). |
| `langfuse.observation.usage_details` | string (JSON) | `json.dumps({"input": 120, "output": 30})` | Fine-grained **mutually-exclusive** token buckets. Distinct from `gen_ai.usage.*` (inclusive) above — do not mix both on one span. Only `generation`/`embedding` observations support cost. |

Log levels are set via the OTel status API (`span.set_status(StatusCode.ERROR, description=…)` + `span.record_exception(...)`) or the Langfuse SDK `level=` field (`DEBUG`/`DEFAULT`/`WARNING`/`ERROR`) — level lives on the observation, never the trace. See `langfuse-enrich/references/metadata-and-log-levels.md`.



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
