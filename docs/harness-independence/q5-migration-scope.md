# Skill Migration Scope — Q5

**Date**: 2026-08-11
**Issue**: #3 (Phase-0 spike)
**Question**: How many of the ~25 agent files need harness-specific change beyond a modelRole substitution?

## Summary

**Total files requiring `modelRole` substitution**: 39
- 25 agent `.md` files (`plugins/*/agents/`) — mechanical `model:` tier → `modelRole:` substitution
- 13 SKILL.md files — carry `model:` in their frontmatter; need the same mechanical substitution
- 1 references doc (`makato-skill-creator/references/frontmatter-spec.md`) — template for new skills; update the example `model:` line

**Total files requiring targeted harness-specific rewrite beyond substitution**: 5 shell scripts

**Grand total files requiring any change for S1 harness swap**: 44

## Agent Frontmatter Files (25 files — modelRole substitution only)

All 25 agent `.md` files under `plugins/*/agents/` carry a `model:` field in their YAML frontmatter
referencing Claude-specific tiers (`opus`, `sonnet`, `haiku`, or a pinned version string).
These must be replaced with `modelRole: <tier>` values that map to configurable endpoints in
`plugins/makato-orchestrate/config/config.yml`.

Note: `plugins/makato-build/agents/RETURN-CONTRACT.md` is a contract document in the `agents/`
directory but carries no `model:` frontmatter — it is excluded from this count.

Proposed tier mapping (per D4, D15):

| Current `model:` value | New `modelRole:` value | Default endpoint |
|------------------------|------------------------|------------------|
| `opus` | `high` | ThinkingCap-Qwen3-72B (open) |
| `sonnet` | `mid` | Qwen3-30B-A3B (open) |
| `haiku` | `fast` | Qwen3-8B (open) |
| pinned version string (e.g. `claude-haiku-4-5-20251001`, `claude-sonnet-latest[1m]`) | mapped to tier by capability | Operator-configured |
| *(unset / default)* | `mid` | Qwen3-30B-A3B (open) |

The judge role (D12) uses `closed` → closed-model endpoint (Claude/GPT/other, operator-configured).

**Files** (all in `plugins/*/agents/`):

### makato-plan (7 files)
- `agents/po-reviewer.md` — `sonnet`
- `agents/prototype-builder.md` — `opus`
- `agents/doc-writer.md` — `sonnet`
- `agents/dev-reviewer.md` — `sonnet`
- `agents/context-scout.md` — `haiku`
- `agents/acceptance-writer.md` — `sonnet`
- `agents/qa-reviewer.md` — `sonnet`

### makato-orchestrate (5 files)
- `agents/light-planner.md` — `sonnet`
- `agents/task-file-scout.md` — `haiku`
- `agents/documentation-agent.md` — `sonnet`
- `agents/context-summariser.md` — `haiku`
- `agents/po-agent.md` — `sonnet`

### makato-change (6 files)
- `agents/code-reviewer.md` — `sonnet`
- `agents/code-explorer.md` — `haiku`
- `agents/change-implementer.md` — `sonnet`
- `agents/test-analyzer.md` — `haiku`
- `agents/requirements-diff-analyzer.md` — `sonnet`
- `agents/quality-guard.md` — `haiku`

### makato-build (7 files)
- `agents/sensor-fixer.md` — `claude-sonnet-latest[1m]` (pinned)
- `agents/runtime-qa.md` — `claude-haiku-4-5-20251001` (pinned)
- `agents/diff-reviewer.md` — `sonnet`
- `agents/knowledge-scout.md` — `haiku`
- `agents/plan-analyst.md` — `haiku`
- `agents/coder.md` — `sonnet`
- `agents/gate-scout.md` — `haiku`

## SKILL.md Files (13 files — modelRole substitution only)

SKILL.md files also carry `model:` frontmatter that selects the executing Claude tier for skill
invocations. These require the same mechanical substitution.

