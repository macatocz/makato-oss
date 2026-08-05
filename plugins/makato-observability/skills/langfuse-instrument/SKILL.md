---
name: langfuse-instrument
description: >-
  Add OpenTelemetry-based Langfuse tracing to a LangGraph-based AI
  agent. Wires the OTel SDK (Tracer, TracerProvider, OTLP HTTP exporter)
  to a Langfuse endpoint so LangGraph nodes running without a LangChain
  wrapper land structured traces. Use when the user wants to trace LLM
  calls, monitor token usage, debug graph node routing, or add
  production-grade observability to their LangGraph agent — with either
  Langfuse Cloud, a self-hosted Langfuse instance, or an e2e-local
  Langfuse. Triggers include "add langfuse", "trace llm", "observe
  agent", "otel setup", "langfuse setup", "wire tracing", "monitor
  tokens", "debug graph", "instrument agent".
version: "0.1.0"
metadata:
  authors: ["makato-observability"]
  last_updated: "2026-08-05"
---

# langfuse-instrument

## When to Use

Use when a contributor wants to wire OpenTelemetry-based tracing into a LangGraph agent so LLM calls, graph-node routing, and token usage land as structured traces on a Langfuse dashboard.

**Do NOT use when:**

- The agent uses classic-LangChain with `CallbackHandler`. That callback-based recipe is out of scope for this plugin — see `plugins/makato-observability/AGENTS.md` § *What Does NOT Belong Here*.
- The consumer wants Prometheus / Loki / ELK / CloudWatch instrumentation. That's not observability-via-Langfuse and belongs elsewhere.
- The consumer wants alerting, SLO calculators, or incident-response prose.

## Anti-patterns

Each item below represents a failure mode that practitioners learn through production breakage — not obvious from the OTel or LangGraph documentation.

**NEVER wrap `graph.invoke()` in a top-level span.**
LangGraph's own runtime emits the trace root; adding an outer span externally double-counts every observation on the Langfuse dashboard, inflates token totals, and produces a broken trace tree where the root span appears twice. Wrap *node bodies* only, not the invoke call.

**NEVER instantiate `InMemorySpanExporter()` per-test.**
The `TracerProvider` is set globally via `trace.set_tracer_provider(provider)` once at session scope. A fresh `InMemorySpanExporter` created inside a test body is never connected to that provider — all spans go to the original exporter and the new one stays empty forever. Always register the exporter once at session scope and use a `clear()` reset between tests.

**NEVER register `atexit.register(shutdown)` inside the pytest session fixture.**
The session fixture's teardown (`yield` cleanup) runs before interpreter exit. `atexit` handlers fire *after* pytest has torn down fixture scope. Combining both causes the `TracerProvider.shutdown()` call to race the fixture teardown, which truncates trailing spans from the last test(s). Use the session fixture's `yield` cleanup exclusively for test teardown; `atexit` is for production service entry points only.

**NEVER use the gRPC OTLP exporter (`opentelemetry-exporter-otlp-proto-grpc`) with Langfuse.**
The Langfuse OTLP receiver listens on HTTP/protobuf only — the gRPC transport is not implemented. The gRPC exporter silently connects and then fails with generic connection errors that do not name Langfuse or HTTP as the cause. Always use `opentelemetry-exporter-otlp-proto-http`.

**NEVER omit the `/api/public/otel/v1/traces` path suffix.**
A common mistake is pointing the exporter at `<LANGFUSE_HOST>` with no path (or `/v1/traces`). Both return 404. The full path is `<LANGFUSE_HOST>/api/public/otel/v1/traces` — the `/api/public/otel` prefix is Langfuse-specific and absent from generic OTLP collector documentation.

**NEVER paraphrase the scrub sentinel strings.**
`[CONTENT SCRUBBED]` and `[OUTPUT SCRUBBED]` are exact sentinel strings that downstream test contracts and QA pipelines match literally. Paraphrasing them (e.g., `<redacted>`, `SCRUBBED`, `[REDACTED]`) breaks those contracts silently — the span appears to contain real data to any matcher that does not see the exact sentinel.

