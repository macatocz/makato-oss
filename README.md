# makato

A curated suite of [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) plugins that
take software work from raw idea to merged pull request — planning, building, reviewing,
orchestrating, and observing AI agents along the way.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why makato

Claude Code ships as a general-purpose CLI. makato adds opinionated skills, agents, and hooks that
turn it into a working software team: it drafts specs from vague feature requests, refines them
into implementation plans, writes tested code, reviews the diff, opens the pull request, and
answers reviewer comments — with a kill-switch you can hit at any boundary.

Each plugin owns one phase of that workflow. Install the ones you need; skip the rest.

## Prerequisites

- **[Claude Code](https://docs.claude.com/en/docs/claude-code/setup)** installed and authenticated
  (`claude` on your `PATH`).
- **git** and a **GitHub** account. Most workflows push branches, open PRs, and read/write GitHub
  Issues.
- **`gh` CLI** authenticated (`gh auth login`) — required by `makato-plan`, `makato-build`, and
  `makato-orchestrate` for issue and PR operations.
- **Python 3.11+** — only if you plan to run the repo's smoke tests or contribute to plugins that
  ship pytest fixtures (`makato-build`, `makato-sagibeast`).

Individual plugins may add their own requirements (for example, `makato-database` expects a
reachable Postgres instance). See each plugin's `README.md` for its specifics.

## Install

Add the marketplace once, then install any subset of plugins.

```bash
claude plugin marketplace add https://github.com/zstary/makato
claude plugin install makato-core@makato-suite
claude plugin install makato-build@makato-suite
```

Or interactively inside Claude Code:

```text
/plugin marketplace add https://github.com/zstary/makato
/plugin install makato-core@makato-suite
```

Verify the install:

```bash
claude plugin list
```

To try a plugin without installing it, point Claude Code at a local clone:

```bash
git clone https://github.com/zstary/makato.git
claude --plugin-dir ./makato/plugins/makato-core
```

## Quick start

The three most common entry points, once at least `makato-core` and one workflow plugin are
installed:

```text
/makato-guide         # discover what's installed and which skill fits your task
/build-start          # begin a build session against an existing GitHub issue
/analyze              # start a change request against an existing feature
```

A typical end-to-end flow for a new feature:

1. `/brainstorm` and `/prd` (from `makato-plan`) shape the idea into a spec and vertically-sliced
   GitHub issues.
2. `/build-start` (from `makato-build`) picks up a shaped issue and drives it through refine →
   implement → verify → PR.
3. `/address-pr-comments` resolves reviewer feedback until the PR merges.

For an unattended run, install `makato-orchestrate` and point its poller at a GitHub Projects v2
board — it will pick up "Ready" issues one at a time and drive them autonomously until they merge
or a HALT fires.

## Plugins

| Plugin                                                 | Purpose                                                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| [`makato-core`](plugins/makato-core/)                   | Shared utilities: codebase navigation, README authoring, GitHub issue filing, library reference lookup. |
| [`makato-contribute`](plugins/makato-contribute/)       | Scaffold new plugins and skills, resolve PR bot feedback, sync from upstream repos.                     |
| [`makato-plan`](plugins/makato-plan/)                   | Turn feature requests into shaped GitHub issues with acceptance criteria.                               |
| [`makato-build`](plugins/makato-build/)                 | Take a shaped issue through refine → implement → verify → PR.                                        |
| [`makato-orchestrate`](plugins/makato-orchestrate/)     | Autonomous control plane for driving issues to merged PRs unattended.                                   |
| [`makato-change`](plugins/makato-change/)               | Implement changes against existing functionality when business requirements shift.                      |
| [`makato-ux`](plugins/makato-ux/)                       | Frontend design, E2E testing patterns, in-browser verification.                                         |
| [`makato-langgraph`](plugins/makato-langgraph/)         | Reference skills for building LangGraph Python agents (StateGraph, ReAct, HITL, persistence).           |
| [`makato-database`](plugins/makato-database/)           | Postgres performance, query writing, schema design.                                                     |
| [`makato-sagibeast`](plugins/makato-sagibeast/)         | Word template extraction, PDF/Excel processing, testbox VM tooling.                                     |
| [`makato-observability`](plugins/makato-observability/) | Trace and debug LangGraph agents via OpenTelemetry → Langfuse. Vendor-neutral.                         |

## Contributing

This repo is a monorepo of Claude Code plugins. Each plugin under `plugins/` owns its own
`AGENTS.md` with the rules that govern its surface — read that file first before editing anything
under `plugins/<name>/`.

A repo-root routing index is generated on demand from each plugin's `AGENTS.md`. It lives at the
repo root as `AGENTS.md` / `CLAUDE.md` and is intentionally gitignored — the file is a
per-checkout local artefact, not part of the plugin distribution.

```bash
./scripts/regenerate-agents.sh
```

Run after adding or removing a plugin. The output is idempotent — re-running produces
byte-identical content unless a plugin's `AGENTS.md` or `plugin.json` description changed.

To have it run on every Claude Code SessionStart, add a hook to your own
`.claude/settings.local.json` (gitignored, so it stays your personal preference and does not
impose on other contributors):

```jsonc
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command",
                  "command": "${CLAUDE_PROJECT_DIR}/scripts/regenerate-agents.sh"}]}
    ]
  }
}
```

### Smoke tests

The repo ships a small **pytest harness** scoped narrowly to skill smoke tests and existing
per-plugin unit tests. It is not a declaration that "makato is a Python package" — plugin
distribution remains via Claude Code's plugin marketplace. The harness exists so contract-critical
skills (`build-simplify`'s no-test-runner handling, `inject_context.resolve_bundles`, the
`dotx-schema-extractor` curation pipeline) regress on every change.

Run from the repo root:

```bash
python3 -m pytest
```

The harness discovers tests in three locations declared in `pyproject.toml` →
`[tool.pytest.ini_options].testpaths`:

- `tests/` — repo-level smoke tests (e.g. `test_smoke_build_simplify.py`)
- `plugins/makato-build/shared/` — context-bundle resolver unit tests
- `plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/` — curation tests

Adding a test runner to plugins that don't already have one is explicitly out of scope — the
harness only covers existing pytest-collectable code.

## License

makato is released under the [MIT License](LICENSE).
