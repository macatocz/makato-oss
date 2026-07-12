# makato-temporal

**Goal**: Provide Temporal durable-execution reference skills for building, debugging, and operating workflows, activities, and workers across Python, TypeScript, Java, and Rust SDKs.

**How**: Ship progressive-disclosure reference skills that route the agent to language- and topic-scoped guidance (determinism, patterns, versioning, gotchas, observability, CLI) on demand.

**Why**: Temporal application code is easy to get subtly wrong — non-determinism, replay, versioning, and saga compensation all have non-obvious rules — and a curated reference skill keeps generated workflow code correct and durable.

## What Belongs Here

- Reference skills that teach an agent how to build and debug Temporal workflows, activities, and workers
- Language-scoped SDK guidance for the Temporal SDKs makato supports (Python, TypeScript, Java, Rust)
- Durable-execution concept references: determinism/replay, signals/queries/updates, versioning, continue-as-new, child workflows, saga/compensation, priority & fairness
- Temporal CLI and dev-server workflow-interaction guidance
- Third-party Temporal integration catalogs (Spring Boot, Spring AI, OpenAI Agents SDK, Google ADK, LangGraph, LangSmith)

## What Does NOT Belong Here

- General AI-agent framework guidance not tied to Temporal durable execution (belongs in `makato-langgraph`)
- Non-Temporal workflow or orchestration engines
- Product-specific application code or business workflows (belongs in the consuming repo)
- LLM-observability tooling unrelated to Temporal execution (belongs in `makato-observability`)
- SDK guidance for languages makato does not carry here (.NET, Go, Ruby)

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `temporal-development` | Build, debug, and manage Temporal applications across Python, TypeScript, Java, and Rust — workflows, activities, workers, determinism, signals/queries/updates, versioning, saga, and the Temporal CLI. | 0.6.0 |

## Installation

```bash
claude --plugin-dir ./plugins/makato-temporal
```

## Version

0.1.0