## Workflow

Follow the seven steps in order. Do not skip Step 6 — a "success" without dashboard verification is a failed install.

### Step 0 — Gather Langfuse credentials

Load `@references/deployment-paths.md` now. Do NOT load this reference before Step 0 or front-load it with other steps.

Ask via `AskUserQuestion`:

> **"How is Langfuse deployed for this project?"**
>
> 1. Langfuse Cloud
> 2. Self-hosted (any Helm / Docker / Kubernetes deployment)
> 3. E2E-local (typically `docker compose` bring-up on `http://localhost:3000`)

For every choice, collect **three** values before proceeding:

- `LANGFUSE_HOST` — the full URL. No default. For Cloud, the operator picks US (`https://cloud.langfuse.com`) or EU (`https://eu.cloud.langfuse.com`); for self-hosted, the operator supplies the arbitrary URL they own.
- `LANGFUSE_PUBLIC_KEY` — starts with `pk-lf-…`
- `LANGFUSE_SECRET_KEY` — starts with `sk-lf-…`

If the operator cannot supply all three, HALT. Do NOT proceed. Point them at their Langfuse project settings → API Keys.

### Step 1 — Confirm agent runs LangGraph on the OTel-SDK path

Load `@references/langgraph-otel-integration.md` now. Do NOT load this reference before Step 1 or during Step 0 credential gathering.

Read the agent entry file(s) the operator names (or scan the conventional locations — typical layouts include a `src/` package with the graph module, plus a bootstrap that calls `graph.compile()` or `graph.invoke()`).

Verify both:

1. **LangGraph present.** Grep for `StateGraph`, `graph.compile()`, `from langgraph`. If not LangGraph — STOP and report: this plugin covers LangGraph-based agents only.
2. **No classic-LangChain wrapper.** Grep for `from langchain.callbacks`, `langfuse.langchain.CallbackHandler`, `config={"callbacks": [`. If any callback wiring is found — STOP and report: the LangChain-callback bridge is out of scope for this plugin per `AGENTS.md`.

Log the confirmation. Proceed only when both checks pass.

**JS/TS agents.** If the target is a JS/TS OTel client (a serverless/edge agent or
chat widget), the Python steps below (2–5) do not apply — load
`@references/js-ts-first-trace.md` for the `NodeSDK` + `LangfuseSpanProcessor`
bootstrap. Do NOT load `js-ts-first-trace.md` for Python targets. Rejoin at
Step 6 for dashboard verification after loading that reference. Enrichment of the
resulting spans (sessions, users, tags, feedback) is covered by the
`langfuse-enrich` skill.

### Step 2 — Verify OTel + Langfuse dependencies

Check the consumer's dependency manifest (`pyproject.toml` or `requirements.txt`):

- `opentelemetry-api>=1.25` — required
- `opentelemetry-sdk>=1.25` — required
- `opentelemetry-exporter-otlp-proto-http` — required for the OTLP HTTP exporter (the Langfuse OTel receiver does not accept gRPC OTLP)
- `langfuse>=2.0` — required for the verification-side SDK use in tests (Step 5 + Step 6)

If any dependency is missing, add it to the correct group (production-scope goes in `[project.dependencies]`; test-only wiring goes in `[project.optional-dependencies].test`). Do NOT run `pip install`. Tell the operator to run their local install command (`pip install -e .`, `uv sync`, or their equivalent).

### Step 3 — Wire the OTel TracerProvider + OTLP HTTP exporter

Load `@references/otel-setup.md` now. Do NOT load this reference before Step 3.

Copy `@templates/otel-setup.py` into the consumer's bootstrap module (the module that runs before any LangGraph node imports — typically an app entry point or a dedicated `observability.py`).

The template:

1. Constructs a `TracerProvider` with a `Resource` carrying `service.name` and `service.version`.
2. Attaches an `OTLPSpanExporter` targeting `<LANGFUSE_HOST>/api/public/otel/v1/traces` with `Authorization: Basic <base64(pk:sk)>`.
3. Wraps the exporter in a `BatchSpanProcessor` (Simple only in test paths, see Step 5).
4. Is a **silent no-op** when `LANGFUSE_PUBLIC_KEY` is unset — the consumer runs locally without a Langfuse instance and the TracerProvider stays uninitialised. Zero overhead.

