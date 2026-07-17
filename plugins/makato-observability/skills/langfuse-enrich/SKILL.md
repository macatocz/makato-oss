---
name: langfuse-enrich
description: >-
  Wire Langfuse enrichment fields onto already-OTel-instrumented LangGraph
  agents. Use when you need to add session tracking, attach user id, set
  langfuse tags, add trace metadata, configure distributed tracing, record a
  user feedback score, mask pii traces, enable token cost tracking, enrich
  traces, or control log levels on individual observations. Assumes the OTel
  TracerProvider and OTLP HTTP exporter are already wired (langfuse-instrument).
version: "1.0.0"
allowed-tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
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
exactly the reference(s) that match. Do not front-load all references.

| Request signals | Reference to load |
|---|---|
| session, conversation id, group traces, multi-turn | `@references/session-and-user-propagation.md` |
| user id, user tracking, attribute trace to user | `@references/session-and-user-propagation.md` |
| environment, staging, production, classify traces | `@references/environment-and-tags.md` |
| tag, label, categorize, filter by tag | `@references/environment-and-tags.md` |
| metadata, arbitrary key-value, trace context, log level, severity, DEBUG/WARNING/ERROR | `@references/metadata-and-log-levels.md` |
| traceparent, cross-service, distributed, W3C baggage, upstream span | `@references/distributed-tracing.md` |
| feedback, score, thumbs, rating, user signal | `@references/user-feedback.md` |
| pii, mask, redact, scrub, sensitive data | `@references/masking.md` |
| token, cost, usage, billing, input_tokens, output_tokens | `@references/token-and-cost.md` |

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
contributor explicitly requests the decorator or context-manager style. If adding
this dependency solely for enrichment, note the trade-off: a second SDK alongside
the existing OTel setup requires careful TracerProvider conflict management.

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
