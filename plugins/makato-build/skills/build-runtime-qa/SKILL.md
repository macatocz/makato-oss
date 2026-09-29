---
name: build-runtime-qa
description: >-
  Exercise the built app via Playwright MCP and score against acceptance
  criteria. Advisory: CRITICAL findings block build-push-to-git; MAJOR/ADVISORY
  findings are logged as warn and build proceeds. No-op when no runtime surface
  detected (no ## Runtime verification section and no health_check_cmd).
  Dispatched by the PO-agent after build-verify-spec succeeds and before
  build-push-to-git. Keywords: runtime-qa, playwright, acceptance-criteria,
  build-verify, runtime-verification, health-check.
version: "1.0.1"
argument-hint: "<work-item-key> [--autonomous]"
tools: Bash, Read, Agent
metadata:
  authors: ["makato-build"]
  last_updated: "2026-08-05"
---

<!-- markdownlint-disable MD013 -->

# build-runtime-qa

## Autonomous Mode

This skill is invoked by the PO-agent with `--autonomous`. All `AskUserQuestion`
gates are bypassed per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`. An empty `WORKTREE_PATH` in
autonomous mode is a `MISSING_INPUT` HALT.

## Decision Framework

Two non-obvious routing choices govern this skill:

1. **Parse failure vs runtime failure**: Agent output is non-deterministic — a
   truncated or malformed R1 block does not prove any AC failed. Route parse
   failures as advisory (`status: "warn"` to `build.jsonl`, return R1 `success`).
   Only a *successfully parsed* R1 with `status: "failure"` and `errors[]` entries
   prefixed `"CRITICAL: …"` triggers `RUNTIME_QA_BLOCKED`.

2. **Skip vs no-op**: When neither `## Runtime verification` nor `health_check_cmd`
   exists, this is correct behavior for non-service/non-UI builds — log SKIP and
   return R1 `success` with `data.skipped: true`. It is never an error.

## Input

| Field | Required | Description |
|-------|----------|-------------|
| `<work-item-key>` | yes | Positional argument (e.g. `123-add-feature`) |
| `WORKTREE_PATH` | yes (autonomous) | Absolute path to the per-run git worktree |
| `REPO_ROOT` | yes | Absolute path to the main checkout |
| `--autonomous` | flag | Activation flag for headless mode |

## Steps

### Step 0 — Workspace-isolation entry guard

Apply the workspace-isolation entry guard per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` §
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
Resolve `SPEC_FOLDER` as exact `$REPO_ROOT/specs/<key>` first; otherwise
accept exactly one `$REPO_ROOT/specs/<key>-*/` folder. Multiple prefix matches
without an exact folder are an error, not a skipped runtime surface. Read the
issue-specific plan from that resolved folder:

```bash
SPEC_FOLDER="$REPO_ROOT/specs/<key>"
if [[ ! -d "$SPEC_FOLDER" ]]; then
  SPEC_MATCHES=()
  for candidate in "$REPO_ROOT/specs/<key>"-*/; do
    [[ -d "$candidate" ]] && SPEC_MATCHES+=("${candidate%/}")
  done
  if ((${#SPEC_MATCHES[@]} > 1)); then
    echo "ambiguous spec folder for <key>" >&2
    exit 1
  elif ((${#SPEC_MATCHES[@]} == 1)); then
    SPEC_FOLDER="${SPEC_MATCHES[0]}"
  fi
fi
PLAN_PATH="$SPEC_FOLDER/plan-<ISSUE_NUMBER>.md"
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
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"ok","data":{"skipped":true,"reason":"no-runtime-surface"}}'
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
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"start","data":{"runtime_cmd":"<cmd>","ac_count":<N>}}'
```

### Step 3 — Dispatch `runtime-qa` agent

> **MANDATORY**: Load `references/severity-contract.md` before dispatching the
> agent. It defines the CRITICAL/MAJOR/ADVISORY rubric and shows the R1 envelope
> shapes you must parse in Step 4.
>
> Do NOT load this reference for other skills — it is specific to the
> runtime-qa contract.

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
See `references/severity-contract.md` for R1 envelope examples and the reasoning
behind each routing decision.

| R1 `status` | Action |
|-------------|--------|
| `"success"` with `data.skipped: true` | Log SKIP, return R1 `success`. |
| `"success"` (paths exercised, 0 CRITICAL) | Log findings as warn if any MAJOR/ADVISORY; return R1 `success`. |
| `"failure"` (CRITICAL findings) | Surface `errors[]` to caller; return R1 `failure` with `data.halt_code: "RUNTIME_QA_BLOCKED"`. |

On parse failure: log `status: "warn"` to `build.jsonl` (`step: "parse-failure"`),
return R1 `success` (advisory — a parse failure is not a CRITICAL finding; see
`references/severity-contract.md § Why parse failure is advisory`).

### Step 5 — Log session end and emit R1

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"session","status":"<ok|error>","data":{"skipped":<bool>,"paths_exercised":<N>,"findings_critical":<C>}}'
```

Also append the R1 envelope to `build.jsonl` per `agents/RETURN-CONTRACT.md §
Audit-log integration` (`step: "r1"`).

Emit the R1 envelope as the **last** fenced ` ```json ` block.

## Anti-patterns

**NEVER treat a parse failure as CRITICAL.**
A malformed or missing R1 block is a transport failure, not evidence that any AC
failed. Promoting parse failure to CRITICAL would silently block a clean build
whenever the model truncates its output — the operator would see a build stoppage
with no actionable runtime evidence. The only valid CRITICAL source is a
*successfully parsed* R1 with `status: "failure"` and `"CRITICAL: …"` entries in
`errors[]`.

**NEVER omit `WORKTREE_PATH` in autonomous mode.**
The worktree is per-run state created by the loop for isolation. Without it, the
skill runs against the main checkout, writes runtime state into the shared
workspace, and pollutes it for concurrent dispatches. `WORKTREE_PATH` absent in
autonomous mode is a `MISSING_INPUT` HALT — do not fall back to `git rev-parse
--show-toplevel` in that branch.

**NEVER forward `RUNTIME_CMD` containing multiple shell statements without stripping.**
The awk extractor pulls every non-fence line from the first code block after
`## Runtime verification`. If the plan author wrote a multi-command block (export +
start), blindly forwarding the full string causes the agent to mis-execute it as a
heredoc. Either extract only the executable command line or pass the full block as
a named script file.

**NEVER escalate RUNTIME_QA_BLOCKED as a planning problem.**
A CRITICAL runtime finding means the code is wrong, not the plan. Routing
`RUNTIME_QA_BLOCKED` to `/build-refine` produces a re-plan loop that never touches
the broken production code. The correct path is code repair (via `makato-change` or
inline fix) followed by a re-run of `build-verify` → `build-runtime-qa`.

## HALT Codes

| Code | Emitted by | Description |
|------|-----------|-------------|
| `MISSING_INPUT` | Step 0 | `WORKTREE_PATH` absent in autonomous mode. |
| `RUNTIME_QA_BLOCKED` | Step 4 | The `runtime-qa` agent found at least one CRITICAL finding. The build is blocked from push until the CRITICAL issue is resolved. Inspect `build.jsonl` `step:"runtime-qa-findings"` for the classified findings. |

`RUNTIME_QA_BLOCKED` route is `operator-escalation` — a CRITICAL runtime finding
is a runtime contract violation, not a planning problem; the fix is in the code,
not the plan. See `plugins/makato-build/halt-codes.md` for the full registry entry.
