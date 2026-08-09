# makato-observability

**Goal:** Add structured LLM-observability to LangGraph-based AI agents via OpenTelemetry SDK and
OTLP HTTP export, so nodes running without a LangChain wrapper land clean traces in Langfuse.

**How:** Ships a Langfuse-via-OTel instrumentation skill that handles credential setup, TracerProvider
and OTLP HTTP exporter wiring, `gen_ai.*` semantic-convention span attributes on LangGraph nodes,
an in-process `InMemorySpanExporter` recipe for unit-test assertions, and mandatory dashboard
verification. Planned follow-on skills add a semantic-conventions catalogue, cardinality-budget
metric authoring, and OTLP exporter tuning (batch, sampling, resource detectors).

**Why:** Closes the "is the LangGraph agent behaving in production?" gap between `makato-build` and
production ops. LangGraph is typically embedded without the classic LangChain callback surface, so
`OTel SDK → OTLP → Langfuse` is the primary code path that lands traces. `makato-langgraph` teaches
how to author graphs; this plugin teaches how to make them observable at runtime.

---

## What Belongs Here

- OpenTelemetry SDK setup (Tracer, TracerProvider, resource attributes) for Python services running
  LangGraph nodes, exporting via OTLP HTTP/protobuf to a Langfuse endpoint
- In-process OTel span exporter recipe for unit tests that need to assert on emitted spans without a
  running Langfuse
- Langfuse SDK usage for reading/asserting traces after they arrive (`get_traces`,
  `get_latest_trace_for`) — verification-side, not instrumentation-side
- Semantic conventions catalogue in `shared/` — HTTP, DB (Postgres / pgvector), and `gen_ai.*`
  attribute-name index every skill references
- Cardinality-budget-first metric authoring workflow — dimension budgets enforced before code hits a
  Prometheus / OTLP-metric backend
- OTLP exporter tuning (batch, timeout, retry, compression), sampling policy templates (head + tail),
  resource-detector patterns

## What Does NOT Belong Here

- LangChain-classic `CallbackHandler` wiring
  (`from langfuse.langchain import CallbackHandler, config={'callbacks': [...]}`) — LangGraph
  consumers run without the LangChain wrapper
- LiteLLM-direct and PydanticAI wiring (out of consumer scope today)
- Temporal-worker observability and Postgres query-perf profiling — Postgres perf belongs in
  `makato-database`
- Non-OTel and non-Langfuse observability — raw Prometheus scraping, log-aggregation pipelines
  (Loki / ELK / CloudWatch)
- Runbook authoring, incident triage prose, post-mortem authoring, SLO / error-budget calculators,
  PromQL alert-rule authoring
- Language-specific business-logic tests and type-checks — that is `makato-build/build-verify`; this
  plugin only instruments

---

## Workflow

This plugin contains a single interactive instrumentation skill. The invocation order below shows
how it fits within a typical development session:

```
makato-langgraph            makato-build              makato-observability
(author graph)              (build & verify)           (instrument)
      │                           │                           │
      ▼                           ▼                           ▼
┌─────────────┐         ┌────────────────┐       ┌───────────────────────────┐
│ LangGraph   │──────►  │ build-implement│──────►│ langfuse-instrument       │
│ agent code  │         │ -tdd / -goal   │       │                           │
└─────────────┘         └────────────────┘       │ Step 0: Gather creds      │
                                                  │ Step 1: Validate LangGraph│
                                                  │ Step 2: Check deps        │
                                                  │ Step 3: Wire TracerProvider│
                                                  │ Step 4: Wrap nodes (spans)│
                                                  │ Step 5: Add test fixture  │
                                                  │ Step 6: Verify dashboard  │
                                                  └───────────┬───────────────┘
                                                              │
                                                              ▼
                                                   Traces visible in Langfuse
                                                   + InMemoryExporter fixture
                                                   + .env.local populated
```

| Phase | Input | Output |
|-------|-------|--------|
| Credential gathering | Interactive prompts (LANGFUSE_HOST, PUBLIC_KEY, SECRET_KEY) | `.env.local` populated |
| LangGraph validation | Python service path | Confirmed LangGraph nodes, no LangChain wrapper |
| TracerProvider wiring | Consumer bootstrap module | OTel SDK + OTLP HTTP exporter wired |
| Span instrumentation | LangGraph node functions | `gen_ai.*` attribute spans wrapping each node |
| Test fixture | Consumer test helpers | `InMemorySpanExporter` pytest fixture |
| Dashboard verification | Running agent + Langfuse access | Traces confirmed visible in Langfuse |

