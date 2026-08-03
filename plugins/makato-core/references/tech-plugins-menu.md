<!-- markdownlint-disable MD013 -->
# Tech Plugins — Installable makato Toolkits

All 10 installable plugins are listed below. Each entry includes a one-line
description and the command to install it from a local clone of the makato repo.

---

| # | Plugin | Description | Install command |
|---|--------|-------------|-----------------|
| 1 | `makato-build` | End-to-end autonomous build pipeline — refine, implement (TDD or goal mode), verify, push, and open a pull request with sensor gates. | `claude --plugin-dir ./plugins/makato-build` |
| 2 | `makato-plan` | Product planning toolkit — brainstorm, PRD, architecture, UX design, story decomposition, acceptance tests, and GitHub issue creation. | `claude --plugin-dir ./plugins/makato-plan` |
| 3 | `makato-change` | Change-request workflow — analyse, design, implement, and review targeted code changes driven by GitHub issue descriptions. | `claude --plugin-dir ./plugins/makato-change` |
| 4 | `makato-orchestrate` | Autonomous loop driver — polls a GitHub Projects v2 board, dispatches the PO-agent per issue, and manages the full worktree lifecycle. | `claude --plugin-dir ./plugins/makato-orchestrate` |
| 5 | `makato-langgraph` | LangGraph development patterns — fundamentals, persistence, human-in-the-loop, reflexion, and multi-agent graph patterns for Python. | `claude --plugin-dir ./plugins/makato-langgraph` |
| 6 | `makato-temporal` | Temporal workflow development — durable execution, activities, workers, signals, queries, versioning, and Temporal CLI usage across SDK languages. | `claude --plugin-dir ./plugins/makato-temporal` |
| 7 | `makato-fastapi` | FastAPI service development — routing, Pydantic models, dependency injection, testing, and async patterns for Python REST APIs. | `claude --plugin-dir ./plugins/makato-fastapi` |
| 8 | `makato-database` | Database management — schema design, migrations, query optimisation, and PostgreSQL administration for AI-native application backends. | `claude --plugin-dir ./plugins/makato-database` |
| 9 | `makato-ux` | Frontend and UX toolkit — E2E testing patterns, frontend design, Penpot UI/UX design, and web app verification with Playwright. | `claude --plugin-dir ./plugins/makato-ux` |
| 10 | `makato-observability` | Observability instrumentation — Langfuse tracing setup, enrichment, and operations for tracking LLM calls and agent runs. | `claude --plugin-dir ./plugins/makato-observability` |

---

## Installing Multiple Plugins

Multiple plugins can be installed simultaneously by passing multiple
`--plugin-dir` flags:

```bash
claude \
  --plugin-dir ./plugins/makato-build \
  --plugin-dir ./plugins/makato-plan \
  --plugin-dir ./plugins/makato-orchestrate
```

Or add them to `.claude/settings.json` under `pluginDirs` for permanent activation
across all sessions in this repository.

## Recommended Starting Sets

**Full autonomous loop** (plan → build → orchestrate):

```bash
claude \
  --plugin-dir ./plugins/makato-plan \
  --plugin-dir ./plugins/makato-build \
  --plugin-dir ./plugins/makato-orchestrate
```

**Backend service development** (build + stack plugins):

```bash
claude \
  --plugin-dir ./plugins/makato-build \
  --plugin-dir ./plugins/makato-fastapi \
  --plugin-dir ./plugins/makato-database \
  --plugin-dir ./plugins/makato-observability
```

**Change-request focused** (no planning, targeted fixes):

```bash
claude \
  --plugin-dir ./plugins/makato-change \
  --plugin-dir ./plugins/makato-build
```
