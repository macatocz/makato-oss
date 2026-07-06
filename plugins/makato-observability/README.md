# makato-observability

**Goal**: Provide LLM-observability skills for tracing, monitoring, and debugging LangGraph-based AI agents — Langfuse-first via OpenTelemetry SDK + OTLP HTTP export, so LangGraph nodes running without a LangChain wrapper still land structured traces in Langfuse.

**How**: Ships a Langfuse-via-OTel instrumentation skill covering credential setup, Tracer / span-attribute conventions, OTLP HTTP exporter wiring to a Langfuse endpoint, an in-process exporter recipe for unit-test assertions, and dashboard-verification. Later skills add semantic-conventions alignment (`gen_ai.*` for LLM spans), a cardinality-budget metric authoring workflow, and OTLP exporter tuning.

**Why**: Closes the "is the LangGraph agent behaving in production?" gap between `makato-build` and production ops. Consumer repos already carry `langfuse` and `opentelemetry-sdk` as declared telemetry dependencies. LangGraph is typically embedded without the classic-LangChain callback surface, so OTel SDK → OTLP → Langfuse is the primary code path that actually lands traces. `makato-langgraph` teaches how to author graphs; this plugin teaches how to make them observable at runtime.

## What Belongs Here

- OpenTelemetry SDK setup for Python services running LangGraph — Tracer, TracerProvider, resource attrs, OTLP HTTP exporter targeting a Langfuse endpoint
- In-process OTel span exporter recipe for unit-test assertions (no running Langfuse required)
- Langfuse SDK usage for reading/asserting traces after they arrive (verification-side, not instrumentation-side)
- Semantic conventions catalogue in `shared/` — HTTP, DB (Postgres / pgvector), `gen_ai.*` for LLM spans
- Cardinality-budget-first metric authoring workflow — dimension budgets enforced before metrics land
- OTLP exporter tuning (batch, timeout, retry, compression), sampling policy templates, resource-detector patterns

## What Does NOT Belong Here

- LangChain-classic `CallbackHandler` wiring — LangGraph consumers in scope run without the wrapper; that recipe does not apply
- LiteLLM-direct, PydanticAI (out of consumer scope today)
- Temporal-worker observability, Postgres query-perf profiling (Postgres perf lives in `makato-database`)
- Non-OTel and non-Langfuse observability — raw Prometheus, Loki / ELK, CloudWatch logs
- Runbook / incident / SLO / alert authoring
- Business-logic tests and type-checks (that is `makato-build/build-verify`)

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| [`langfuse-instrument`](skills/langfuse-instrument/SKILL.md) | Wire OpenTelemetry SDK + OTLP HTTP exporter to a Langfuse endpoint for a LangGraph-based agent. Cloud / self-hosted / e2e-local deployment paths. Includes in-process exporter recipe for unit tests. | 0.1.0 |

## Installation

```bash
claude --plugin-dir ./plugins/makato-observability
```

## Version

0.1.0
