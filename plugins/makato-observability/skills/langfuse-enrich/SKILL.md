---
name: langfuse-enrich
description: >-
  Wire Langfuse enrichment fields onto already-OTel-instrumented LangGraph
  agents. Use when you need to add session tracking, attach user id, set
  langfuse tags, add trace metadata, configure distributed tracing, record a
  user feedback score, mask pii traces, enable token cost tracking, enrich
  traces, or control log levels on individual observations. Assumes the OTel
  TracerProvider and OTLP HTTP exporter are already wired (langfuse-instrument).
version: "1.0.1"
allowed-tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
metadata:
  last_updated: "2026-08-05"
---

# langfuse-enrich

## When to Use

Use when the OTel TracerProvider, `BatchSpanProcessor`, and OTLP HTTP exporter
are **already** wired to a Langfuse endpoint (via `langfuse-instrument`) and the
contributor now needs to add one or more Langfuse enrichment features to running
node spans.

**Do NOT use when:**

- The TracerProvider has not been set up yet. Run `langfuse-instrument` first.
- The request is to add new `gen_ai.*`, `tool.*`, or `graph.node.*` span
  attributes. Those are covered by `langfuse-instrument` Step 4 +
  `span-attribute-conventions.md`.
- The request is about alerting, SLO budgets, or incident triage.

## Anti-patterns

These are the highest-consequence pitfalls for this enrichment skill. Each
produces silent data loss or corruption — no exception is raised.

**NEVER add a second `langfuse` SDK `TracerProvider` when one is already
registered by `langfuse-instrument`.**
Two `TracerProvider` registrations on the same Python process produce
conflicting global providers. The last `set_tracer_provider()` call wins, but
earlier spans are already registered to the first provider — both providers then
export partial, non-overlapping sets of spans to Langfuse, making traces appear
truncated or split. Use the OTel SDK primary path (`span.set_attribute(...)`) for
all enrichment unless `langfuse>=2.0` is already a declared dependency AND the
contributor explicitly requests the SDK path.

**NEVER set `langfuse.session.id` or `langfuse.user.id` inside individual node
functions.**
OTel context propagation automatically carries root-span attributes to all child
spans. Setting these attributes inside each node creates redundant writes and
misses the root observation. Set them exactly once on the root span before
`graph.invoke()` is called.

**NEVER call `get_trace_id_hex()` after the root span ends.**
Once the span context is closed, `trace.get_current_span()` returns the
invalid-span sentinel. `format(ctx.trace_id, "032x")` then produces
`"00000000000000000000000000000000"` — a valid-looking string that matches no
trace in Langfuse. Always extract the trace ID inside the active span, before
`graph.invoke()` returns.

**NEVER mix `gen_ai.usage.*` and `langfuse.observation.usage_details` on the
same span for the same token dimension.**
`gen_ai.usage.*` attributes are treated as **inclusive** counts (Langfuse
subtracts cache buckets during ingest). `langfuse.observation.usage_details` is
stored **verbatim**. Setting both for, say, `input_tokens` causes the ingest
pipeline to count that dimension twice — cost and token totals in the dashboard
become permanently wrong with no error surfaced.

**NEVER use the legacy `mask=` hook for LangGraph-via-OTel setups.**
`Langfuse(mask=...)` fires only at Langfuse-SDK attribute-creation time. It does
NOT intercept raw OTel spans emitted by LangGraph nodes or third-party
auto-instrumentation libraries. Only `mask_otel_spans` covers those spans. Using
`mask=` gives a false sense of PII protection while the actual node payloads land
in Langfuse unmasked.

**NEVER let `mask_otel_spans` raise an unhandled exception.**
Any uncaught exception in the hook drops the entire export batch with no error
surface and no retry. Always wrap the hook body in `try/except` and return `None`
on failure (safe fallback — passes the batch through unmodified).

## Workflow

### Step 0 — Confirm credentials are in place

Credentials (`LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`) must
already be set. If any are missing, stop and direct the contributor to
`langfuse-instrument` Step 0 before continuing.

