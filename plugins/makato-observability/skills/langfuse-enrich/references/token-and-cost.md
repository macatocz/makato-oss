# Token and cost tracking

Langfuse computes USD cost per generation observation from token counts plus a model
price definition. The OTel path sets token counts as span attributes; cost inference
is automatic when the model name matches a price definition.

Span attribute definitions live in shared/span-attribute-conventions.md — load it for the
full `gen_ai.*` table. This file covers the delta: cost inference and fine-grained
exclusive usage buckets.

## Observation type requirement

Only observations of type `"generation"` or `"embedding"` support token and cost
tracking. Observations of type `"span"` silently drop all usage data. Mark the
observation type by setting:

```python
span.set_attribute("gen_ai.operation.name", "chat")   # marks as generation
span.set_attribute("gen_ai.request.model", "gpt-4o")  # required for cost inference
```

## Inclusive token counts (gen_ai.usage.*)

Set these on the generation span after the LLM call returns:

```python
span.set_attribute("gen_ai.usage.input_tokens", response.usage.prompt_tokens)
span.set_attribute("gen_ai.usage.output_tokens", response.usage.completion_tokens)
```

Langfuse treats `gen_ai.usage.input_tokens` as **inclusive** — it may contain cached
tokens. Langfuse subtracts known cache buckets during ingest. See
span-attribute-conventions.md for the full attribute table.

## Fine-grained exclusive buckets (usage_details)

For precise cache accounting, pass pre-computed exclusive buckets as a JSON string.
These are stored **verbatim** — Langfuse does no normalization:

```python
import json

# OpenAI: prompt_tokens is inclusive of cached_tokens — subtract before passing.
cached = response.usage.prompt_tokens_details.cached_tokens or 0
non_cached_input = response.usage.prompt_tokens - cached

span.set_attribute(
    "langfuse.observation.usage_details",
    json.dumps({
        "input": non_cached_input,
        "cache_read_input_tokens": cached,
        "output": response.usage.completion_tokens,
    }),
)
```

**Never mix** `gen_ai.usage.*` and `langfuse.observation.usage_details` on the same
span for the same token dimension. `gen_ai.usage.*` is treated as inclusive;
`usage_details` is treated as verbatim exclusive — combining them double-counts.

## Custom model pricing

When Langfuse's built-in model list does not recognise the model name, cost will be
zero. Register a custom definition via the REST API:

```bash
curl -X POST "${LANGFUSE_HOST}/api/public/models" \
  -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "modelName": "my-fine-tune-v1",
    "matchPattern": "(?i)^my-fine-tune-v1$",
    "tokenizerId": "cl100k_base",
    "inputPrice": 0.0000025,
    "outputPrice": 0.0000100
  }'
```

`matchPattern` is a regex matched against the `gen_ai.request.model` value on the
span. A mismatch produces silent zero cost — no warning is emitted.

Custom model definitions are **project-scoped**. On a self-hosted instance, browse
existing definitions at `${LANGFUSE_HOST}/project/<id>/models`.

## Gotchas

| Gotcha | Detail |
|---|---|
| OpenAI inclusive prompt_tokens | `prompt_tokens` includes `cached_tokens`. Subtract before passing to `usage_details` or input is double-counted. Anthropic `input_tokens` already excludes cache reads — no subtraction needed. |
| Do not mix inclusive + verbatim | `gen_ai.usage.*` → inclusive ingest; `langfuse.observation.usage_details` → verbatim storage. Using both for the same token type on the same span silently corrupts counts. |
| Cost frozen at ingest | Cost is calculated at ingestion time. Updating a model price definition does not recalculate historical observations. |
| Reasoning model blind spot | Reasoning tokens (OpenAI o1 family) are billed as output tokens but are opaque to Langfuse tokenization. Explicitly set `output` in `usage_details` or cost will be wrong. |
| `total` key semantics | `total` in `usage_details` is derived as the sum of all buckets if omitted. If you supply it, it must match the actual sum — a mismatch produces an inconsistent UI display. |
| `matchPattern` regex mismatch | A typo in the pattern (or a model name that differs by version suffix) causes silent zero cost with no error logged. Test the regex against your actual model string before registering. |
| Span type check | Setting `gen_ai.operation.name="chat"` is what marks the observation as a generation in the OTel path. Without it, even correct token attributes are silently dropped. |
