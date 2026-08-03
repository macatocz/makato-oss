# makato-temporal — Contributor Guide

## Hard Constraints

- **Only Temporal durable-execution skills belong here.** General AI-agent framework guidance goes in `makato-langgraph`; non-Temporal workflow/orchestration engines are out of scope.
- **Never include product-specific application code or business workflows.** Those belong in the consuming repository.
- **LLM-observability tooling unrelated to Temporal execution belongs in `makato-observability`, not here.**
- **SDK guidance is limited to languages makato carries** (Python, TypeScript, Java, Rust). Do not add .NET, Go, Ruby, or other language guides without a corresponding plugin update.
- **Skills must emit JSONL audit entries** — session start, each major step, session end.

## Goal

Provide Temporal durable-execution reference skills for building, debugging, and operating workflows, activities, and workers across Python, TypeScript, Java, and Rust SDKs.

**How:** Ship progressive-disclosure reference skills that route the agent to language- and topic-scoped guidance (determinism, patterns, versioning, gotchas, observability, CLI) on demand.

**Why:** Temporal application code is easy to get subtly wrong — non-determinism, replay, versioning, and saga compensation all have non-obvious rules — and a curated reference skill keeps generated workflow code correct and durable.

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

## Decision Test

"Does this skill help an agent build, debug, or operate a Temporal durable-execution application?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version
- The frontmatter `name` MUST exactly match the skill's directory name

## File Structure

```
makato-temporal/
├── .claude-plugin/
│   └── plugin.json
├── CLAUDE.md
├── AGENTS.md
├── README.md
├── CHANGELOG.md
└── skills/
    └── temporal-development/
        ├── SKILL.md
        └── references/
            ├── core/            # language-agnostic concepts + CLI
            ├── python/          # Python SDK (canonical for the sagibeast runtime)
            ├── typescript/      # TypeScript SDK
            ├── java/            # Java SDK
            ├── rust/            # Rust SDK (Public Preview)
            └── integrations.md  # third-party integration catalog
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-temporal): description`
