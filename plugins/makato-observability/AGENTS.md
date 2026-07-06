# makato-observability — Contributor Guide

## Goal

Provide LLM-observability skills for tracing, monitoring, and debugging LangGraph-based AI agents — Langfuse-first via OpenTelemetry SDK + OTLP HTTP export, so LangGraph nodes running without a LangChain wrapper still land structured traces in Langfuse.

**How:** Ships a Langfuse-via-OTel instrumentation skill covering credential setup, Tracer / span-attribute conventions, OTLP HTTP exporter wiring to a Langfuse endpoint, an in-process exporter recipe for unit-test assertions, and dashboard-verification. Later skills add semantic-conventions alignment (including `gen_ai.*` for LLM spans), a cardinality-budget-first metric authoring workflow, and OTLP exporter tuning (batch / sampling / resource detectors).

**Why:** Closes the "is the LangGraph agent behaving in production?" gap between `makato-build` and production ops. Consumer repos already carry `langfuse` and `opentelemetry-sdk` as declared telemetry dependencies. LangGraph is typically embedded without the classic-LangChain callback surface, so the OTel-SDK-to-Langfuse-OTLP path is the primary code path that actually lands traces in Langfuse; the older "Langfuse LangChain callback" recipe does not apply to LangChain-free LangGraph deployments. `makato-langgraph` teaches how to author graphs; this plugin teaches how to make them observable at runtime.

## What Belongs Here

- OpenTelemetry SDK setup (Tracer, TracerProvider, resource attributes) for Python services running LangGraph nodes, exporting via OTLP HTTP/protobuf to a Langfuse endpoint
- In-process OTel span exporter recipe for unit tests that need to assert on emitted spans without a running Langfuse
- Langfuse SDK usage for reading/asserting traces after they arrive (`get_traces`, `get_latest_trace_for(correlation_id)`) — this is verification-side, not instrumentation-side
- Semantic conventions catalogue in `shared/` — HTTP, DB (Postgres / pgvector), and `gen_ai.*` attribute-name index every skill references
- Cardinality-budget-first metric authoring workflow — dimension budgets enforced before code hits a Prometheus / OTLP-metric backend
- OTLP exporter tuning (batch, timeout, retry, compression), sampling policy templates (head + tail), resource-detector patterns

## What Does NOT Belong Here

- LangChain-classic `CallbackHandler` wiring (including `from langfuse.langchain import CallbackHandler` and `config={"callbacks": [...]}` patterns). LangGraph consumers in scope run without the LangChain wrapper — that recipe does not apply. Add follow-up skills only when a consumer stack actually depends on classic LangChain
- LiteLLM-direct and PydanticAI wiring (out of consumer scope today)
- Temporal-worker observability, Postgres query-perf profiling — Postgres perf belongs in `makato-database`; Temporal is not in scope for this plugin
- Non-OTel and non-Langfuse observability — raw Prometheus scraping, log-aggregation pipeline (Loki / ELK / CloudWatch)
- Runbook authoring, incident triage prose, post-mortem authoring, SLO / error-budget calculators, PromQL alert-rule authoring
- Language-specific business-logic tests and type-checks — that is `makato-build/build-verify`. This plugin only instruments; it does not verify correctness

## Decision Test

"Does this skill help make a shipped LangGraph agent or Python service observable at runtime through OpenTelemetry (typically exporting to Langfuse via OTLP), without also being a non-observability tool (test, alert, incident, correctness)?"

- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references and templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache)
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`
- Every Langfuse-touching skill MUST start with credential setup (`LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`) via `AskUserQuestion` — no default endpoint is assumed, and the three deployment paths (Langfuse Cloud / self-hosted / e2e-local) are first-class choices. See § *Langfuse deployment stance*.
- OTel skills MUST default to OTLP HTTP/protobuf (Langfuse-compatible), not gRPC, unless the caller explicitly names a gRPC-only collector
- Instrumentation code emitted by skills MUST use the OpenTelemetry SDK directly (Tracer + spans + resource attrs). Skills MUST NOT emit LangChain-classic `CallbackHandler`, LiteLLM-direct, or PydanticAI wiring examples — those framework-callback bridges are not the primary code path here

## Langfuse deployment stance

This plugin is **deployment-neutral**. Skills MUST NOT hard-code any hosting provider or cluster-specific URL pattern. The three supported deployment paths are:

1. **Langfuse Cloud** — `https://cloud.langfuse.com` (US) or `https://eu.cloud.langfuse.com` (EU). The skill accepts either via the `LANGFUSE_HOST` value the caller supplies; it does not choose the region for them.
2. **Self-hosted** — any Helm / Docker / Kubernetes deployment the consumer owns. The skill accepts the arbitrary `LANGFUSE_HOST` URL the caller supplies and treats it identically to the Cloud path. No provider names appear in prose, examples, or templates.
3. **E2E-local** — a locally-run Langfuse instance (typically a `docker compose` bring-up) used for end-to-end tests. The skill MAY include a reference to spin up a local Langfuse for testing, but the SKILL.md prose MUST frame it as "the same deployment shape the consumer app uses in production" — the app under test picks the deployment; the plugin does not.

Rationale: bundling any provider-specific deployment guidance into the plugin couples makato-observability to whichever cluster the current consumer happens to run on. Consumers migrate; the plugin should not. Any reference material that carries hosting-provider branding (external skill sources, upstream tutorials, vendor docs) MUST be de-branded before it lands here — no vendor names, no cluster DNS patterns, no cloud-account artefacts in prose, examples, or templates.

## File Structure

```text
makato-observability/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── (empty — populate via makato-skill-creator; first planned: langfuse-instrument via OTel SDK)
├── shared/
│   └── (semantic-conventions catalogue, cardinality budgets, span-attribute conventions)
├── CLAUDE.md
├── AGENTS.md
├── README.md
└── CHANGELOG.md
```

## Versioning

- No `version` in `plugin.json` (repo versioned via release-please + git tags)
- Skill versions: bumped in `SKILL.md` frontmatter per feature PR
- `CHANGELOG.md`: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal — instruments a LangGraph agent or Python service for runtime observability via OTel SDK
- [ ] Skill is self-contained (no `../` outside its own directory or `shared/` symlink)
- [ ] Langfuse skills gather credentials via `AskUserQuestion` before writing code
- [ ] OTel skills default to OTLP HTTP/protobuf unless a gRPC collector is named
- [ ] Instrumentation code uses OpenTelemetry SDK directly — no LangChain `CallbackHandler`, LiteLLM-direct, or PydanticAI wiring
- [ ] Semantic-convention attribute names come from `shared/` — not invented
- [ ] No hosting-provider or cluster-specific names in prose, examples, or templates — see § *Langfuse deployment stance*
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-observability): description`
