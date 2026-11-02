# Plan — shared agent model roles for OMP + Claude Code, merge-safe installer

## Problem
- `modelRole:` in agent frontmatter is read by neither harness → remove it.
- `scripts/select-model-profile.sh` overwrites `~/.omp/agent/config.yml` (line 108) and `models.yml` (91-107) wholesale → deletes custom roles/overrides.
- Agents need a role that works in both harnesses; po-agent needs a dedicated strongest-model role.

## How each harness gets the model
| Harness | Mechanism | Source |
|---|---|---|
| OMP | `task.agentModelOverrides[<agent>] = "@<role>"` → expanded via `modelRoles` (editable in `/model` → Roles) | merged by installer from `config/agent-roles.yml` |
| Claude Code | frontmatter `model:` alias | derived from role via `claude_aliases` |

OMP ignores frontmatter `model` for Claude-dialect plugins, so both coexist.

## Roles (shared; grouped by phase/inputs → same model → prompt-cache reuse)
| Role | Claude alias | Agents |
|---|---|---|
| orchestrator (dedicated) | fable | po-agent |
| task | inherit | coder, sensor-fixer, runtime-qa (was default), change-implementer |
| advisor | opus | diff-reviewer, code-reviewer, requirements-diff-analyzer, dev-reviewer, po-reviewer, qa-reviewer |
| smol | haiku | gate-scout, knowledge-scout, plan-analyst, code-explorer, test-analyzer, quality-guard, task-file-scout (was tiny), context-summariser (was tiny), context-scout (was tiny) |
| commit | sonnet | gherkin-scenario-elaborator (new), documentation-agent, acceptance-writer, doc-writer |
| plan | opus | light-planner |
| designer | opus | prototype-builder |

## Changes
1. **Agents (26 files)**: replace `modelRole: x` in place with `model: <alias>`; gherkin-scenario-elaborator inserts `model: sonnet` after `name:`. Minor-bump existing `version:` only: coder 1.3.0, sensor-fixer 1.1.0, diff-reviewer 1.4.0, gate-scout 1.7.0, change-implementer 1.1.0, quality-guard 1.3.0, po-agent 1.4.0, documentation-agent 1.2.0. Skip `makato-build/agents/RETURN-CONTRACT.md`.
2. **`config/agent-roles.yml`** (new, nested mappings only so `_parse_nested_yaml` reads it): `claude_aliases: {role: alias}`, `agents: {agent: role}`.
3. **Canonical role `orchestrator`** added everywhere the role list lives: `EXPECTED_ROLES` in `scripts/resolve-model-profile.py`, `scripts/preflight-omp-context.sh`, `tests/test_model_roles_config.py`, `tests/test_model_profiles.py`; `config/model-profiles.yml` (openai `o1`, qwen-vllm `open`, apple-ollama `llama3.1`; fix "ten canonical" comment); `infra/omp-config.yml` (`orchestrator: local/open` + `task.agentModelOverrides`); `.github/workflows/validate.yml` fixture; `tests/infra/test_macos_remote_profiles.sh` fixture; `plugins/makato-orchestrate/config/config.yml` models block + comments (111-112, 123-126, 157); `config/config.md` 185, 196-198.
4. **Resolver**: load/validate agent-roles (every agent → known role; every role has alias); new `--emit omp-agent-overrides`; new `merge` helper (PyYAML `safe_dump(sort_keys=False)`) that updates only canonical `modelRoles` keys, `tools.format`, and makato keys in `task.agentModelOverrides`; `providers.<profile>` only in `models.yml`. Everything else preserved.
5. **Installer** `select-model-profile.sh`: replace overwrites with the merge; add `--agents-only` (merge overrides only, no profile roles/providers, no credential check); `--dry-run` prints merged result; update usage/arg parsing.
6. **Preflight**: scope role and `tools.format` checks (208, 214-232) to their YAML blocks.
7. **Tests**: rewrite `test_no_closed_model_in_agent_frontmatter` → agent `model:` must equal alias of its role in agent-roles.yml, every agent listed; keep "SKILL.md has no model:" check; update `test_phase0_spike_artefacts.py::test_q5_count_matches_grep_audit` (0 modelRole, 26 model); add merge test (custom role/override/unrelated key survive install and `--agents-only`).
8. **Docs/CHANGELOGs**: frontmatter-spec.md (drop modelRole row 15 + template line 30, add "skills must not set model:"), workflow-schema-field-reference.md 62-64, docs/workflow-schema.md, README.md 135-148, docs/macos-openai-qwen.md, docs/vast-ai-llm-deployment.md; `### Changed — route subagents through shared model roles` under `[Unreleased]` in build/change/orchestrate/plan/contribute/core CHANGELOGs.
9. **Env**: `uv sync --group dev --python 3.14` (.venv broken by 3.15a7 from `.python-version`; AGENTS.md says 3.14 — flag to user).
10. **Verify**: pytest, pyright on changed .py, ruff, shellcheck, check-plugin-structure per plugin, infra shell tests, installer smoke on temp `OMP_CONFIG_FILE`/`OMP_MODELS_FILE` with custom keys (`--dry-run`, `--agents-only`).
11. **User OMP config via `cfg://` (approval)**: `modelRoles` rename REVIEW/VERIFY → review/verify, add `orchestrator: anthropic/claude-fable-5:high`, `designer: anthropic/claude-opus-5-5:medium`, keep judge; `task.agentModelOverrides` = 26 `@role` entries; ask to save.

## Notes for the user
- Skill role ≠ agent role: skills take the model from workflow-schema `skill_execution.role` (`--model @role`); SKILL.md has no model field.
- `fable` under Claude Code may bill usage credits (no prompt in `-p`).
- Change models in `/model` → Roles only; saving in `/agents` replaces `@role` with a concrete model.
- Bare-name overrides also hit same-named agents from other plugins (impacto `coder`, `code-reviewer`, `diff-reviewer`).