---

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [langfuse-instrument](skills/langfuse-instrument/SKILL.md) | Add OpenTelemetry-based Langfuse tracing to a LangGraph-based AI agent. Wires the OTel SDK (Tracer, TracerProvider, OTLP HTTP exporter) to a Langfuse endpoint so LangGraph nodes running without a LangChain wrapper land structured traces. Includes in-process exporter recipe for unit-test assertions and mandatory dashboard verification. (interactive) | Python service with LangGraph nodes (no LangChain CallbackHandler); Langfuse credentials (LANGFUSE_HOST, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY) gathered interactively | OTel TracerProvider + OTLP HTTP exporter wired into consumer bootstrap; LangGraph nodes wrapped with `gen_ai.*` spans; `InMemorySpanExporter` pytest fixture; `.env.local` populated; traces verified on Langfuse dashboard | 0.1.0 |
| [langfuse-enrich](skills/langfuse-enrich/SKILL.md) | Layer Langfuse enrichment fields onto already-OTel-instrumented LangGraph agents — sessions, users, environments, tags, metadata, log levels, cross-service distributed tracing, user-feedback scores, PII masking (`mask_otel_spans`), and token/cost tracking. OTel-native `span.set_attribute` path primary. (technical) | An agent already instrumented via `langfuse-instrument`; the enrichment feature(s) to add | `langfuse.*` enrichment attributes set on node spans; W3C `traceparent` wired across service hops; `create_score` feedback flow; `mask_otel_spans` hook wired to the project PII layer; per-generation usage/cost | 1.0.0 |
| [langfuse-ops](skills/langfuse-ops/SKILL.md) | Ops companion — interact with Langfuse data and docs against a running instance: read-only `langfuse-cli` access to traces/scores/datasets/sessions, documentation lookup, trace-based error analysis, LLM-as-a-judge calibration, CI/CD experiment gates, and SDK-upgrade migration. Autonomous context-based routing with an `AskUserQuestion` fallback. (technical) | `LANGFUSE_HOST` (self-hosted/local) + public/secret keys; the task signal (error/upgrade/ci/docs/judge/cli/feedback) | Routed to the matching workflow reference; data queried, docs fetched, errors analyzed, judges calibrated, gates wired, or SDK upgraded | 1.0.0 |

---

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|------------|
| Consumes from | `makato-langgraph` | LangGraph graphs authored with `langgraph-fundamentals` / `langgraph-agent-patterns` are the instrumentation target — `langfuse-instrument` adds OTel tracing to those agents |
| Consumes from | `makato-build` | Agents built via the TDD/goal pipeline (`build-implement-tdd`, `build-implement-goal`) receive OTel tracing as a follow-on observability step |
| Complements | `makato-database` | Postgres query-perf profiling belongs in `makato-database`; DB span attribute naming (`db.*`) is documented in this plugin's `shared/` catalogue |
| Complements | `makato-ux` | E2E tests authored with `makato-ux` `e2e-testing-patterns` can assert on OTel spans emitted by instrumented agents |

---

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-observability/AGENTS.md` | Canonical contributor guide — Goal, How, Why, What Belongs / Does Not Belong, Skill Authoring rules, Langfuse deployment stance, PR checklist |
| `plugins/makato-observability/.claude-plugin/plugin.json` | Plugin registration metadata — name, description, author |
| `plugins/makato-observability/skills/langfuse-instrument/SKILL.md` | Seven-step `langfuse-instrument` skill — credential gathering, LangGraph validation, dependency checks, TracerProvider wiring, span instrumentation, in-process test exporter, and mandatory dashboard verification |
| `plugins/makato-observability/skills/langfuse-instrument/references/deployment-paths.md` | Reference for the three Langfuse deployment paths — Cloud, self-hosted, and e2e-local — consumed in Step 0 of `langfuse-instrument` |
| `plugins/makato-observability/skills/langfuse-instrument/references/otel-setup.md` | Reference for wiring OTel TracerProvider, Resource, BatchSpanProcessor, and OTLPSpanExporter targeting Langfuse — consumed in Step 3 |
| `plugins/makato-observability/skills/langfuse-instrument/references/span-attribute-conventions.md` | Canonical `gen_ai.*` and related semantic-convention attribute names to use when instrumenting LangGraph nodes — consumed in Step 4 |
| `plugins/makato-observability/skills/langfuse-instrument/references/inprocess-exporter.md` | Reference for the `InMemorySpanExporter` + `SimpleSpanProcessor` pytest fixture pattern — consumed in Step 5 |
| `plugins/makato-observability/skills/langfuse-instrument/references/langgraph-otel-integration.md` | Reference verifying the LangGraph-on-OTel-SDK integration path (vs. classic-LangChain callback path) — consumed in Step 1 |
| `plugins/makato-observability/skills/langfuse-instrument/references/troubleshooting.md` | Troubleshooting guide walked when Step 6 dashboard verification fails |
| `plugins/makato-observability/skills/langfuse-instrument/templates/otel-setup.py` | Bootstrap template for TracerProvider + OTLP HTTP exporter — silent no-op when `LANGFUSE_PUBLIC_KEY` is unset; copied into consumer bootstrap module in Step 3 |
| `plugins/makato-observability/skills/langfuse-instrument/templates/otel-inprocess-exporter.py` | `InMemorySpanExporter` pytest fixture template for unit-test span assertions without a running Langfuse — copied into consumer test helpers in Step 5 |
| `plugins/makato-observability/skills/langfuse-instrument/templates/env-local.example` | Example `.env.local` file showing the three required `LANGFUSE_*` environment variables — provided to operators in Step 6 |
| `plugins/makato-observability/CHANGELOG.md` | Release history updated with each PR per AGENTS.md convention |

---

## Prerequisites / MCP Servers

None — pure reference skills, no MCP servers required.

---

## Installation

```bash
claude --plugin-dir ./plugins/makato-observability
```

---

## Version

0.1.0