### makato-plan (8 files)
- `skills/brainstorming/SKILL.md` — `opus`
- `skills/create-acceptance-tests/SKILL.md` — `sonnet`
- `skills/create-architecture/SKILL.md` — `opus`
- `skills/create-prd/SKILL.md` — `opus`
- `skills/create-prototype/SKILL.md` — `opus`
- `skills/create-ux/SKILL.md` — `opus`
- `skills/decompose/SKILL.md` — `opus`
- `skills/stress-test-artifact/SKILL.md` — `opus`

### makato-build (5 files)
- `skills/build-grill-with-docs/SKILL.md` — `opus`
- `skills/build-implement-goal/SKILL.md` — `opus`
- `skills/build-implement-tdd/SKILL.md` — `sonnet`
- `skills/build-refine/SKILL.md` — `opus`
- `skills/build-review/SKILL.md` — `opus`

## References File (1 file — template update)

- `plugins/makato-contribute/skills/makato-skill-creator/references/frontmatter-spec.md` — carries
  `model: opus` as the template example for new skills; update to `modelRole: high` to avoid
  perpetuating the Claude-specific tier in newly authored skills.

## Shell Scripts Requiring Targeted Rewrite (5 files)

These files contain `claude -p` or `claude --dangerously-skip-permissions` invocations that are Claude Code-specific and must be replaced with omp equivalents.

### 1. `plugins/makato-orchestrate/scripts/functions.sh`
**Change**: Replace `claude -p [args]` dispatch calls with `omp --yolo -p [args]`.
**Scope**: Core dispatch seam S1. This is the primary entry point for all autonomous skill invocations.

### 2. `plugins/makato-orchestrate/scripts/loop.sh` (referenced via `functions.sh`)
**Change**: `_cmd_dispatch` function — replace `claude --dangerously-skip-permissions -p` with `omp --yolo -p`. Export `MAKATO_HEADLESS=1` is preserved (harness-agnostic).
**Scope**: Core dispatch seam S1.

### 3. `plugins/makato-orchestrate/scripts/context-handoff.sh`
**Change**: `_emit_resume` — replace `claude --dangerously-skip-permissions -p --resume "$SESSION_ID"` with `omp --yolo -p --resume "$SESSION_ID"`. Session-id extraction from terminal NDJSON event (see D16 artefact).
**Scope**: Resume seam (HALT-007B path).

### 4. `plugins/makato-build/shared/headless-guard-smoke-tests.sh`
**Change**: Update test expectations from CC headless invocation patterns to omp equivalents. No logic change — test scaffolding update only.
**Scope**: Test harness update, not production path.

### 5. `plugins/makato-build/shared/plan-only-tier-smoke-tests.sh`
**Change**: Update CC-specific reference patterns in smoke test assertions.
**Scope**: Test harness update, not production path.

## Out of Scope (unchanged)

- All plugin AGENTS.md files — no harness-specific content
- SKILL.md `AskUserQuestion` bypass logic — covered by `AUTONOMOUS-MODE.md` (harness-agnostic)
- All `shared/*.sh` scripts (workflow-state, worktree, progress-comment, etc.) — use `gh` CLI exclusively, not Claude Code APIs
- All `scripts/*.sh` except the 3 listed above — no CC-specific invocations
- All Python scripts — harness-agnostic

## Conclusion

The migration scope is bounded and well-understood. The dominant effort (25 agent files + 13 SKILL.md
files) is a mechanical `model:` → `modelRole:` substitution. The 5 shell scripts require targeted
surgical rewrites of exactly 3 production dispatch sites. No plugin logic, orchestration rules, or
AGENTS.md content requires change. This confirms the Sequence 1 (S1) estimate is accurate and the
scope does not warrant triggering the Hermes fallback (D2).

**Verification method**: `grep -r "^model:" plugins/ --include="*.md"` returns 39 lines across
25 agent files, 13 SKILL.md files, and 1 references file — all requiring the same mechanical
substitution. Rerun this command to confirm the count is exhaustive.
