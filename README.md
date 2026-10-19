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
- **Python 3.15+** — only if you plan to run the repo's smoke tests or contribute to plugins that
  ship pytest fixtures (`makato-build`, `makato-sagibeast`). Pinned in `pyproject.toml`
  (`requires-python = ">=3.15"`) and in the audit CI workflows.
- **A selected model profile** — every agent role routes through one of three provider profiles
  declared in [`config/model-profiles.yml`](config/model-profiles.yml): `qwen-vllm` (local or
  remote OpenAI-compatible vLLM — the checked-in default, no credential), `openai` (native
  `api.openai.com`, requires `OPENAI_API_KEY`), or `apple-ollama` (Apple Silicon local
  OpenAI-compatible Ollama, no credential). See [Provider switching](#provider-switching) below.
  Apple Silicon (macOS/arm64) clients should also run `scripts/macos-setup.sh` — see
  [`docs/macos-openai-qwen.md`](docs/macos-openai-qwen.md) for the full quick-start.

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

`omp` routes every agent role through whichever model profile is currently installed
(configured by `~/.omp/agent/config.yml` and `~/.omp/agent/models.yml` — see
[Provider switching](#provider-switching) below; no AWS Bedrock token required):

```bash
MAKATO_HEADLESS=1 omp --yolo -p "/makato-build:build-start"
```

On a local machine without OMP installed, use `claude` directly:

```bash
MAKATO_HEADLESS=1 claude --dangerously-skip-permissions -p "/makato-build:build-start"
```

`MAKATO_HEADLESS=1` is mandatory for every non-interactive invocation — omitting it causes
`MISSING_INPUT: headless-without-autonomous`.

## Provider switching

makato's autonomous roles route through one of three provider profiles declared in
[`config/model-profiles.yml`](config/model-profiles.yml):

| Profile | Endpoint | Credential | Tool format |
| --- | --- | --- | --- |
| `qwen-vllm` (default) | Local or remote OpenAI-compatible vLLM (`http://localhost:8100/v1`; override via `MAKATO_OPEN_ENDPOINT_URL`/`VLLM_API_BASE`) | none | `qwen3` |
| `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `openai` |
| `apple-ollama` | Local Apple Silicon `ollama serve` (`http://localhost:11434/v1`) | none | `openai` |

Preview a profile — structural validation only, never touches disk, never requires a
credential. `--dry-run` prints only the fragments that would be merged, never the contents
of your existing files:

```bash
python3 scripts/resolve-model-profile.py openai --emit summary
bash scripts/select-model-profile.sh openai --dry-run
bash scripts/select-model-profile.sh qwen-vllm --dry-run
bash scripts/select-model-profile.sh apple-ollama --dry-run
```

Install a profile for real — merges into `~/.omp/agent/config.yml` and
`~/.omp/agent/models.yml` instead of overwriting them. In `config.yml` only the canonical
`modelRoles` keys, `tools.format` and the makato agent keys under `task.agentModelOverrides`
change; in `models.yml` it updates only the profile's own provider entry (`baseUrl`, `apiKey`,
`models`). Custom roles (e.g. `review`), other agents' overrides, other keys in that provider
entry, other providers and unrelated settings are preserved. Both files are validated before
either is written. Merging into an existing file needs PyYAML (`python3 -m pip install
pyyaml`, or point `MAKATO_PYTHON_BIN` at a Python that has it); YAML comments in a merged
file are not preserved. `OPENAI_API_KEY` is required only here, only for `openai`, is written
only into `models.yml` (mode `600`), and its value is never echoed to stdout/stderr/logs:

```bash
OPENAI_API_KEY=sk-... bash scripts/select-model-profile.sh openai
bash scripts/select-model-profile.sh qwen-vllm       # no credential needed
bash scripts/select-model-profile.sh apple-ollama    # no credential needed
```

If you pick models yourself in OMP `/model` → Roles, route makato's agents through those
roles without installing a profile. `--agents-only` merges only the agent → `"@<role>"`
overrides into `config.yml`, leaves `modelRoles`, `tools` and `models.yml` untouched, and
needs no credential:

```bash
bash scripts/select-model-profile.sh --agents-only --dry-run   # preview the overrides
bash scripts/select-model-profile.sh --agents-only
```

Before dispatching the PO-agent, run the mandatory Gate 6 runtime preflight for the active
profile — endpoint reachability, credential presence, and OMP role/tool-format match; never
prints a credential value:

```bash
MAKATO_MODEL_PROFILE=openai bash scripts/preflight-model-runtime.sh
MAKATO_MODEL_PROFILE=qwen-vllm bash scripts/preflight-model-runtime.sh
MAKATO_MODEL_PROFILE=apple-ollama bash scripts/preflight-model-runtime.sh
```

`MAKATO_SKIP_OPTIONAL_PREFLIGHT=1` skips the advisory Playwright MCP / Langfuse / Postgres /
Temporal / Sagibeast checks (`scripts/preflight-optional-services.sh`) that otherwise run
alongside Gate 6 for visibility only — a missing or unreachable optional service is always
reported as `SKIP`/`WARN`, never as silently healthy, and never blocks Gate 6.

On Apple Silicon, `scripts/macos-setup.sh` reports (or, with `--install`, installs) every
client-side tool a profile needs — Homebrew Bash ≥5, Python 3.15, Node.js, `gh`, `jq`, OMP,
Docker Desktop — then checks/installs the selected profile. It never installs CUDA/vLLM:

```bash
bash scripts/macos-setup.sh --dry-run --profile qwen-vllm
bash scripts/macos-setup.sh --install --profile openai
```

See [`docs/macos-openai-qwen.md`](docs/macos-openai-qwen.md) for the full Mac quick-start,
optional-service setup, and a troubleshooting matrix.

### Agent model roles

Every makato subagent runs on one shared model role declared in
[`config/agent-roles.yml`](config/agent-roles.yml). Agents of the same pipeline phase share a
role, so the model — and its prompt cache — does not switch between them. `po-agent` alone
has the dedicated `orchestrator` role so the outer loop gets the strongest model.

| Role | Claude Code `model:` | Agents |
| --- | --- | --- |
| `orchestrator` | `fable` | po-agent |
| `task` | `inherit` | coder, sensor-fixer, runtime-qa, change-implementer |
| `advisor` | `opus` | diff-reviewer, code-reviewer, requirements-diff-analyzer, dev-reviewer, po-reviewer, qa-reviewer |
| `smol` | `haiku` | gate-scout, knowledge-scout, plan-analyst, code-explorer, test-analyzer, quality-guard, task-file-scout, context-summariser, context-scout |
| `commit` | `sonnet` | gherkin-scenario-elaborator, documentation-agent, acceptance-writer, doc-writer |
| `plan` | `opus` | light-planner |
| `designer` | `opus` | prototype-builder |

- **OMP** reads `task.agentModelOverrides: {<agent>: "@<role>"}` in `~/.omp/agent/config.yml`,
  merged by `scripts/select-model-profile.sh`; the concrete model for each role lives only in
  OMP `modelRoles`.
- **Claude Code** reads the agent's frontmatter `model:` alias, which
  `tests/test_model_roles_config.py` keeps in sync with the role's alias.

Change models in OMP `/model` → Roles, not in `/agents`: saving an agent's model there
replaces its `@role` alias with a fixed model. Skills are separate — a skill's model comes
from workflow-schema `skill_execution.role` (see
[`docs/workflow-schema.md`](docs/workflow-schema.md)); SKILL.md never sets `model:`.

## Support boundaries

- **Mac (Apple Silicon) client** — orchestrates the autonomous loop and runs OMP/Claude Code
  locally. It can route inference through the local `apple-ollama` profile (Apple
  Silicon-native, OpenAI-compatible, no credential), the native `openai` profile
  (`api.openai.com`), or a remote `qwen-vllm` endpoint served on Linux. It never runs
  CUDA/vLLM itself — `scripts/macos-setup.sh` refuses to install it.
- **Remote Linux/NVIDIA** — serves the `qwen-vllm` profile via `infra/bootstrap-vllm.sh` +
  `infra/vllm-serve.sh` (both refuse to run on Darwin). See
  [`docs/vast-ai-llm-deployment.md`](docs/vast-ai-llm-deployment.md) for the full runbook.
- **Optional services** (Playwright MCP, Langfuse, Postgres, Temporal, Sagibeast/testbox) are
  never required for the core loop. `scripts/preflight-optional-services.sh` reports each as
  an explicit `PASS`/`SKIP`/`WARN` and never blocks dispatch.

## Autonomous loop

The `makato-orchestrate:loop` skill polls a GitHub Projects v2 board for `Status=Ready` issues and
drives each one to a merged PR unattended.

### Loop prerequisites

```bash
# One-time setup: initialise board sync (populates .claude/config.json → github_project)
/makato-plan:issue-to-project --init
```

### Start the loop

The loop dispatches each issue through
[`plugins/makato-orchestrate/scripts/harness-command.sh`](plugins/makato-orchestrate/scripts/harness-command.sh),
the shared harness-neutral command adapter. It resolves the permission flag from the
**explicit** `MAKATO_HARNESS_MODE` switch — never inferred from `MAKATO_HARNESS_BIN`'s name:
`omp` (default) → `--yolo`; `claude` → `--dangerously-skip-permissions`. `MAKATO_HARNESS_BIN`
only names the binary to exec; `MAKATO_MODEL_PROFILE` (see
[Provider switching](#provider-switching)) selects the provider profile. Neither variable
ever carries a credential.

On a provisioned vast.ai box (or any host with `omp` on `PATH`):

```bash
MAKATO_HARNESS_BIN="/root/.local/bin/omp" \
  nohup /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run --status Ready \
  > ~/.claude/state/loop.log 2>&1 &
disown
```

On a local machine where Claude Code is the harness, opt in explicitly with
`MAKATO_HARNESS_MODE=claude` — no separate shim binary is needed:

```bash
MAKATO_HARNESS_BIN="claude" MAKATO_HARNESS_MODE=claude \
  nohup plugins/makato-orchestrate/scripts/loop.sh run --status Ready \
  > ~/.claude/state/loop.log 2>&1 &
disown
```

The `nohup`+`disown` detaches the loop so a background-session reap does not kill it mid-dispatch.

A crashed or context-ceiling dispatch resumes the same session via its captured
`last_session_id` and `--resume <session_id>` — both supported harnesses accept the same
`--resume <session_id> -p <prompt>` shape, so there is no Claude-only resume fallback. See
[`plugins/makato-orchestrate/README.md`](plugins/makato-orchestrate/README.md) for the full
harness/profile/resume contract.

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
MAKATO_HARNESS_BIN="omp" \
  plugins/makato-orchestrate/scripts/loop.sh run --dry-run --once

# Dispatch exactly one Ready issue and exit
MAKATO_HARNESS_BIN="omp" \
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

| Plugin                                                   | Purpose                                                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
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

Install the declared development dependencies and run from the repo root:

```bash
uv sync
uv run pytest
pre-commit run pyright --hook-stage manual --all-files
```

Pyright resolves dependencies from `.venv` and the launcher's shared-module import
directory. Keep `.venv` synchronized before running repository-wide gates.

The harness discovers tests in three locations declared in `pyproject.toml` →
`[tool.pytest.ini_options].testpaths`:

- `tests/` — repo-level smoke tests (e.g. `test_smoke_build_simplify.py`)
- `plugins/makato-build/shared/` — context-bundle resolver unit tests
- `plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/` — curation tests

Adding a test runner to plugins that don't already have one is explicitly out of scope — the
harness only covers existing pytest-collectable code.

## License

makato is released under the [MIT License](LICENSE).
