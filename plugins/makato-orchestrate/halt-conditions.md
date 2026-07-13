# HALT Conditions — makato-orchestrate

> **Authoritative reference.** Every autonomous exit path in this plugin maps to a HALT code
> below. PO-agent and supporting skills MUST emit one of these codes (never a free-text status)
> when terminating outside the success path.

The PO-agent's only acceptable exits are:

1. **A merged PR** (`current_phase: "done"`, `github_pr_number` populated).
2. **A HALT code** from the table below, persisted to `workflow-state.json` via the
   `halt_audit[]` array and audited to `specs/<key>-<slug>/orchestrate.jsonl`.

Silent termination is a contract violation.

## HALT taxonomy

There are two HALT categories. The distinction is **load-bearing** and drives whether the issue
gets the `needs-human-review` label:

| Category | Meaning | Issue labelled `needs-human-review`? | Next operator action |
|----------|---------|--------------------------------------|----------------------|
| **Hard stop** | Mission cannot continue without human judgement. Cost ceilings, structural blockers, kill-switches. | **Yes** | Investigate; re-invoke `loop --autonomous` manually after fix. |
| **Soft handoff** (HALT-007B only) | Mission CAN continue — the current Claude session just can't carry it any further. Quality control, not cost control. | **No** | None. A fresh subprocess restarts automatically via `resume-{KEY}.sh`. |

## Code table

