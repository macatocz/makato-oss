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
- **Python 3.14+** — only if you plan to run the repo's smoke tests or contribute to plugins that
  ship pytest fixtures (`makato-build`, `makato-sagibeast`). Pinned in `pyproject.toml`
  (`requires-python = ">=3.14"`) and in the audit CI workflows.

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

## Running skills

### Interactively (Claude Code session)

Open Claude Code in the repo and type the skill name directly:

```text
/makato-build:build-start
/makato-plan:brainstorming My new feature idea
/makato-change:orchestrate
```

### Headlessly via OMP

On a provisioned vast.ai box, `omp` routes every agent role through the local vLLM endpoint
(configured by `infra/omp-config.yml` and `infra/omp-models.yml` — no AWS Bedrock token
required):

```bash
MAKATO_HEADLESS=1 omp --yolo -p "/makato-build:build-start"
```

On a local machine without a vLLM endpoint, use `claude` directly:

```bash
MAKATO_HEADLESS=1 claude --dangerously-skip-permissions -p "/makato-build:build-start"
```

`MAKATO_HEADLESS=1` is mandatory for every non-interactive invocation — omitting it causes
`MISSING_INPUT: headless-without-autonomous`.

## Autonomous loop

The `makato-orchestrate:loop` skill polls a GitHub Projects v2 board for `Status=Ready` issues and
drives each one to a merged PR unattended.

### Loop prerequisites

```bash
# One-time setup: initialise board sync (populates .claude/config.json → github_project)
/makato-plan:issue-to-project --init
```

### Start the loop

The loop dispatches each issue by calling `$MAKATO_HARNESS_BIN --yolo`. On a provisioned
vast.ai box, set `MAKATO_HARNESS_BIN` to `omp` — it supports `--yolo` natively:

```bash
MAKATO_HARNESS_BIN="/root/.local/bin/omp" \
  nohup /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run --status Ready \
  > ~/.claude/state/loop.log 2>&1 &
disown
```

On a local machine where `claude` is the harness, use the `claude-harness` shim that
translates `--yolo` → `--dangerously-skip-permissions`:

```bash
MAKATO_HARNESS_BIN="$HOME/.claude/bin/claude-harness" \
  nohup plugins/makato-orchestrate/scripts/loop.sh run --status Ready \
  > ~/.claude/state/loop.log 2>&1 &
disown
```

The `nohup`+`disown` detaches the loop so a background-session reap does not kill it mid-dispatch.

### Monitor

```bash
# Live status (refreshes every 5 s)
watch -n 5 plugins/makato-orchestrate/scripts/loop.sh status

# Tail the dispatch log
tail -f ~/.claude/state/loop.log
```

### Stop the loop

```bash
# Graceful stop after the current issue finishes
touch ~/.claude/HALT

# Remove the HALT file to allow the next run
rm ~/.claude/HALT
```

### One-shot run (smoke test / manual dispatch)

```bash
# Inspect the queue without dispatching anything
MAKATO_HARNESS_BIN="$HOME/.claude/bin/claude-harness" \
  plugins/makato-orchestrate/scripts/loop.sh run --dry-run --once

# Dispatch exactly one Ready issue and exit
MAKATO_HARNESS_BIN="$HOME/.claude/bin/claude-harness" \
  plugins/makato-orchestrate/scripts/loop.sh run --once
```

### Recover from a stale active_workflow

If the loop was killed mid-dispatch, `loop-status.json` may have a stale `active_workflow` entry
that prevents the next dispatch. Clear it with:

```bash
jq '.active_workflow = null' .claude/state/loop-status.json \
  | sponge .claude/state/loop-status.json
```

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

## Infrastructure

makato's autonomous skills call an open LLM endpoint served by **vLLM** on a vast.ai GPU box.
See [`docs/vast-ai-llm-deployment.md`](docs/vast-ai-llm-deployment.md) for the full runbook —
version pins, gotchas, and why the setup is the way it is.

To bring up a fresh or migrated box in one command:

```bash
# full run — LLM + sagibeast stack + Cloudflare tunnel on your domain:
HF_TOKEN=hf_xxx ./scripts/vast-provision-all.sh <IP>

# stack only (no LLM, no tunnel):
./scripts/vast-provision-all.sh <IP> --no-llm --no-tunnel
```

The script auto-detects the SSH port from the vast.ai API, repairs the box, rsyncs the repos,
bootstraps the vLLM endpoint (driver → reboot → venv → model → systemd), brings up the
sagibeast compose stack, and prints the connection cheat-sheet. Run it any time — it is
idempotent.

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

### Release automation

Releases are cut by [release-please](https://github.com/googleapis/release-please) on every
push to `main`. It opens a "chore: release vX.Y.Z" PR aggregating unreleased
conventional-commit history; the PR is auto-merged by
`.github/workflows/auto-merge-release-please.yml` once required checks pass (or after a
~5-minute cap on the zero-checks case that arises because `validate.yml` has `paths:` filters
that release-please PRs do not match).

The auto-merge pattern is adapted from `macatocz/sagibeast`. Two makato-specific
constraints, both duplicated in the workflow header comment:

- **Single-branch**: makato has only `main` as an integration branch. NEVER add per-branch
  conditions to the auto-merge workflow — the label filter (`autorelease: pending`) is the
  only gate we need.
- **Split-token pattern preserved**: `GITHUB_TOKEN` reads check-runs; `RELEASE_PLEASE_PAT`
  performs the merge so downstream `release: published` events propagate. Do not consolidate
  to a single token — GitHub's anti-loop protection silently suppresses PAT-less merges.

The workflow's decision logic lives in `scripts/auto-merge-decide.sh` with fixture-based
smoke tests at `scripts/auto-merge-decide-smoke-tests.sh` so the classification
(merge / abort / wait / zero-checks-detected) has a unit-test surface separate from the
GitHub Actions runtime.

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
