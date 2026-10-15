# Changelog — makato-observability

<!-- markdownlint-disable MD013 -->

## [Unreleased]

### Fixed

- Health probes accept only HTTP/HTTPS endpoints and same-origin redirects,
  preserving fail-open behavior and timeouts without allowing local-file or
  cross-origin redirect access. Added protocol-boundary regression coverage.
- E2E result emission uses the supported observation API and propagates tags,
  replacing the removed `client.trace` call. A real SDK-to-local-OTLP regression
  verifies exported outcome data and audit trace identity.

### Added

- `langfuse-enrich` skill — layers Langfuse enrichment onto already-OTel-instrumented LangGraph agents (sessions, users, environments, tags, metadata, log levels, cross-service distributed tracing, user-feedback scores, `mask_otel_spans` PII masking, token/cost tracking). 7 references under `skills/langfuse-enrich/references/`: `session-and-user-propagation.md`, `environment-and-tags.md`, `metadata-and-log-levels.md`, `distributed-tracing.md`, `user-feedback.md`, `masking.md`, `token-and-cost.md`. OTel-native `span.set_attribute` path primary; Langfuse-SDK convenience APIs documented as an optional alternative.
- `langfuse-instrument` gains `references/js-ts-first-trace.md` — the JS/TS `NodeSDK` + `LangfuseSpanProcessor` OTel bootstrap for serverless/edge agents (AGENTS.md scope extended to JS/TS OTel clients). Enrichment of the resulting spans is handled by `langfuse-enrich`.
- `plugins/makato-observability/shared/` populated with `span-attribute-conventions.md` (now carrying a **Langfuse enrichment** section: canonical `langfuse.session.id`, `langfuse.user.id`, `langfuse.environment`, `langfuse.trace.tags`, `langfuse.trace.metadata.<key>`, `langfuse.observation.usage_details`) and `langgraph-otel-integration.md`; both `langfuse-ops` and `langfuse-enrich` skills carry a `shared/` symlink so they reference the catalogue rather than redefining it.
- `langfuse-ops` skill — ops companion for interacting with Langfuse data and docs against a running instance (read-only `langfuse-cli` access, documentation lookup, trace-based error analysis, LLM-as-a-judge calibration, CI/CD experiment gates, SDK-upgrade migration). Autonomous context-based use-case routing with an `AskUserQuestion` fallback. 8 references under `skills/langfuse-ops/references/`: `credentials.md`, `docs-lookup.md`, `cli.md`, `error-analysis.md`, `judge-calibration.md`, `ci-cd.md`, `sdk-upgrade.md`, `skill-feedback.md`. Self-hosted / local only (`LANGFUSE_HOST` primary).
- `span-attribute-conventions.md` gains a **Langfuse enrichment** section — canonical names for `langfuse.session.id`, `langfuse.user.id`, `langfuse.environment`, `langfuse.tags`, `langfuse.metadata`, `langfuse.observation.usage_details`; `langfuse-enrich` references this table rather than defining its own.

### Changed

- AGENTS.md § *What Belongs Here* extended to admit Langfuse enrichment fields, the data-and-docs ops surface, and JS/TS OTel-SDK clients (previously Python-only). Decision test widened accordingly.
- `config/skill-bundles.yml` — `observability-skills` and `observability-otel` bundles now route `langfuse-ops` and `langfuse-enrich` alongside `langfuse-instrument`; added enrichment content-hint predicates and task triggers.


- `langfuse-instrument` skill — wires OpenTelemetry SDK to a Langfuse OTLP HTTP endpoint for LangGraph-based agents (see the skill's SKILL.md for the 7-step workflow)
- 6 references under `skills/langfuse-instrument/references/`: `deployment-paths.md`, `langgraph-otel-integration.md`, `otel-setup.md`, `span-attribute-conventions.md`, `inprocess-exporter.md`, `troubleshooting.md`
- 3 templates under `skills/langfuse-instrument/templates/`: `otel-setup.py`, `otel-inprocess-exporter.py`, `env-local.example`

### Changed

- AGENTS.md § Goal / How / Why rewritten to name the primary code path as "OpenTelemetry SDK + OTLP HTTP export" (was: "native LangChain-callback bridge"). LangGraph consumers in scope run without the LangChain wrapper; the callback recipe does not apply and is now explicitly out of scope.
- Plugin description in `plugin.json` and `.claude-plugin/marketplace.json` synced to the OTel-SDK framing.
- Decision test tightened to "…observable at runtime through OpenTelemetry (typically exporting to Langfuse via OTLP)…"

## [0.1.0] — 2026-07-06

### Added

- Initial plugin scaffold with governance files
- Plugin manifest (`plugin.json`) with vendor-neutral description
- Contributor guide (`AGENTS.md`) including § *Langfuse deployment stance*
- Contributor + user documentation (`README.md`)
- `shared/` directory placeholder for the future semantic-conventions catalogue, cardinality-budget templates, and span-attribute conventions
- `skills/` directory placeholder — first planned skill (`langfuse-instrument` via OpenTelemetry SDK + OTLP HTTP export to a Langfuse endpoint) added via `makato-skill-creator` in a follow-up PR
- Marketplace registration in `.claude-plugin/marketplace.json`
- Marketplace registration in `.claude-plugin/marketplace.json`