| Code | Trigger | Action | Recovery |
|------|---------|--------|----------|
| **HALT-000** | `~/.claude/HALT` file exists at session start OR detected by `hooks/check-halt.sh` PreToolUse poll. | PO-agent exits immediately. Writes `halt_audit` entry with `code: "HALT-000"`. No `needs-human-review` label (operator-initiated). | Operator removes `~/.claude/HALT`, then re-invokes `loop --autonomous <issue>`. |
| **HALT-001** | `pre-commit` fast-lane gate failed and `sensor-fixer` could not repair within MAX_LOOPS=5. | PO-agent terminates with `needs-human-review`; `build.jsonl` already carries forensics. | Operator inspects failed sensor output, fixes manually, restarts the loop. |
| **HALT-002** | `build-verify` reports test coverage below configured floor and re-plan via `build-refine` failed to recover. | `needs-human-review`; `build.jsonl` records the gap. | Operator either raises coverage manually or relaxes the floor in the consumer repo's `makato.config.json`. |
| **HALT-003** | `diff-reviewer` returned `status: "failure"` with CRITICAL findings the `coder` could not address in the allowed retry budget. **Also fires** when `build-address-pr-comments` (autonomous mode) detects one or more STRUCTURAL MUST-FIX comments — the skill posts a summary PR reply, applies `needs-human-review` itself, returns R1 `failure` with `data.halt_code: "HALT-003"` and `errors: ["STRUCTURAL_BLOCKER: …"]`. | `needs-human-review`; CRITICAL findings or STRUCTURAL summaries persisted to `workflow-state.json` under the most recent sub-task's `agent_result.errors`. | Operator reviews findings, decides per-finding whether to fix manually, suppress with rationale, or revert the change. For STRUCTURAL: typically re-shape the story via `makato-plan`, or override the structural call and re-run `build-address-pr-comments` interactively. |
| **HALT-004** | `sensor-fixer` outer loop hit its bounded retry counter (MAX_LOOPS=5) on the same finding. | `needs-human-review`; sensor finding ID and last 5 attempts logged. | Operator manually resolves the finding; sensor harness then accepts a clean commit. |
| **HALT-005** | `git push` was denied by the pre-push deny-list (force-push to main, push of a `needs-human-review`-tagged branch, etc.). | `needs-human-review`; deny reason logged. | Operator reviews intent — if push is legitimate, removes the deny condition (e.g. rebases away from main) and restarts. |
| **HALT-006** | The dispatch context bundle (`specs/<key>-<slug>/`) is missing, malformed, or refers to artifacts that don't exist on disk. **Auto-materialize (#200):** when the *only* fault is a missing spec folder or a stub `plan.md` AND the issue carries `plan-tier:light`, the PO-agent's Step 1a first dispatches the `light-planner` agent to synthesize a real `plan.md` from the issue body and retries Step 1 **once** (gated by `scripts/should-materialize-spec.sh`). HALT-006 fires only if that single attempt does not yield a `validate-plan-body.sh`-valid plan (thin body / hollow plan), or the issue is not `plan-tier:light`. | `needs-human-review`; missing-path list logged. | Operator re-runs `makato-plan`'s `decompose` to regenerate the spec folder, or expands the issue body so light-planner can produce a plan on the next `loop --autonomous` run. |
| **HALT-007** | `budget_consumed_tokens >= budget_limit_tokens` (per-task ceiling) OR daily ceiling (`MAKATO_DAILY_TOKEN_BUDGET`) tracked in `.claude/state/daily-budget-{YYYY-MM-DD}.json` exceeded. **Cost control.** Also fires as the **fallback** when HALT-007B's self-restart subprocess could not be spawned (`restart_failed: true`), and when `session_count >= MAKATO_MAX_HANDOFFS` (default 5). | `needs-human-review`; current budget snapshot and ceiling source (per-task vs daily vs handoff-cap vs restart-failure) logged. | Operator decides: raise budget, split issue, or write off the work. Then restarts `loop --autonomous`. |
| **HALT-007B** | `(budget_consumed_tokens - session_baseline_tokens) >= context_warn_tokens` at an outer-loop boundary — i.e. the **per-session context delta**, not the cumulative total (#281). **Quality control**, not cost control — fires before the context window degrades around 170 k. On handoff, `session_baseline_tokens` is advanced to the current `budget_consumed_tokens` so the resumed session's delta restarts at 0 (this is what prevents the resume-storm; the cumulative counter is left untouched for HALT-007). | **No `needs-human-review`.** PO-agent runs `scripts/context-handoff.sh`: checkpoints `resume_point`, dispatches `context-summariser` for a ≤ 500-token session summary, emits `.claude/state/resume-{KEY}.sh`, executes that script detached, exits the current session with status `HANDOFF`. `handoff_reason: "context_ceiling"` set; `session_count` incremented; `session_baseline_tokens` advanced. | **None — automatic.** A fresh `claude --dangerously-skip-permissions --resume {KEY} -p "<prompt that dispatches makato-orchestrate:po-agent for issue #{ISSUE}>"` subprocess takes over without operator action. The prompt names the po-agent subagent explicitly so the resumed session delegates instead of invoking `makato-build` skills directly (which would default to interactive mode and deadlock a headless `claude -p` — see #160). The `session-status.sh` SessionStart hook (GAP-007 follow-up) prints a `↻ context handoff in progress — resumed from task {N} (session N+1)` banner. |
| **HALT-008** | TWO origins (both fire HALT-008 with the same `needs-human-review` action — distinguished by the `data` payload): (a) `outer_iteration >= 3` — re-plan-and-retry loop exceeded its budget, enforced by `kill-switch poll`; (b) `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3, GAP-016 / #45) — the `resolve-pr-conflict` skill exhausted its rebase + `merge -X ours` retry budget on irreconcilable conflicts. The two counters are independent — a single run can exhaust both. | `needs-human-review`; iteration audit logged. Worktree retained on the merge-conflict path so a human can inspect the conflicted tree. | Operator reads the `lessons_learned` trail, decides whether to rewrite the plan, split the story, or resolve the conflict by hand. For the merge-conflict origin: `cd <worktree_path> && git status` to inspect, then resolve manually and re-run `loop --autonomous <issue>`. |
| **HALT-009** | GitHub `claude-halt` label detected on the target issue by the `kill-switch` poll (~60 s interval). | PO-agent terminates cleanly at the next outer-loop boundary; `needs-human-review` applied; the `claude-halt` label is preserved as the operator's intent marker. | Operator removes `claude-halt`, removes `needs-human-review`, restarts. |
| **HALT-010** | `human_review_cycles >= MAX` (default 3) — the issue has cycled through `needs-human-review` more times than the operator-configured ceiling allows. | `needs-human-review`; cycle count logged; operator-escalation hook fires (if configured). | Operator considers whether the story should be cancelled, split, or re-shaped by `makato-plan`. |
| **HALT-011** | `shared/check-session-tail.sh` returned `verdict:"silent"` for a dispatched `build-*` sub-skill — the audit-tail guard (#175) saw a `step:"session" status:"start"` line but no matching terminal `session` line. Complements the sub-skill-side contract landed by #169 / PR #174: the sub-skill promises exactly one terminal `session` line per invocation; this HALT fires when that promise is broken. Origin file: `plugins/makato-orchestrate/agents/po-agent.md` § *Step 4d.1*. | `needs-human-review`; guard payload `{skill, last_step, last_status}` logged in `halt_audit[]`; worktree retained so the operator can read the truncated `build.jsonl` for forensics. | Operator inspects `specs/<key>-*/build.jsonl` to see where the sub-skill silently died (usually mid-turn drift, uncaught exception, or context ceiling inside a headless `claude -p`), decides whether to file a sub-skill contract fix or simply re-run `loop --autonomous <issue>`. |
| **HALT-STRUCTURAL** | A dispatched sub-agent returned R1 with `status: "failure"` and `data.escalation: "refine"`. | PO-agent re-dispatches `build-refine` once. If that also fails, escalates to HALT-008. | Same as HALT-008. |

## Why HALT-007 and HALT-007B are different codes

The original kill-switch design (issue #30, original AC list) coupled context-window degradation
and budget exhaustion under a single code. The proactive-handoff extension (2026-06-27) split
them because they require **different responses**:

- **HALT-007** (cost) — the operator must decide whether the work is worth more tokens. No
  amount of clever restart logic helps; only a human can answer.
- **HALT-007B** (quality) — the operator's input is irrelevant. The agent simply needs to start
  a fresh subprocess before its working memory degrades. Operators on unattended multi-hour
  runs should not be paged for what is, essentially, garbage collection.

The PO-agent applies the `needs-human-review` label only on HALT-007, never on HALT-007B.
Confusing these is a contract violation.

Because the two codes read the **same** `budget_consumed_tokens` counter, they must interpret
it differently (#281). HALT-007 (cost) is **cumulative** — it counts every token the run has
ever spent, and must never be reset or a runaway task would evade its budget ceiling. HALT-007B
(quality) is **per-session** — it only cares about tokens spent *since the current session
began*, so it evaluates the delta `budget_consumed_tokens - session_baseline_tokens`. Advancing
`session_baseline_tokens` to the cumulative total at each handoff resets that delta to 0 without
touching the cumulative counter, so a resumed session starts with a fresh context budget while
the cost ceiling keeps accruing. Resetting `budget_consumed_tokens` itself (the naive fix) would
have silently disabled the HALT-007 per-task and daily cost ceilings.

## Audit shape

Every HALT writes to `workflow-state.json` via `workflow-state.sh patch`:

```json
{
  "halt_audit": [
    {
      "code": "HALT-007B",
      "ts": "2026-06-28T14:23:01.456Z",
      "data": {
        "budget_consumed_tokens": 152340,
        "session_baseline_tokens": 0,
        "session_delta_tokens": 152340,
        "context_warn_tokens": 150000,
        "resume_point": "task:7",
        "session_count": 2,
        "session_summary_chars": 1847
      }
    }
  ]
}
```

The same event is appended to `specs/<key>-<slug>/orchestrate.jsonl`:

```json
{"ts":"2026-06-28T14:23:01.456Z","skill":"kill-switch","issue":30,"step":"halt","status":"warn","data":{"halt_code":"HALT-007B","session_count":2},"error":"context_warn_tokens reached — handoff initiated"}
```

The dual write is intentional: `workflow-state.json` is the live state the next session reads;
`orchestrate.jsonl` is the immutable audit trail across sessions.

## See also

- `plugins/makato-orchestrate/never-patterns.md` — the 9 universal NEVER rules.
- `plugins/makato-orchestrate/skills/kill-switch/SKILL.md` — implementation of HALT-000, HALT-007, HALT-007B, HALT-009.
- `plugins/makato-orchestrate/skills/resolve-pr-conflict/SKILL.md` — implementation of the HALT-008 merge-conflict origin (GAP-016 / #45).
- `plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json` — schema for `halt_audit[]` and the `merge_conflict_cycles` counter.
- `plugins/makato-build/skills/build-resolve-finding/SKILL.md` — HALT-adjacent per-finding repair logic.
- `plugins/makato-change/AUTONOMOUS-MODE.md` § *HALT codes* — **authoritative** source for HALT-CH-001 … HALT-CH-004; the table above mirrors it.

---

## makato-change autonomous path — HALT-CH-* codes

The `makato-change` plugin runs a four-phase pipeline: **analyze → design → execute → resolve-review**.
When invoked with `--autonomous`, the `orchestrate` skill drives the first three phases headlessly;
`resolve-review` is **excluded from autonomous mode** (it requires human judgement on PR feedback —
see `plugins/makato-change/AUTONOMOUS-MODE.md` § *Skills NOT in scope*). HALT-CH codes enumerate every
non-success exit path across those autonomous phases.

> **Single source of truth.** The authoritative definitions of HALT-CH-001 … HALT-CH-004 live in
> `plugins/makato-change/AUTONOMOUS-MODE.md` § *HALT codes*, and the skills that emit them
> (`analyze`, `design`, `execute`) are the ground truth. This table mirrors that contract for
> operators reading the orchestrate-side HALT reference; if the two ever diverge, AUTONOMOUS-MODE.md
> wins and this table is the bug.

The same category distinction as the PO-agent table applies, refined to the three severities the
change pipeline actually emits:

| Category | Severity | Meaning | `change-state` `halt_audit` written? | Issue labelled `needs-human-review`? |
|----------|----------|---------|--------------------------------------|--------------------------------------|
| **Hard stop** | `failure` | Phase cannot advance without human input. | **Yes** | **Yes** |
| **Audit** | `audit` | Notable autonomous default was taken; run continues. | **Yes** | **No** |
| **Degraded** | `degraded` | Phase completed with reduced confidence; run continues, PR flagged for elevated scrutiny. | **Yes** | **No** |

### Code table

| Code | Severity | Phase | Trigger | Recovery action |
|------|----------|-------|---------|-----------------|
| **HALT-CH-001** | `failure` | analyze | Headless repository discovery failed: `REPO_ROOT` is not in the dispatch context bundle **and** `repositories.yml` does not exist, so `analyze` cannot resolve the target repo without a human answering the `AskUserQuestion` repo prompt. | Emit R1 `status: "failure"` with `data.halt_code: "HALT-CH-001"`; write the blocking detail to `specs/<issue-key>/deferred-questions.md`; write a `halt_audit` entry (`code: "HALT-CH-001"`, `phase: "analyze"`) to `change-state.json`; apply `needs-human-review`. Operator supplies `REPO_ROOT` (or commits `repositories.yml`) and re-invokes `orchestrate --autonomous`. |
| **HALT-CH-002** | `failure` | analyze | A **critical blocking** open question surfaced in `analyze` Step 8 — the `requirements-diff-analyzer` classified a question as `blocking: true` and a downstream design step cannot proceed without the answer. Non-critical questions do NOT fire this code; they are written to `deferred-questions.md` and the run continues. | Emit R1 `status: "failure"` with `data.halt_code: "HALT-CH-002"` and `data.blocking_questions: [...]`; append each critical question to `specs/<issue-key>/deferred-questions.md` under `## Critical Blocking Questions (HALT-CH-002)`; write a `halt_audit` entry (`phase: "analyze"`) to `change-state.json`; apply `needs-human-review`. Operator answers the blocking questions (updates the issue body or linked spec) and re-invokes `orchestrate --autonomous`. |
| **HALT-CH-003** | `audit` | design | The `design` skill auto-approved its design in autonomous mode (the interactive Step 10 approval gate was bypassed). This code is an **audit marker, not a failure** — the run proceeds; the GitHub Issues post is conditional on `MAKATO_CHANGE_POST_DESIGN=1`. | Log an `autonomous_bypass` entry to `change.jsonl` and write a `halt_audit` entry (`code: "HALT-CH-003"`, `phase: "design"`, `informational: true`) to `change-state.json`. No `needs-human-review` label. No R1 failure. The entry lets a reviewer identify every auto-approved design run. |
| **HALT-CH-004** | `degraded` | execute | The `execute` skill found **no test infrastructure** in the target repo during a headless run (the interactive Step 3 prompt was bypassed). The skill does NOT halt — a test-less implementation is preferable to a stalled run. | Do NOT halt. Set `data.degraded_confidence: true` and `data.no_test_infrastructure: true` in the execute R1; log the HALT-CH-004 signal to `change.jsonl`; write a `halt_audit` entry (`code: "HALT-CH-004"`, `phase: "execute"`, `informational: true`) to `change-state.json`. No `needs-human-review` label. The `no_test_infrastructure` flag signals the PO-agent to route the resulting PR for elevated human scrutiny after creation. |

### Audit shape

Every HALT-CH-* code writes to `change-state.json` (the `makato-change` analogue of
`workflow-state.json`) via the shared state helper:

```json
{
  "halt_audit": [
    {
      "code": "HALT-CH-001",
      "ts": "2026-07-09T10:00:00.000Z",
      "phase": "analyze",
      "data": {
        "errors": ["HALT-CH-001: REPO_ROOT required in headless mode"]
      }
    }
  ]
}
```

HALT-CH-003 (`audit`) and HALT-CH-004 (`degraded`) entries are written to `halt_audit[]` with
`informational: true` to distinguish them from the hard-stop `failure` codes (HALT-CH-001,
HALT-CH-002) when the operator scans the audit trail.
