# makato Codebase Architecture

> **Scope**: High-level structure of the makato monorepo — how plugins, skills,
> agents, and shared helpers fit together. `context-scout` surfaces this as
> **High**-tier "existing patterns / architecture" background when a feature
> touches existing code.

## Monorepo shape

makato is a **monorepo of Claude Code plugins**. Each plugin lives under
`plugins/<name>/` and owns its own `AGENTS.md`, `README.md`, `CHANGELOG.md`,
`skills/`, `agents/`, and (optionally) `shared/` and `config/`.

The marketplace is declared in `.claude-plugin/marketplace.json`. Releases use
release-please + conventional commits.

## Plugin anatomy

```
plugins/<plugin>/
├── AGENTS.md          # Authoritative contract for this plugin
├── README.md
├── CHANGELOG.md
├── skills/<skill>/    # SKILL.md + references/ + templates/
├── agents/*.md        # Subagent definitions (frontmatter + prose)
├── shared/            # Plugin-local helpers (*.py stdlib libs, *.sh)
└── config/            # e.g. context-bundles.yml, skill-bundles.yml
```

## The plan → build → orchestrate pipeline

- **makato-plan** turns a raw request into vertically-sliced GitHub issues
  (brainstorm → PRD → architecture → UX → decompose → to-issues).
- **makato-build** turns a decomposed story into merged code
  (refine → implement-tdd/goal → simplify → review → verify → push → PR).
- **makato-orchestrate** is the autonomous control plane: `loop` polls a
  Projects v2 board, dispatches the PO-agent per Ready issue, and the PO-agent
  drives makato-build skills to a merged PR or a documented HALT code.

## Shared-helper conventions

Python helpers under `plugins/*/shared/` are importable, stdlib-only libraries
(see `standards/python.md`). `inject_context.py` is the canonical reference for
the pure-function / typed-exception / HALT-code style.

<!-- POPULATE: add bounded-context / integration-seam detail as the codebase
     grows. Reference concrete files; keep entries to 2-3 sentences. -->
