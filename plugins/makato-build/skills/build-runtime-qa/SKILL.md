---
name: build-runtime-qa
description: >-
  Exercise the built app via Playwright MCP and score against acceptance
  criteria. Advisory: CRITICAL findings block build-push-to-git; all other
  findings are logged. No-op when no runtime surface detected.
version: "1.0.0"
tools: Bash, Read, Agent
---

<!-- markdownlint-disable MD013 -->

# build-runtime-qa

> **Mission**: After `build-verify` passes, dispatch the `runtime-qa` agent to
> launch the built application, drive critical user paths through Playwright MCP,
> and score each path against the plan's acceptance criteria. CRITICAL findings
> block `build-push-to-git`. All other findings are advisory and logged. When the
> build has no `## Runtime verification` section and no `health_check_cmd`, the
> skill exits cleanly as a no-op.

## When to Use

Dispatched by the PO-agent (Step 6 #1b) after `build-verify-spec` succeeds and
before `build-push-to-git`, when the plan includes a `## Runtime verification`
section or gate-scout discovered a `health_check_cmd`. Not dispatched for
non-service/non-UI builds.

## Autonomous Mode

This skill is invoked by the PO-agent with `--autonomous`. All `AskUserQuestion`
gates are bypassed per `@../../AUTONOMOUS-MODE.md`. An empty `WORKTREE_PATH` in
autonomous mode is a `MISSING_INPUT` HALT.

## Input

| Field | Required | Description |
|-------|----------|-------------|
| `<work-item-key>` | yes | Positional argument |
| `WORKTREE_PATH` | yes (autonomous) | Absolute path to the per-run git worktree |
| `REPO_ROOT` | yes | Absolute path to the main checkout |
| `--autonomous` | flag | Activation flag for headless mode |

## Steps

### Step 0 — Workspace-isolation entry guard

Apply the workspace-isolation entry guard per `@../../AUTONOMOUS-MODE.md` §
*WORKTREE_PATH — workspace-isolation contract*:

```bash
if [[ -n "${AGENT_ID:-}" ]] || [[ "${1:-}" == "--autonomous" ]] || [[ -n "${task_id:-}" ]]; then
  # Autonomous mode
  if [[ -z "${WORKTREE_PATH:-}" ]]; then
    # HALT: MISSING_INPUT
    exit 1
  fi
else
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
cd "$WORKTREE_PATH"
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

### Step 1 — Detect runtime surface

Resolve `ISSUE_NUMBER` from the numeric leading segment of `<work-item-key>`.
Read `$REPO_ROOT/specs/<key>-*/plan-<ISSUE_NUMBER>.md` and check for a
`## Runtime verification` section:

```bash
PLAN_PATH="$(ls "$REPO_ROOT/specs/<key>-*/plan-<ISSUE_NUMBER>.md" 2>/dev/null | head -1)"
RUNTIME_CMD=""
if grep -q "^## Runtime verification" "$PLAN_PATH" 2>/dev/null; then
  # Extract the command from the fenced code block following the heading
  RUNTIME_CMD="$(awk '/^## Runtime verification/{found=1} found && /^```/{if(++n==1){next}; if(n==2){exit}} found && n==1{print}' "$PLAN_PATH")"
fi
```

If `RUNTIME_CMD` is empty, also check `gate-scout`'s `health_check_cmd` field
from the most recent `build.jsonl` `step:"gate-scout"` entry.

If still empty — log SKIP and return `status: "success"` with `data.skipped: true`:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"ok","data":{"skipped":true,"reason":"no-runtime-surface"}}'
```

Log session end and return R1 immediately. **Do NOT proceed to Step 2.**

If `RUNTIME_CMD` is non-empty, continue.

### Step 2 — Build AC list from plan

Read the `## Acceptance criteria` section from `plan-<ISSUE_NUMBER>.md`:

```bash
AC_LIST="$(awk '/^## Acceptance criteria/{found=1; next} found && /^## /{exit} found && /^-/{print}' "$PLAN_PATH" | jq -Rsc 'split("\n") | map(select(. != ""))')"
```

Log session start:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"start","data":{"runtime_cmd":"<cmd>","ac_count":<N>}}'
```

### Step 3 — Dispatch `runtime-qa` agent

Dispatch the `runtime-qa` agent (from `plugins/makato-build/agents/runtime-qa.md`)
with the following bundle:

| Field | Value |
|-------|-------|
| `PLAN_PATH` | `$REPO_ROOT/specs/<key>-*/plan-<ISSUE_NUMBER>.md` |
| `RUNTIME_CMD` | discovered in Step 1 |
| `AC_LIST` | JSON array from Step 2 |
| `WORKTREE_PATH` | `$WORKTREE_PATH` |
| `REPO_ROOT` | `$REPO_ROOT` |
| `SPEC_KEY` | `<work-item-key>` |

### Step 4 — Parse R1 and route

Parse the last fenced ` ```json ` block from the agent's output as the R1 envelope.

| R1 `status` | Action |
|-------------|--------|
| `"success"` with `data.skipped: true` | Log SKIP, return R1 `success`. |
| `"success"` (paths exercised, 0 CRITICAL) | Log findings as warn if any MAJOR/ADVISORY; return R1 `success`. |
| `"failure"` (CRITICAL findings) | Surface `errors[]` to caller; return R1 `failure` with `data.halt_code: "RUNTIME_QA_BLOCKED"`. |

On parse failure: log `status: "warn"` to `build.jsonl` (`step: "parse-failure"`),
return R1 `success` (advisory — a parse failure is not a CRITICAL finding).

### Step 5 — Log session end and emit R1

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"<ok|error>","data":{"skipped":<bool>,"paths_exercised":<N>,"findings_critical":<C>}}'
```

Emit the R1 envelope as the **last** fenced ` ```json ` block.

## HALT Codes

| Code | Emitted by | Description |
|------|-----------|-------------|
| `MISSING_INPUT` | Step 0 | `WORKTREE_PATH` absent in autonomous mode. |
| `RUNTIME_QA_BLOCKED` | Step 4 | The `runtime-qa` agent found at least one CRITICAL finding. The build is blocked from push until the CRITICAL issue is resolved. Inspect `build.jsonl` `step:"runtime-qa-findings"` for the classified findings. |

`RUNTIME_QA_BLOCKED` route is `operator-escalation` — a CRITICAL runtime finding
is a runtime contract violation, not a planning problem; the fix is in the code,
not the plan. See `plugins/makato-build/halt-codes.md` for the full registry entry.
