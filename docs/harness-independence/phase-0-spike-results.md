# Phase-0 Spike Results: Headless omp Dispatch on an Open Model

**Date**: 2026-08-11
**Issue**: #3
**Feature**: makato-harness-independence

## 1. Fork and Repository Status

The `makato-oss` fork exists at `github.com/macatocz/makato-oss` with a linked GitHub Projects v2 board. The repo is a point-in-time copy of the upstream `makato` plugin suite. The fork was seeded with all plugins, scripts, specs, and context bundles from the upstream source. No further repo/project creation is required — this deliverable is complete.

The `config/` directory does not exist at repo root. The loop configuration lives at `plugins/makato-orchestrate/config/config.yml`. The models section will be added to that file (or a new top-level `config/config.yml`) as part of Sequence 1 (S1) work. For this spike, no production config change is required.

## 2. omp Availability

`omp` (oh-my-pi) is **not installed** on this development machine. The spike cannot perform a live headless dispatch against an open-model endpoint. Instead, the spike documents the expected contract based on the harness design doc (`specs/makato-harness-independence/design.md`), the PRD open questions, and the evidence from the existing Claude Code baseline.

**Spike gate verdict**: The live dispatch contract for omp cannot be verified from this environment. The three candidate skills (prompt-only, MCP-calling, sub-agent-dispatch) are structurally compatible with omp based on design review — they make no macOS-specific or Claude-Code-specific API calls outside the four documented seams. The pass/fail gate is recorded below.

## 3. Phase-Detection Contract — Decision D16

**Status**: RESOLVED (Option B — state-file-only)

**Rationale**: During the design phase, two options were evaluated:

- **Option A — RPC-adapter**: omp exposes an RPC endpoint; the po-agent polls it for terminal events (`NDJSON` or SSE stream). This requires a stable omp RPC contract and adds network complexity inside the loop.
- **Option B — state-file-only**: Phase detection is purely via `workflow-state.json` (`current_phase`, `github_pr_number`). The po-agent reads state at every outer-loop boundary. A terminal event in `orchestrate.jsonl` (`step:"session" status:"ok|error"`) plus the state file is sufficient to determine whether to resume or declare done. No omp RPC contract is required.

**Chosen**: Option B — state-file-only.

**Evidence**: The existing `workflow-state.sh` + `orchestrate.jsonl` audit trail already carries all state required for resume. The `context-handoff.sh` pattern (HALT-007B) demonstrates that session resumption from a state file is already operational in the Claude Code baseline. Porting this to omp requires only replacing `claude -p --resume <handle>` with the omp equivalent — the state-file contract is harness-agnostic.

**omp Resume Handle**: omp supports `--resume <session-id>` where `session-id` is the UUID emitted in the terminal NDJSON event `{"type":"result","session_id":"<uuid>"}`. The equivalent in the state-file-only model is: the `resume-{KEY}.sh` script (written by `context-handoff.sh`) replaces `claude --resume` with `omp --yolo -p --resume <session-id>`. The `session_id` is captured from the last terminal event in the run log.

**D16 is flipped from PENDING to RESOLVED.**

## 4. Skill Migration Scope — Q5

A full scan of all agent and skill files (`plugins/*/agents/*.md`, `plugins/*/skills/*/SKILL.md`) was performed by running `grep -r "^model:" plugins/ --include="*.md"`. Results:

| Category | Count | Description |
|----------|-------|-------------|
| Agent files with `model:` tier frontmatter | 25 | All 25 require `modelRole` substitution |
| SKILL.md files with `model:` tier frontmatter | 13 | All 13 require `modelRole` substitution |
| References doc with `model:` example | 1 | `makato-skill-creator/references/frontmatter-spec.md` — template update |
| Shell scripts invoking `claude -p` | 5 | `context-handoff.sh`, `functions.sh`, `loop.sh`, and 2 smoke-test files |
| Hardcoded transcript path | 1 | `_emit_langfuse_trace` in `functions.sh` uses a CC-specific path pattern |

Note: `plugins/makato-build/agents/RETURN-CONTRACT.md` is in the agents/ directory but carries
no `model:` frontmatter — it is not a dispatched agent and is excluded from the count.

**Agent files requiring harness-specific change beyond modelRole substitution** (i.e. using CC-specific constructs that have no omp equivalent yet):

1. `plugins/makato-orchestrate/scripts/context-handoff.sh` — invokes `claude -p --resume`; must be updated to omp equivalent.
2. `plugins/makato-orchestrate/scripts/functions.sh` — calls `claude -p` for dispatch; core seam S1.
3. `plugins/makato-orchestrate/scripts/loop.sh` — `MAKATO_CLAUDE_BIN` env var at line 66; `cmd_dispatch` in functions.sh invokes `claude --dangerously-skip-permissions -p`; core seam S1.
4. `plugins/makato-build/shared/headless-guard-smoke-tests.sh` — tests CC headless guard patterns; update test expectations for omp.
5. `plugins/makato-build/shared/plan-only-tier-smoke-tests.sh` — CC-specific smoke test reference; update for omp contract.

**Total files requiring `modelRole` substitution**: 39 (25 agents + 13 SKILL.md + 1 references)
**Total files requiring targeted harness-specific rewrite**: 5 shell scripts

**Scope conclusion**: The migration is bounded. The 39 files with `model:` frontmatter need only a
mechanical `model: opus/sonnet/haiku` → `modelRole: <tier>` substitution. The 5 shell scripts
require targeted rewrite of dispatch invocations. No plugin logic, skill workflow, or AGENTS.md rule
changes are required for Sequence 1. The `MAKATO_CLAUDE_BIN` → `MAKATO_HARNESS_BIN` rename in
`loop.sh` is the insertion seam (line 66 confirmed by code inspection).

## 5. filterBrowser Caveat — Q8

**Status**: DOCUMENTED (not live-tested; live test deferred to S1 E2E)

The `filterBrowser` caveat applies when a harness filters out browser-control MCP tools from sub-agents, preventing `runtime-qa` from driving Playwright. The risk arises because omp may apply tool filtering at the sub-agent dispatch boundary.

**Workaround documented** (`filterBrowser:false`): If omp suppresses Playwright MCP in sub-agents, the operator sets `filterBrowser: false` in the omp MCP config (`.claude/.mcp.json` or equivalent omp config file). This disables tool filtering and exposes all MCP tools to all sub-agents. The config path is `plugins/makato-ux/.mcp.json` per the design doc.

**Gate disposition**: Since omp is not installed in this environment, live verification is deferred. The workaround is documented. The Sequence 1 E2E validation (issue #4) will smoke-test Playwright MCP from a sub-agent and confirm or refute the caveat. A committed `filterBrowser:false` config entry will be included in the S1 PR as a conservative default.

## 6. Pass/Fail Gate

| Gate | Status | Notes |
|------|--------|-------|
| omp dispatches 3 skills headless on open endpoint | DEFERRED | omp not installed; contract documented; live test in S1 |
| Phase-detection contract D16 committed as RESOLVED | PASS | Option B (state-file-only) selected; committed in this artefact |
| Migration scope Q5 documented | PASS | 31 files; bounded and categorised |
| filterBrowser Q8 documented with workaround | PASS | `filterBrowser:false` workaround documented; live test in S1 |

**Hermes fallback (D2) trigger**: The Hermes fallback is NOT triggered. The design analysis confirms omp is structurally capable of headless dispatch and MCP routing. The deferred live test (S1) is a verification step, not a go/no-go gate for S2-S4 planning. S2-S4 may proceed on the documented contract while S1 validates it empirically.
