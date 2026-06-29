<!-- markdownlint-disable MD013 MD032 MD040 -->
# Autonomous Mode — makato-build approval-gate bypass convention

> **Status**: Authoritative for all `build-*` skills in this plugin. When a skill takes a runtime decision via `AskUserQuestion`, autonomous mode replaces that decision with the documented default. Interactive runs are unaffected.

## Why this exists

Every `build-*` skill that transitions between pipeline phases calls `AskUserQuestion` for approval. This is intentional for interactive use — but it structurally prevents headless operation by a PO-agent. The PO-agent (GAP-006 / #32) drives the build pipeline end-to-end without a human at the prompt, parsing R1 envelopes (GAP-002 / #24) from each skill's last `json`-fenced block. For that to work, every gate that today waits on a human must take a deterministic, documented default in autonomous mode.

`plugins/makato-plan/skills/to-issues/SKILL.md` v3.4.0 already proves the bypass pattern (see its § *Mode detection (D10)* and § *Autonomous Execution*). This document is the build-plugin equivalent — same shape, same activation triggers, same logging contract.

## Activation triggers

A `build-*` skill runs in **autonomous mode** when ANY of the following holds:

1. `--autonomous` is passed on the CLI (e.g. `/makato-build:build-refine GAP-005 --autonomous`).
2. The caller provides a context bundle whose payload includes a `task_id` field (the convention agent-dispatch infrastructure uses to mark a downstream invocation).
3. The `$AGENT_ID` environment variable is exported (set by makato agent dispatch infrastructure).

If none of those hold the skill runs in **interactive mode**, exactly as it did before this convention existed. Interactive mode is the default — autonomous mode is opt-in by infrastructure or CLI flag.

**Precedence:** the three triggers are OR-equivalent. Once any one is true the skill is autonomous; further checks are unnecessary.

## Default-taking rules per gate

| Skill | Gate (line ref to the `AskUserQuestion` site) | Interactive behavior | Autonomous default |
|---|---|---|---|
| `build-refine` | Step 1 — work-item-key prompt | Asks for key | If no arg passed: HALT `MISSING_INPUT`. If arg passed: use it. |
| `build-refine` | Step 11 — plan-review (in-chat vs in-browser) | Asks how to review | Write `plan.md`, skip review entirely, proceed to hand-off. |
| `build-push-to-git` | Step 4 — commit-grouping confirmation | Asks user to confirm grouping & messages | Use plan task `commitMessage` fields verbatim; no confirmation. |
| `build-push-to-git` | Step 6 — push confirmation | Asks "Ready to push N commits?" | Push immediately. Pre-push hook still fires. |
| `build-push-to-git` | Step 8 — hand-off to create-pr | Asks A/B | Auto-invoke `/build-create-pr <key> --autonomous`. |
| `build-create-pr` | Step 1 — work-item-key prompt | Asks for key (optional) | Use arg if passed; otherwise read `issue_number`/`branch` from most-recent `build.jsonl` session in the spec folder. HALT `MISSING_INPUT` only if neither yields a value. |
| `build-create-pr` | Step 4 — draft approval | Asks "Does this PR description look correct?" | Open PR as drafted. PR body is rendered from spec artifacts and workflow-state (no human authoring). |
| `build-address-pr-comments` | Step 5 — classification approval | Asks user to confirm/adjust classification + handles STRUCTURAL flow | Auto-apply MUST-FIX (non-STRUCTURAL) and SHOULD-FIX. Skip CONSIDER. Skip OUT-OF-SCOPE. STRUCTURAL MUST-FIX: HALT (see below). |
| `build-address-pr-comments` | Step 8 — push-fix confirmation | Asks before push | Push immediately. |
| `build-simplify` | Step 5 — per-finding approval | Asks user to approve/reject each SIMPLIFY finding | Auto-approve every `SIMPLIFY` finding (apply in Step 6). KEEP findings remain KEEP (no action). ESCALATE findings are not auto-applied — they are logged and surfaced in the R1 envelope so the PO-agent can decide whether to open a `/build-refine` session for the structural piece. |
| `build-simplify` | Step 5 — zero-findings confirmation | Asks user to confirm zero findings | Proceed without confirmation. Log `step: "review"` with `data.zero_findings: true`. |

### STRUCTURAL MUST-FIX is deliberately not auto-handled

`build-address-pr-comments` classifies a MUST-FIX as **STRUCTURAL** when it requires changing the fundamental implementation approach (data model redesign, API contract reversal, algorithm replacement). In autonomous mode the skill does NOT attempt to auto-fix structural items — it halts with R1 `status: "failure"` and an error string `STRUCTURAL_BLOCKER: <comment summary>`. The PO-agent reads the R1 envelope and escalates (e.g. opens a fresh `/build-refine` session or surfaces to the human operator).

This is a deliberate gap, not an oversight. Re-planning is a judgment call the build pipeline does not attempt headlessly.

### ESCALATE findings in `build-simplify` are deliberately not auto-applied

`build-simplify` Step 4 classifies a finding as **ESCALATE** when the complexity is structural — it cannot be resolved without changing the implementation approach — OR when the simplification would remove a security guard (input validation, auth check, CSRF token, rate limiter). In autonomous mode these findings are NOT auto-applied; they are logged with `step: "escalate", status: "warn"` and surfaced in the R1 envelope's `data.escalated` array so the PO-agent can decide whether to open a `/build-refine` session for the structural piece.

This mirrors `build-address-pr-comments` STRUCTURAL-MUST-FIX handling: deterministic-and-safe is auto-applied; judgment-required is surfaced upward, never silently skipped.

A `build-simplify` session that produced zero SIMPLIFY findings AND any ESCALATE findings returns R1 `status: "partial"` (work remains for the PO-agent). A session with zero ESCALATE findings (any SIMPLIFY count, including zero) returns `status: "success"`.

## Cross-skill propagation

When an autonomous-mode skill auto-invokes the next skill in the pipeline, it MUST forward the `--autonomous` flag explicitly. For example, `build-push-to-git` in autonomous mode invokes `/build-create-pr <key> --autonomous` — not `/build-create-pr <key>`. This keeps the activation contract explicit at every hand-off and avoids autonomous-mode "leaking" implicitly through process state.

`$AGENT_ID`-driven activation does propagate implicitly (env vars cross sub-process boundaries), but downstream skills SHOULD still read the CLI flag for symmetry with the documented contract.

## WORKTREE_PATH — workspace-isolation contract (GAP-017 / #46, follow-up #85)

Every autonomous-mode dispatch from the PO-agent carries a `WORKTREE_PATH` field in the dispatch context bundle. This is the absolute filesystem path to the per-run git worktree the PO-agent owns (see `plugins/makato-orchestrate/agents/po-agent.md` § *Worktree Lifecycle* § *Inheritance*). Sub-agents MUST `cd "$WORKTREE_PATH"` (or pass `-C "$WORKTREE_PATH"` to git) before any file edit, `git`, test, or build command, so the work lands in the worktree's branch and never on the main checkout.

**Contract:**

- `WORKTREE_PATH` is **mandatory** in every `--autonomous` invocation initiated by the PO-agent. If autonomous mode is active and `WORKTREE_PATH` is empty, the skill MUST HALT with R1 `status: "failure"` and `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]` — silently falling back to the main checkout defeats Layer 1 workspace isolation.
- `WORKTREE_PATH` is **optional** for non-autonomous (developer-hands) callers. When unset in interactive mode, skills fall through to `git rev-parse --show-toplevel` of the current `$PWD` — the original developer-driven behaviour, unchanged.
- Skills that auto-dispatch other skills MUST forward `WORKTREE_PATH` in the downstream context bundle, exactly as they forward `--autonomous`. Implicit env propagation is not relied on — the field stays explicit in every hand-off.
- Skills that dispatch agents (e.g. `build-implement-tdd` → `coder`) MUST inject `WORKTREE_PATH` into the agent's input bundle. The agent then `cd`s into that path before its inner cycle.

**Autonomous-mode detection in the falsy-check:** the canonical signal is the same as elsewhere in this doc — `$AGENT_ID` exported in the env (set by makato agent dispatch infrastructure) OR the caller's CLI carries `--autonomous` OR the context bundle has a `task_id` field. There is no separately-set `$AUTONOMOUS` env var; the snippet below tests `$AGENT_ID` only because it is the single signal the bash level can observe (CLI flags are arguments the skill has already parsed; bundle fields live in the prompt). Earlier drafts of this section referenced `${AUTONOMOUS:-false}` — that branch never fires in practice; do not rely on it in new code.

**Falsy-check pattern:**

```bash
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  # Autonomous mode without WORKTREE_PATH is a contract violation — HALT.
  # In interactive mode, fall back to the current checkout.
  if [[ -n "${AGENT_ID:-}" ]]; then
    # emit R1 failure with MISSING_INPUT and stop
    exit 1
  fi
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
cd "$WORKTREE_PATH"
```

The skill-level guard is the more important enforcement point: a skill running in `--autonomous` mode (from CLI flag or `task_id` bundle) MUST treat empty `WORKTREE_PATH` as `MISSING_INPUT` regardless of whether `$AGENT_ID` was exported. The bash snippet covers the agent-dispatched case; the SKILL.md prose covers the full `--autonomous` activation set.

**Why `git -C` over `cd`:** for one-shot git invocations, `git -C "$WORKTREE_PATH" <cmd>` is preferred — it does not mutate the surrounding shell's CWD and avoids leaking the worktree path into pwd-relative downstream commands. For test runners and longer subprocess sequences (pytest, npm, build commands that read relative config), `cd "$WORKTREE_PATH"` once at skill entry is fine.

**Concurrency rationale:** two concurrent PO-agent runs each get their own worktree (different branches, different HEADs). Without `WORKTREE_PATH` propagation both runs would serialise on the main checkout's HEAD — a silent race that defeats the per-run isolation guarantee.

### Two roots, one contract — `WORKTREE_PATH` vs `REPO_ROOT`

Worktree isolation has a non-obvious consequence: not every read or write belongs in the worktree. `specs/<key>-*/` is `.gitignore`d at the repo root (see the repo-level `.gitignore`), so a fresh `git worktree add` produces a worktree with NO `specs/` content. Two artefacts therefore have distinct correct homes:

| Artefact | Lives in | Why |
|----------|----------|-----|
| Source-tree edits, `git commit`, `git push`, test runs | `WORKTREE_PATH` | The branch HEAD only moves in the worktree; commits to the main checkout would target the wrong branch. |
| `specs/<key>-*/plan.md`, `stories.json`, `prd.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `created-issues.json` | Main checkout (`REPO_ROOT`) | `specs/` is gitignored and exists only on the main checkout. A worktree-relative read returns nothing or an error. |
| `specs/<key>-*/build.jsonl`, `orchestrate.jsonl` | Main checkout (`REPO_ROOT`) | The audit trail is single-writer across all worktrees of a run; `shared/build-log.sh` resolves `REPO_ROOT` from `git rev-parse --git-common-dir` so logs land in one place. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Whichever checkout has it tracked — both, in this repo's setup | Tracked file; `git -C "$WORKTREE_PATH"` reads it fine. The point is that *reading the spec artefact next to it (`plan.md`)* still requires `REPO_ROOT`. |

**Resolving the two roots:**

```bash
# Worktree path — workspace isolation (file edits, git ops, test runs).
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  if [[ -n "${AGENT_ID:-}" ]]; then exit 1; fi
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
# Repo root — spec/audit-trail reads (plan.md, stories.json, build.jsonl).
# `--git-common-dir` echoes the main repo's .git from inside a worktree;
# its parent is the main checkout. From the main checkout it echoes `.git`.
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

`shared/build-log.sh` already encapsulates the `REPO_ROOT` derivation and is the single point that resolves `specs/<key>-*/build.jsonl` correctly from either checkout. Skills that read spec artefacts directly (e.g. `build-push-to-git` and `build-create-pr` reading `plan.md` in Step 1) MUST resolve `REPO_ROOT` via the snippet above and read `$REPO_ROOT/specs/<key>-*/...` — never via `$WORKTREE_PATH/specs/...`.

**Skills that consume this contract:**

The autonomous-mode pipeline has two cohorts of consumers. Both honour the falsy-check / fallback. The second cohort also reads spec artefacts and therefore resolves `REPO_ROOT` separately.

- `build-implement-tdd` — Step 6 dispatches `coder` per task; forwards `WORKTREE_PATH` in the coder bundle. Plan reads via `REPO_ROOT`.
- `build-implement-goal` — same pattern; goal-mode build steps `cd` before file edits and verification. Plan reads via `REPO_ROOT`.
- `build-verify` — gate runner; lint/test/coverage commands run from `WORKTREE_PATH`.
- `build-push-to-git` — `git commit` / `git push` operate against the worktree's branch. Plan reads via `REPO_ROOT`. Forwards `WORKTREE_PATH` to `build-create-pr` when auto-dispatching at Step 8.
- `build-create-pr` — `gh pr create` resolves the right branch from the worktree's `.git`. Spec artefact reads (`stories.json`, `prd.md`, `plan.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `created-issues.json`) via `REPO_ROOT`.
- `build-refine` — produces `plan.md`; reads spec folder via `REPO_ROOT`. Honours the falsy-check when dispatched by the PO-agent on a re-plan cycle (Step 4f of `po-agent`).
- `build-simplify` — runs `git diff main...HEAD` and applies fixes in `WORKTREE_PATH`. Plan reads via `REPO_ROOT`.
- `build-address-pr-comments` — `gh pr` calls + per-comment fix-apply operate from `WORKTREE_PATH`. Spec artefact reads via `REPO_ROOT`.
- `coder` agent — receives `WORKTREE_PATH` in its input bundle; `cd`s before RED→GREEN→INTEGRATE→VERIFY. In autonomous mode, the agent MUST HALT R1 `failure` with `MISSING_INPUT: WORKTREE_PATH required in autonomous mode` when the field is empty — silently falling back to the main checkout defeats Layer 1 isolation. Detection: any of `$AGENT_ID`, an `AUTONOMOUS_MODE` field in the dispatch bundle, or the absence of an interactive prompt context.

The PO-agent's Step 2b creates the worktree and Step 6 #6 cleans it up; see `plugins/makato-orchestrate/agents/po-agent.md` § *Worktree Lifecycle* for the full lifecycle.

## Logging contract

Every gate that the skill bypasses in autonomous mode MUST emit a `build.jsonl` entry via `shared/build-log.sh` with this shape:

```json
{
  "ts": "<ISO-8601>",
  "skill": "<skill-name>",
  "story": "<key>",
  "step": "decision",
  "status": "decision",
  "data": {
    "event": "autonomous_bypass",
    "gate": "<short-name-from-table-above>",
    "bypassed": true,
    "default_taken": "<value-from-table>",
    "trigger": "agent_id" | "cli_flag" | "task_id_bundle"
  }
}
```

Notes on the shape:

- `step: "decision"` and `status: "decision"` are the existing convention for non-happy-path agent decisions (see plugin AGENTS.md Design Principle 4). The `data.event: "autonomous_bypass"` discriminator is what makes these entries machine-searchable.
- `gate` matches the short name from the per-gate table (e.g. `"plan-review"`, `"commit-grouping"`, `"push-confirm"`, `"pr-draft-approval"`, `"comment-classification"`).
- `default_taken` is the actual value applied — e.g. `"approve"`, `"plan-as-drafted"`, `"push"`, `"open-pr-as-drafted"`, `"auto-apply"`, `"halt"`.
- `trigger` records which activation source fired. Useful when a session was driven by a misconfigured CI step (`cli_flag` when expected was `agent_id`).

A session that visited N autonomous gates MUST produce N `autonomous_bypass` entries. A future reader running `jq 'select(.data.event=="autonomous_bypass")' build.jsonl` reconstructs every decision the pipeline took without a human.

## Reference R1 return envelope

In autonomous mode every modified skill returns R1-shaped output (GAP-002 / #24). The shape is documented in `plugins/makato-build/agents/RETURN-CONTRACT.md` and applies verbatim to skills as well as agents. The minimum fields a build-* skill emits at session end:

```json
{
  "schema": "r1",
  "agent": "<skill-name>",
  "status": "success" | "partial" | "failure",
  "summary": "<one-line synthesis>",
  "files_changed": [...],
  "tests_written": [...],
  "errors": [...],
  "tool_calls_used": 0,
  "data": { /* skill-specific — see each skill's Autonomous Execution section */ }
}
```

In interactive mode this envelope is OPTIONAL — interactive output is for a human and prose suffices. In autonomous mode it is MANDATORY and must be the final `json`-fenced block in the skill's output.

## Skills NOT in scope

These pipeline skills are explicitly excluded from autonomous-mode wiring:

- `build-sensors` — already halts on non-zero pre-commit exit; no human gate to bypass. Sensor-fixer escalates via tier-up to opus; no `AskUserQuestion` site.
- `build-verify` — already halts on gate failure; no human gate to bypass.
- `build-implement-tdd` / `build-implement-goal` — the inner per-task loop already runs autonomously; there is no approval gate between RED/GREEN/INTEGRATE/VERIFY phases.
- `build-grill-with-docs`, `build-review` — these run review-style queries against the diff; their interactivity is the work itself, not a gate. Autonomous orchestration calls them or skips them; it doesn't bypass parts of them.
- `build-resolve-finding` — driven by sensor-fixer with deterministic branches already.
- `build-start` — the entry skill; it must remain interactive because it captures the implementation mode and confirms branch state. The PO-agent does not invoke `build-start` — it invokes the post-start skills directly with workflow-state already populated.

> `build-simplify` was previously listed here on the grounds that "its interactivity is the work itself." That reasoning pre-dated `finding-routes.json` routing sensor findings into the skill via `sensor-fixer` → `build-resolve-finding` (#59 / #60). Once the skill is dispatched headlessly the per-finding approval prompt becomes a real gate, and v1.3+ honors autonomous mode per the table above.

Shaping skills in `makato-plan/` are also out of scope: they require human judgment by design (brainstorming, PRD authoring, architecture decisions, story slicing). The PO-agent operates on stories that have already been shaped.

## Reference implementation

`plugins/makato-plan/skills/to-issues/SKILL.md` (v3.4.0) is the canonical reference for the bypass pattern. When in doubt about phrasing, mirror what `to-issues` does:

- Mode-detection block lives right after the first orientation step (Step 0 / Step 1).
- Bypass logic is described inline at each gate as a conditional ("In autonomous mode, …"), never as a separate "if autonomous" branch at the top of the skill.
- The skill ends with a § *Autonomous Execution* section listing activation triggers, behavior, R1 return format, and HALT codes.

## Backward compatibility

This convention is purely additive. Skills retain every existing `AskUserQuestion` call; they only learn to skip it when autonomous mode is active. A skill that has not yet been updated to this convention continues to run interactively under all activation triggers — autonomous activation is per-skill, not a global mode. The PO-agent (GAP-006) only dispatches updated skills.

## Versioning

This document is referenced (not embedded) by each updated skill. When the convention changes:

- Patch / minor edits (clarifications, new gates added, log-field additions): bump each consuming skill's `version` minor when its behavior changes; this doc itself carries no version field.
- Breaking change (activation trigger removed, log shape changed): rename the file to `AUTONOMOUS-MODE-v2.md` and migrate skills one at a time. The PO-agent reads the version from the skill's frontmatter, not from this file.