Adapt the module path per the consumer's conventions; do NOT hard-code a filesystem layout.

### Step 4 — Instrument LangGraph nodes with spans + attributes

Load `@references/span-attribute-conventions.md` now. Do NOT load this reference before Step 4.

For each LangGraph node whose behaviour needs tracing, wrap the node body:

```python
tracer = trace.get_tracer(__name__)

def some_node(state):
    with tracer.start_as_current_span("some_node") as span:
        # ... node body ...
        span.set_attribute("gen_ai.request.model", model_name)
        span.set_attribute("gen_ai.usage.input_tokens", usage.input_tokens)
        span.set_attribute("gen_ai.usage.output_tokens", usage.output_tokens)
        return {...}
```

Use canonical `gen_ai.*` attribute names from the catalogue — do not invent new names. For LLM calls, always capture: model, input tokens, output tokens, latency (auto-captured by the span duration).

**Scrub perimeter.** When the consumer's context assigns a data-sensitive perimeter tag to the node, MUST set `span.set_attribute("input", "[CONTENT SCRUBBED]")` and `span.set_attribute("output", "[OUTPUT SCRUBBED]")` instead of raw payloads. The perimeter tag comes from the consumer's convention — this skill accepts it via the context prompt and does not choose it.

### Step 5 — Add the in-process exporter for unit tests

Load `@references/inprocess-exporter.md` now. Do NOT load this reference before Step 5, and do NOT load it for the production wiring path.

Copy `@templates/otel-inprocess-exporter.py` into the consumer's test-helpers directory (the operator supplies the path — typical layouts use `tests/_helpers/` but this skill does not hard-code that location).

The template:

1. Registers an `InMemorySpanExporter` at pytest session scope, wired through a `SimpleSpanProcessor` for synchronous test execution.
2. Exposes a `captured_spans` fixture that returns finished spans for the current test.
3. Resets the exporter between tests via a per-test cleanup hook.

Unit tests then assert on span structure directly without a running Langfuse:

```python
def test_node_emits_gen_ai_attrs(captured_spans):
    # ... exercise the node ...
    assert any(s.attributes.get("gen_ai.request.model") for s in captured_spans)
```

### Step 6 — Configure env vars + verify traces on dashboard (MANDATORY)

Update or create `.env.local` at the consumer repo root with the three `LANGFUSE_*` values from Step 0. Provide `@templates/env-local.example` as reference.

For non-local deployment (staging / production), tell the operator to add the same three vars to whichever deployment mechanism the consumer app uses (Kubernetes Secret, Docker Compose `env`, container-orchestrator secret store). Do NOT emit deployment-mechanism-specific YAML — the skill stays deployment-neutral per plugin AGENTS.md § *Langfuse deployment stance*.

Then verify traces end-to-end:

1. **Start the agent.** Watch for log lines confirming the TracerProvider was created (per the template's `logger.info` on successful init).
2. **Exercise a LangGraph flow.** Send a test query through the agent's normal entry point.
3. **Query the Langfuse REST API:**

   ```bash
   curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
     "$LANGFUSE_HOST/api/public/traces?limit=1" | jq '.data[0] | {id, name, observations: (.observations | length)}'
   ```

   Expected: non-empty `id`, `observations > 0`.
4. **Verify `gen_ai.*` attributes** appear on at least one observation. Pull one span and confirm:

   ```bash
   curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
     "$LANGFUSE_HOST/api/public/observations?limit=1&type=GENERATION" | jq '.data[0] | {model: .model, inputTokens: .promptTokens, outputTokens: .completionTokens}'
   ```

If any step fails, load `@references/troubleshooting.md` now. Do NOT load troubleshooting.md proactively — defer it to this failure path only.

**Do NOT declare success until traces are visible on the dashboard.**
