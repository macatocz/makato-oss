<!-- markdownlint-disable MD013 MD032 MD040 -->
# Autonomous Mode — makato-change approval-gate bypass convention

> **Status**: Authoritative for all `makato-change` skills. When a skill takes a runtime decision via `AskUserQuestion`, autonomous mode replaces that decision with the documented default. Interactive runs are unaffected.

## Why this exists

Every `makato-change` skill that transitions between workflow phases calls `AskUserQuestion` for approval, confirmation, or clarification. This is intentional for interactive use — but it structurally prevents headless operation by a PO-agent or an automated loop. The `loop` skill in `makato-orchestrate` (GAP-007 / #33) polls a GitHub Projects v2 board for items tagged as ready and dispatches against each; for that to work against change-request issues, every gate that today waits on a human must take a deterministic, documented default in autonomous mode.

This document follows the same shape as `plugins/makato-build/AUTONOMOUS-MODE.md` — same activation triggers, same `MAKATO_HEADLESS` defensive guard, same logging contract — applied to the makato-change skill set.

## Activation triggers

A `makato-change` skill runs in **autonomous mode** when ANY of the following holds:

1. `--autonomous` is passed on the CLI (e.g. `/makato-change:orchestrate PROJ-1234 --autonomous`).
2. The caller provides a context bundle whose payload includes a `task_id` field.
3. The `$AGENT_ID` environment variable is exported (set by makato agent dispatch infrastructure).

If none of those hold the skill runs in **interactive mode**, exactly as it did before this convention existed.

**Precedence:** the three triggers are OR-equivalent. Once any one is true the skill is autonomous; further checks are unnecessary.

## Defensive-headless guard (`MAKATO_HEADLESS`)

`MAKATO_HEADLESS=1` is **not a fourth autonomous trigger** — it is the opposite. It is a caller-side assertion of "no human is at the prompt" that lets a skill refuse to hang when the caller has forgotten to set any of the three autonomous triggers above. Semantics mirror `makato-build/AUTONOMOUS-MODE.md` exactly:

- `MAKATO_HEADLESS=1` SET AND at least one autonomous trigger fired → run autonomous (autonomous wins; the env var is redundant but harmless).
- `MAKATO_HEADLESS=1` SET AND no autonomous trigger fired → HALT with `MISSING_INPUT: headless-without-autonomous` before the first `AskUserQuestion`. Write R1 `status:"failure"` envelope. Do NOT auto-fall-back to autonomous mode — the caller violated the contract.
- `MAKATO_HEADLESS` unset → normal interactive path, no guard fires.

**Callers that MUST export `MAKATO_HEADLESS=1`:** any script that dispatches through
`plugins/makato-orchestrate/scripts/harness-command.sh` (the shared harness-neutral
command adapter — `omp` default resolves to `--yolo`, explicit `MAKATO_HARNESS_MODE=claude`
resolves to `--dangerously-skip-permissions`; never inferred from `MAKATO_HARNESS_BIN`'s
name) targeting a `makato-change` skill. Currently:

- `plugins/makato-orchestrate/scripts/loop.sh` — `cmd_dispatch` (when dispatching change-request issues)
- Any future orchestrate scripts that headlessly invoke `makato-change:orchestrate`

This contract does not depend on which model profile is active (`config/model-profiles.yml`:
`openai` | `qwen-vllm` | `apple-ollama`, selected via `MAKATO_MODEL_PROFILE`) — see
`plugins/makato-build/AUTONOMOUS-MODE.md` § *Defensive-headless guard* for the full
harness-adapter/profile-propagation contract this mirrors.

## HALT codes

| Code | Severity | Trigger | Behavior |
|------|----------|---------|---------|
| `HALT-CH-001` | failure | Headless repo discovery: `REPO_ROOT` not in context bundle AND `repositories.yml` does not exist | Emit R1 `status:"failure"`. Write blocking details to `deferred-questions.md`. Do NOT prompt. |
| `HALT-CH-002` | failure | Critical blocking open question identified during analyze that cannot be deferred | Emit R1 `status:"failure"`. Write blocking questions to `deferred-questions.md` before halting. |
| `HALT-CH-003` | audit | Design auto-approved in autonomous mode (audit marker, not a failure) | Log `autonomous_bypass` JSONL entry. Continue — this code is a signal, not a stop. |
| `HALT-CH-004` | degraded | No test infrastructure detected in headless execute run | Do NOT halt. Set `data.degraded_confidence:true`, `data.no_test_infrastructure:true` in R1. Continue. |

### HALT-CH-001 — headless repository discovery

The `analyze` skill uses `AskUserQuestion` to discover the target repository when `repositories.yml` does not exist. In headless mode no human can answer that prompt. The skill MUST check for `REPO_ROOT` in the dispatch context bundle first:

- `REPO_ROOT` present in bundle → auto-write `repositories.yml` using that path; continue.
- `REPO_ROOT` absent AND `repositories.yml` does not exist → emit HALT-CH-001, write a `deferred-questions.md` entry explaining what is needed, return R1 `status:"failure"`.

### HALT-CH-002 — critical question blocks design

The `analyze` skill asks questions interactively in Step 8. In headless mode, non-critical (clarifying) questions are written to `specs/<issue-key>/deferred-questions.md` and the run continues. A question is critical only when the `requirements-diff-analyzer` explicitly classifies it as `blocking: true` AND a downstream design step cannot proceed without the answer. HALT-CH-002 fires only in that narrow case — ambiguity that merely reduces design quality does not qualify.

### HALT-CH-003 — design auto-approval (audit, not failure)

The `design` skill asks for explicit user approval before posting to GitHub Issues (Step 10). In autonomous mode the design is auto-approved and the GitHub Issues post is conditional on `MAKATO_CHANGE_POST_DESIGN=1`. HALT-CH-003 is the JSONL audit marker emitted by `log-bypass.sh` — it surfaces in `change.jsonl` so a reviewer can identify every auto-approved design run without treating it as an error.

### HALT-CH-004 — no test infrastructure (degraded confidence)

The `execute` skill asks what to do when no test infrastructure is found (Step 3). In headless mode the skill continues with `degraded_confidence:true` rather than halting — a test-less implementation is better than a stalled run. The R1 envelope's `data.no_test_infrastructure:true` flag signals the PO-agent to route the run for elevated human scrutiny after the PR is created. This mirrors the `build-simplify` no-test-runner path in `makato-build/AUTONOMOUS-MODE.md`.

## Phase state file

Every autonomous `orchestrate` run maintains a phase-tracking file at:

```
specs/<issue-key>/change-state-<N>.json
```

where `<N>` is the GitHub issue number (integer, no leading zeros). This file is the canonical record of change-request workflow progress and is the makato-change analog of `workflow-state-<N>.json` in `makato-orchestrate`.

**Schema:**

```json
{
  "schema": "change-state",
  "version": "1.0",
  "issue_key": "<ISSUE-KEY>",
  "issue_number": 1234,
  "current_phase": "analyze",
  "phases_complete": [],
  "worktree_path": null,
  "pr_url": null,
  "started_at": "<ISO-8601-ms>",
  "updated_at": "<ISO-8601-ms>",
  "halt_code": null,
  "degraded_confidence": false
}
```

**Field reference:**

| Field | Type | Description |
|-------|------|-------------|
| `schema` | string | Always `"change-state"` — discriminator for log readers |
| `version` | string | Schema version (`"1.0"`) |
| `issue_key` | string | GitHub Issues key (e.g., `PROJ-1234`) |
| `issue_number` | integer | GitHub issue number — used as `<N>` in the filename |
| `current_phase` | enum | Phase currently executing or last completed; one of `analyze`, `design`, `execute`, `resolve-review`, `done` |
| `phases_complete` | string[] | Ordered list of phases that have reached terminal state |
| `worktree_path` | string\|null | Absolute path to per-run git worktree (set by `worktree.sh`; null until created) |
| `pr_url` | string\|null | PR URL once created by the execute phase |
| `started_at` | ISO-8601-ms | When the autonomous orchestrate run began |
| `updated_at` | ISO-8601-ms | Last write timestamp |
| `halt_code` | string\|null | Most recent HALT code, if any |
| `degraded_confidence` | boolean | True when any phase ran in degraded confidence mode (e.g., HALT-CH-004) |

**Write rules:**

- `orchestrate` writes the file at Step 0.5 (initialization) and updates `current_phase` and `phases_complete` after each phase completes.
- `orchestrate` writes `current_phase:"done"` when all phases reach terminal state.
- No phase skill writes this file directly — `orchestrate` is the sole writer.

## Loop in-flight compatibility

For the `makato-orchestrate` loop to track a change-request run without re-dispatching a completed issue, `orchestrate` MUST also maintain a compatible `workflow-state-<N>.json` stub at:

```
specs/<issue-key>/workflow-state-<N>.json
```

**On autonomous start (Step 0.5):** write a minimal stub:

```json
{
  "schema": "workflow-state",
  "version": "1.0",
  "issue_key": "<ISSUE-KEY>",
  "issue_number": 1234,
  "current_phase": "in_progress",
  "plugin": "makato-change",
  "started_at": "<ISO-8601-ms>",
  "updated_at": "<ISO-8601-ms>"
}
```

**On terminal state (all phases done):** patch `current_phase` to `"done"` and set `updated_at`. The loop's poller reads `current_phase` to know when the issue is unblocked; clearing to `"done"` prevents re-dispatch of a completed run.

**On HALT:** patch `current_phase` to `"halted"`, set `halt_code` in `change-state-<N>.json`, and set `updated_at` in both files.

**Why a separate file from `change-state-<N>.json`:** `workflow-state-<N>.json` is the contract the `makato-orchestrate` loop reads. `change-state-<N>.json` is the richer makato-change-specific record. Both co-exist; `orchestrate` maintains both and keeps them in sync at every phase boundary.

## Worktree integration

In autonomous mode, `orchestrate` uses `makato-orchestrate/shared/worktree.sh` to create and manage a per-run git worktree for the target repository. This provides branch isolation equivalent to the `makato-build` pipeline's `WORKTREE_PATH` contract.

**Activation:** worktree integration is only active when `MAKATO_HEADLESS=1` AND at least one autonomous trigger fires.

**Script location:** resolved via the `MAKATO_ORCHESTRATE_SHARED` environment variable:

```bash
WORKTREE_SH="${MAKATO_ORCHESTRATE_SHARED}/worktree.sh"
```

`MAKATO_ORCHESTRATE_SHARED` must be exported by the caller. Typical value: `plugins/makato-orchestrate/shared` (absolute path in practice).

If `MAKATO_ORCHESTRATE_SHARED` is unset in autonomous mode, `orchestrate` logs a warning and skips worktree creation (degraded mode — branch isolation is not guaranteed). It does NOT HALT on this absence because worktree support is an enhancement, not a prerequisite for correctness.

**Lifecycle (mirrors `po-agent.md` § *Worktree Lifecycle*):**

1. **Step 0.5 (start):** `${WORKTREE_SH} create --new-branch <KEY> <ISSUE_NUMBER> <REPO_NAME> <BRANCH_NAME>`. Store returned path in `change-state-<N>.json:.worktree_path`.
2. **Each phase dispatch:** pass `WORKTREE_PATH` in the phase skill's context bundle.
3. **Terminal state (done):** `${WORKTREE_SH} cleanup <KEY> <ISSUE_NUMBER>`.
4. **Any HALT:** `${WORKTREE_SH} retain <KEY> <ISSUE_NUMBER> <HALT_CODE>` to preserve the worktree for inspection.

**Contract with phase skills:** phase skills receive `WORKTREE_PATH` in their context bundle and MUST use it for all git operations and file edits, following the two-roots contract defined in `makato-build/AUTONOMOUS-MODE.md` § *Two roots, one contract*. Spec artifacts (`specs/<key>/`) live in `REPO_ROOT`; source-tree edits live in `WORKTREE_PATH`.

## Default-taking rules per gate

| Skill | Gate | Interactive behavior | Autonomous default |
|-------|------|---------------------|-------------------|
| `orchestrate` | Step 1 — issue key prompt | Asks user for issue key | Use CLI arg; HALT `MISSING_INPUT` if absent |
| `orchestrate` | Step 4 — phase selection | AskUserQuestion with options | Auto-select recommended next phase |
| `orchestrate` | Step 7 — loop-or-exit | Asks what to do next | Continue until all phases complete; exit on HALT |
| `analyze` | Step 2.5 — repo discovery | AskUserQuestion for repo path | Use `REPO_ROOT` from bundle + auto-write `repositories.yml`; HALT-CH-001 if absent |
| `analyze` | Step 8 — open questions | AskUserQuestion per question | Write non-critical questions to `deferred-questions.md`; HALT-CH-002 for critical blocking questions |
| `design` | Step 3 — discovery preference | Asks guided vs exploratory | Auto-select guided mode |
| `design` | Step 5.6 — scenario classification | AskUserQuestion for confirmation | Auto-approve classifications; log `autonomous_bypass` |
| `design` | Step 10 — design approval | AskUserQuestion (3 options) | Auto-approve; post to GitHub only if `MAKATO_CHANGE_POST_DESIGN=1`; log HALT-CH-003 |
| `execute` | Step 3 — no test infrastructure | AskUserQuestion (3 options) | Continue with `degraded_confidence:true`; log HALT-CH-004 signal |
| `execute` | Step 6 — branch creation | `git -C <REPO_ROOT> checkout -b` | Use `worktree.sh` via `MAKATO_ORCHESTRATE_SHARED`; fall back to `git checkout -b` if unset |

## Cross-skill propagation

`orchestrate` forwards `--autonomous` activation to each downstream phase skill via the Skill tool `args` parameter:

```
Skill(skill="makato-change:analyze", args="<ISSUE_KEY> --autonomous")
```

Phase skills detect autonomous mode through the same three triggers. `$AGENT_ID` propagates implicitly across subprocess boundaries when set.

Phase skills MUST NOT forward `--autonomous` on their own internal agent dispatches (e.g., `code-explorer`, `requirements-diff-analyzer`). `$AGENT_ID` handles activation implicitly. Context-bundle fields (`WORKTREE_PATH`, `REPO_ROOT`, `ISSUE_KEY`) MUST be forwarded explicitly — they carry state the env cannot.

## Logging contract

Every gate bypassed in autonomous mode MUST emit a `change.jsonl` entry using the same helper as `makato-build`:

```bash
shared/log-bypass.sh <skill> <key> <gate> <default_taken> <trigger> [extra-json-object]
```

The log file is `specs/<issue-key>/change.jsonl`. The emitted entry shape matches `makato-build/AUTONOMOUS-MODE.md` § *Logging contract* exactly, with `"skill"` set to the makato-change skill name. Use `change.jsonl` rather than `orchestrate.jsonl` to avoid namespace collision when `makato-orchestrate`'s loop is also writing to the specs folder.

## R1 return envelope

In autonomous mode every `makato-change` skill returns R1-shaped output. Minimum fields:

```json
{
  "schema": "r1",
  "agent": "<skill-name>",
  "status": "success" | "partial" | "failure",
  "summary": "<one-line synthesis>",
  "files_changed": [],
  "errors": [],
  "data": {
    "current_phase": "<phase>",
    "phases_complete": [],
    "halt_code": null,
    "degraded_confidence": false
  }
}
```

In interactive mode this envelope is OPTIONAL. In autonomous mode it is MANDATORY and must be the final `json`-fenced block in the skill's output.

## Skills NOT in scope

- `resolve-review` — requires human judgment on PR feedback; the interactivity is the work itself. The PO-agent invokes it only when a human reviewer has already left comments. Automating it without a human reviewer in the loop adds no value.

## Backward compatibility

This convention is purely additive. Skills retain every existing `AskUserQuestion` call; they only learn to skip it when autonomous mode is active. A skill that has not yet been updated to this convention continues to run interactively under all activation triggers — autonomous activation is per-skill, not global. The loop only dispatches updated skills.
