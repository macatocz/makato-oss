# Autonomous Mode — orchestrate reference

> Canonical source: `plugins/makato-change/AUTONOMOUS-MODE.md`. This reference
> summarizes the contract sections needed by `orchestrate`; for per-skill gate
> rules (analyze, design, execute) read the canonical source.

## Activation triggers

A `makato-change` skill runs in **autonomous mode** when ANY of the following holds (OR-equivalent):

1. `--autonomous` is passed on the CLI (e.g. `makato-change:orchestrate PROJ-1234 --autonomous`).
2. The caller provides a context bundle whose payload includes a `task_id` field.
3. The `$AGENT_ID` environment variable is exported (set by makato agent dispatch infrastructure).

If none hold, the skill runs in **interactive mode**.

## MAKATO_HEADLESS guard

`MAKATO_HEADLESS=1` is **not** an autonomous trigger — it is the opposite: a caller-side assertion that no human is at the prompt.

- `MAKATO_HEADLESS=1` **AND** at least one autonomous trigger fires → run autonomous (autonomous wins; the env var is redundant but harmless).
- `MAKATO_HEADLESS=1` **AND** no autonomous trigger fires → HALT with `MISSING_INPUT: headless-without-autonomous` before the first `AskUserQuestion`. Write R1 `status:"failure"`. Do NOT auto-fall-back to autonomous mode — the caller violated the contract.
- `MAKATO_HEADLESS` unset → normal interactive path; no guard fires.

## HALT codes

| Code | Severity | Trigger | Behavior |
|------|----------|---------|---------|
| `HALT-CH-001` | failure | `REPO_ROOT` not in context bundle AND `repositories.yml` absent | Emit R1 `status:"failure"`. Write blocking details to `deferred-questions.md`. Do NOT prompt. |
| `HALT-CH-002` | failure | Critical blocking question in analyze that cannot be deferred | Emit R1 `status:"failure"`. Write blocking questions to `deferred-questions.md` before halting. |
| `HALT-CH-003` | audit | Design auto-approved in autonomous mode | Log `autonomous_bypass` JSONL entry. Continue — this code is a signal, not a stop. |
| `HALT-CH-004` | degraded | No test infrastructure detected in headless execute run | Continue with `data.degraded_confidence:true`. Not a stop — set flag in R1. |

**Escalation:** HALT-CH-001 and HALT-CH-002 require human input before the run continues. HALT-CH-003 is audit-only; continue. HALT-CH-004 sets degraded confidence but does not stop the run.

## Default-taking rules (orchestrate gates only)

| Gate | Interactive behavior | Autonomous default |
|------|---------------------|-------------------|
| Step 1 — issue key prompt | Asks user for issue key | Use CLI arg; HALT `MISSING_INPUT` if absent |
| Step 4 — phase selection | AskUserQuestion with options | Auto-select recommended next phase |
| Step 7 — loop-or-exit | Asks what to do next | Continue until all phases complete; exit on any HALT |

For per-skill gate defaults (analyze, design, execute), see the full canonical source.

## Cross-skill propagation

`orchestrate` forwards `--autonomous` to each downstream phase skill via the Skill tool `args` parameter:

```
Skill(skill="analyze", args="<ISSUE_KEY> --autonomous")
```

Phase skills MUST NOT forward `--autonomous` on their own internal agent dispatches (e.g., `code-explorer`, `requirements-diff-analyzer`). `$AGENT_ID` handles activation implicitly across subprocess boundaries. Context-bundle fields (`WORKTREE_PATH`, `REPO_ROOT`, `ISSUE_KEY`) MUST be forwarded explicitly — they carry state the env cannot.

## Skills NOT in scope

- `resolve-review` — requires human judgment on PR feedback; the interactivity is the work itself. The PO-agent invokes it only when a human reviewer has already left comments. Automating it without a human reviewer in the loop adds no value.

## Phase state file

Every autonomous `orchestrate` run maintains `specs/<issue-key>/change-state-<N>.json` where `<N>` is the GitHub issue number (integer, no leading zeros).

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

**Write rules:** `orchestrate` is the sole writer of this file. No phase skill writes it directly. `orchestrate` updates `current_phase` and `phases_complete` after each phase completes, writes `current_phase:"done"` at terminal state.

## R1 return envelope

Minimum fields — **mandatory** in autonomous mode, **optional** in interactive:

```json
{
  "schema": "r1",
  "agent": "<skill-name>",
  "status": "success | partial | failure",
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

In autonomous mode this envelope MUST be the final `json`-fenced block in the skill's output.