`LANGFUSE_HOST` is the primary endpoint env var (example: `http://localhost:3000`
for a local deployment). It is set on the **client side** and must point to the
self-hosted or local Langfuse instance the project runs. Never substitute a
hardcoded URL and never default to a remote host; always read from the environment.

### Step 1 — Detect the enrichment feature from context and load the reference

Read the contributor's request and the surrounding codebase context, then load
**exactly one** reference that matches. Do NOT pre-load multiple references — load
only the file whose row matches, then proceed to Step 2.

| Request signals | Reference to load | Do NOT load if |
|---|---|---|
| session, conversation id, group traces, multi-turn | `@references/session-and-user-propagation.md` | request is only about user id with no multi-turn grouping |
| user id, user tracking, attribute trace to user | `@references/session-and-user-propagation.md` | request is only about session grouping with no user attribution |
| environment, staging, production, classify traces | `@references/environment-and-tags.md` | request mentions neither environment nor tag classification |
| tag, label, categorize, filter by tag | `@references/environment-and-tags.md` | request is about metadata key-value, not tag classification |
| metadata, arbitrary key-value, trace context, log level, severity, DEBUG/WARNING/ERROR | `@references/metadata-and-log-levels.md` | request is about session/user/tag/env — those are separate keys |
| traceparent, cross-service, distributed, W3C baggage, upstream span | `@references/distributed-tracing.md` | request is about in-process session propagation only |
| feedback, score, thumbs, rating, user signal | `@references/user-feedback.md` | request does not mention surfacing a score value to the Langfuse UI |
| pii, mask, redact, scrub, sensitive data | `@references/masking.md` | request is about filtering traces by tag, not payload redaction |
| token, cost, usage, billing, input_tokens, output_tokens | `@references/token-and-cost.md` | request is about log-level severity, not token counts |

If the request is to **set up** JS/TS OTel tracing from scratch (create
`instrumentation.ts`, register `NodeSDK` / `LangfuseSpanProcessor`), that is
bootstrap, not enrichment — route to the `langfuse-instrument` skill (its
`js-ts-first-trace.md` reference). Return here to add session/user/tags/etc.
enrichment to the JS/TS spans once the exporter is wired.

If the request matches **none** of the above, or spans more than three unrelated
features simultaneously, ask via `AskUserQuestion`:

> "Which enrichment feature do you want to add? Choose one:
> sessions/users, environment/tags, metadata/log-levels, distributed tracing,
> user feedback, PII masking, token+cost tracking, or JS/TS frontend tracing."

### Step 2 — Apply

Read the loaded reference in full, then implement the changes using the OTel SDK
primary code path (`span.set_attribute(...)`) described there.

**Primary code path — raw OTel SDK (Python):**

The consumer stack instruments LangGraph nodes via the OTel SDK. Every enrichment
feature has a `span.set_attribute("langfuse.<key>", value)` equivalent that
works without the `langfuse` Python package. Use that path unless the contributor
explicitly opts into the Langfuse SDK convenience APIs.

**Optional — Langfuse SDK convenience APIs (`propagate_attributes` / `@observe`):**

Available only when `langfuse>=2.0` is already a declared dependency and the
contributor explicitly requests the decorator or context-manager style. Before
adding the Langfuse SDK for enrichment alone, surface the TracerProvider conflict
risk (see Anti-patterns above) and get explicit confirmation.

**Shared attribute names note:**

New `langfuse.*` enrichment span attribute keys (`langfuse.session.id`,
`langfuse.user.id`, `langfuse.trace.tags`, `langfuse.environment`,
`langfuse.trace.metadata.<key>`) belong to the **shared attribute catalogue**. Do
not invent parallel key names. The canonical table lives in
`shared/span-attribute-conventions.md`. If this skill
adds a new `langfuse.*` key that is not yet in that table, open a follow-up to
add it there — do not define it only here.

After applying changes, verify at least one enriched span reaches the dashboard:

```bash
curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  "$LANGFUSE_HOST/api/public/traces?limit=1" \
  | jq '.data[0] | {id, sessionId, userId, tags, environment}'
```

Expected: the enrichment field you just added appears with a non-null value.
