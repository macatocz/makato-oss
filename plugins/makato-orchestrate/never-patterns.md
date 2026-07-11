# NEVER Patterns — makato-orchestrate

> **Authoritative reference.** These nine rules describe behaviour that is **categorically
> prohibited** in autonomous mode. Every rule has a HALT code attached — if a PO-agent or
> sub-agent appears to be approaching any of these, the HALT must fire instead of the action.

The list is intentionally short. Specific guardrails live in each skill's own SKILL.md; this
file lists only the rules that are **universal across every skill and agent** in the
autonomous control plane.

---

## NEVER 1 — Never bypass the pre-commit gate

Pre-commit is the fast-lane hygiene check. Every commit produced in autonomous mode must pass
it. The PO-agent and its sub-agents must never:

- Invoke `git commit --no-verify`.
- Set `SENSOR_HARNESS_DISABLE=1` (the emergency-bypass env var is reserved for human operators
  on hotfix runs and is logged whenever it fires).
- Re-stage auto-fixed files and immediately re-attempt the same commit without dispatching
  `sensor-fixer`.

**Enforcement**: `plugins/makato-build/hooks/pre-commit-sensors.md` is wired as a `PreToolUse`
hook with `blocking: true`. A failing pre-commit run blocks the tool call entirely.
**HALT code**: HALT-001 (after MAX_LOOPS=5 sensor-fixer attempts).

---

## NEVER 2 — Never force-push to the default branch

`git push --force` (or `--force-with-lease`) targeting `main` (or the configured default
branch) is unconditionally banned. The PO-agent operates only on feature branches; the default
branch is updated exclusively through merged PRs.

**Enforcement**: The repo's pre-push deny-list rejects force-push to `main`. The PO-agent's
own dispatch logic never constructs such a command.
**HALT code**: HALT-005.

---

## NEVER 3 — Never skip the HALT-file check

The HALT-file (`~/.claude/HALT`) is the universal kill-switch. Every PO-agent outer-loop
boundary and every PreToolUse on `Bash` runs `hooks/check-halt.sh`. The agent must never:

- Cache a "no HALT file present" result and skip subsequent checks.
- Run a long-running tool call without the PreToolUse poll in front of it.
- Continue dispatching sub-agents after `check-halt.sh` returned non-zero.

**Enforcement**: `hooks/check-halt.sh` is a PreToolUse hook on `Bash` with `blocking: true`.
**HALT code**: HALT-000.

---

## NEVER 4 — Never edit target-repo source files from the PO-agent

The PO-agent is an **orchestrator**, not an implementer. It dispatches `coder` (in
`makato-build`) for every source-file mutation. The PO-agent's own `Write`/`Edit` tool calls
are restricted to:

- `specs/<key>-<slug>/workflow-state.json` (via `workflow-state.sh`)
- `specs/<key>-<slug>/orchestrate.jsonl` (via `orchestrate-log.sh`)
- `specs/<key>-<slug>/plan.md` + `seed-manifest.json` — **Step 1a HALT-006 auto-materialize
  only** (#200): the seed stub written before dispatching `light-planner`, and the
  `spec_tier:plan-only` stamp on a guard-valid plan. Both under gitignored `specs/`; the
  plan body is written by the `light-planner` agent, not the PO-agent.
- `.claude/state/resume-{KEY}.sh` (via `context-handoff.sh`)
- `.claude/state/daily-budget-{YYYY-MM-DD}.json` (via `kill-switch`)

**Enforcement**: `disallowedTools` in agent frontmatter is currently all-or-nothing — it
denies a tool entirely or not at all; there is no path-scoped denial. Because the PO-agent
legitimately needs `Write`/`Edit` to mutate the five allow-listed files above, those tools
CANNOT be in `disallowedTools`. The boundary is enforced instead by:

1. **Behavioural rule** — the agent's `po-agent.md` Permission Boundary section documents
   the allow-list verbatim, and the agent SHOULD NOT write outside it.
2. **Code review** — a PR that adds a `Write` or `Edit` against a target-repo source path
   from this agent's process must be rejected here, in `AGENTS.md`'s Security Model, and
   in `po-agent.md`'s Permission Boundary — all three locations explicitly forbid it.
3. **Frontmatter does still set** `disallowedTools: NotebookEdit` (notebook edits are not
   a legitimate orchestrator concern, and the explicit denial doubles as a regression
   marker — if this list ever grows, reviewers know to check the new entry against the
   allow-list).

**HALT code**: N/A — this is a contract enforced at PR review time, not at runtime. A PR
that adds source-path writes to the PO-agent violates the AGENTS.md security model and
must be rejected.

---

## NEVER 5 — Never write to `workflow-state.json` from a sub-agent

PO-agent is the sole writer of state. Sub-agents (`coder`, `diff-reviewer`, `gate-scout`,
`knowledge-scout`, `plan-analyst`, `context-summariser`, etc.) return R1 envelopes; the
PO-agent translates R1 into state patches.

The single documented exception is `build-implement-tdd`'s narrow guarded patch on task
completion (see `workflow-state` SKILL.md § *Cross-plugin caller*). That carve-out exists
because `build-implement-tdd` already lives inside a coder dispatch — putting the patch in the
PO-agent would require a round-trip after every task that's not worth the latency.

Concurrent writes are a design failure, not a race to manage. Two writers means a torn state
file. If a new use case appears to need a second writer, route it through the PO-agent.

**Enforcement**: Sub-agent frontmatter `disallowedTools` denies `Bash` (except for `coder` and
the narrow `build-implement-tdd` carve-out documented above).
**HALT code**: N/A — frontmatter contract.

---

## NEVER 6 — Never silently ignore an R1 contract violation

If a sub-agent returns output without a parseable R1 block as the last fenced `json` block,
the PO-agent must treat that dispatch as `status: "failure"` with
`errors: ["R1 contract violation: <reason>"]` and persist it to state. Specifically:

- Do not retry the dispatch hoping for a better-formatted response.
- Do not scrape prose to reconstruct what the agent "meant".
- Do not silently move on to the next task.

**Enforcement**: Every PO-agent dispatch path parses the last `json` block per
`plugins/makato-build/agents/RETURN-CONTRACT.md` § Caller parsing rule.
**HALT code**: HALT-STRUCTURAL (after one re-dispatch of `build-refine`).

---

## NEVER 7 — Never exceed the daily token budget

If `MAKATO_DAILY_TOKEN_BUDGET` is set, the per-day cumulative token count tracked in
`.claude/state/daily-budget-{YYYY-MM-DD}.json` is a **hard ceiling**. The PO-agent must never:

- Continue dispatching after the ceiling is reached.
- "Round up" to a slightly higher number to finish a task.
- Move tokens between days to fit under the per-day ceiling.

The daily ceiling is a cost-control. The right response when it fires is HALT-007 — let the
operator decide whether to raise the ceiling or write off the work.

**Enforcement**: `skills/kill-switch/` reads the daily-budget file at every outer-loop
boundary.
**HALT code**: HALT-007.

---

## NEVER 8 — Never restart a session after HALT-007B more than MAKATO_MAX_HANDOFFS times

The proactive context-ceiling handoff exists so unattended runs don't degrade. It is **not** a
license to run indefinitely. After `session_count >= MAKATO_MAX_HANDOFFS` (default 5),
context-handoff.sh refuses to spawn a new subprocess and instead fires HALT-007 — the operator
must intervene.

This rule exists because:

- An infinite handoff loop would be indistinguishable from a runaway process from outside.
- After 5 handoffs the task is consuming `5 × context_warn_tokens` = ~750k tokens. That's
  budget-control territory, not quality-control territory.

**Enforcement**: `scripts/context-handoff.sh` reads `session_count` from `workflow-state.json`
before initiating handoff.
**HALT code**: HALT-007.

---

## NEVER 9 — Never apply `needs-human-review` on a HALT-007B handoff

The distinction between HALT-007 (cost, labelled) and HALT-007B (quality, unlabelled) is the
hinge of the proactive-handoff design. Applying `needs-human-review` on a HALT-007B handoff
would page the operator on an event that is, by design, fully automatic.

Specifically:

- `context-handoff.sh` exits with status `HANDOFF`, not `HALT`.
- It calls `workflow-state.sh patch` to set `handoff_reason: "context_ceiling"` and increment
  `session_count`, but does NOT increment `human_review_cycles`.
- It does NOT call `gh issue edit --add-label needs-human-review`.

**Enforcement**: Code review. The HALT-007 fallback path (when `restart_failed: true` or
`session_count >= MAKATO_MAX_HANDOFFS`) DOES apply the label — that is a HALT-007 event, not
a HALT-007B event.
**HALT code**: N/A — this is a behavioural rule about the absence of an action.

---

## NEVER 10 — Never create branches from the PO-agent process

The PO-agent must never run `git checkout -b`, `git branch <name>`, or any other command
that materialises a feature branch. Branch creation is delegated exclusively to
`plugins/makato-orchestrate/shared/worktree.sh create --new-branch`, which uses
`git worktree add -b <BRANCH> <path> origin/<default>` to create the branch and its
worktree atomically **without** touching the main-repo working tree.

The historical failure mode this rule closes is documented in #170: when `loop.sh` dispatched
the PO-agent for a fresh issue whose branch did not yet exist, the agent's model
self-repaired by running `git checkout -b feat/<N>-<slug>` in the main repo, then
`git worktree add` failed with `branch already used by worktree at <REPO_ROOT>`, and the
agent bypassed the failure by patching `.worktree_path` to the main-repo root. The main
repo was left on a feature branch, worktree isolation was destroyed, and the audit log
carried a fabricated `worktree_created` event pointing at the main checkout.

The rule has three layers of enforcement:

1. **Behavioural** — the PO-agent's Rules section forbids inline branch creation. Step 2b
   probes the remote via `git ls-remote origin $BRANCH` and dispatches
   `worktree.sh create --new-branch` when the branch is missing.
2. **Helper** — `worktree.sh create --new-branch` runs the atomic worktree/branch add, so
   even a caller that misunderstands the contract cannot corrupt the main checkout.
3. **State** — `workflow-state.sh patch` refuses `.worktree_path` writes to any path that
   is not a registered git worktree of this repo (bypass:
   `MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1`, tests only). The layer-3 guard blocks the
   deceptive-audit failure mode even if a future caller ignores layers 1 and 2.

**Enforcement**: layered as above.
**HALT code**: HALT-006 when `worktree.sh create --new-branch` itself fails (e.g. remote
base ref missing). Inline branch creation from within the PO-agent process is a contract
violation with no runtime HALT — it is caught at PR review time (like NEVER 4).

---

## NEVER 11 — Never start `loop.sh run` without acquiring the pidfile mutex

**Rule**: `loop.sh run` must not write to `.claude/state/loop-status.json` before
acquiring `.claude/state/loop.pid` (or the `MAKATO_LOOP_PIDFILE` override). A live
pidfile — PID responds to `kill -0` — refuses the second invocation with exit code 3
and leaves the file untouched. Stale pidfiles are reclaimed silently; `--force`
`SIGTERM`s (then `SIGKILL`s after `MAKATO_LOOP_FORCE_GRACE`) the incumbent before
taking over.

**Why**: Traced to #172. On 2026-07-08 an operator started
`plugins/makato-orchestrate/scripts/loop.sh run --status Ready --interval 600` at
01:50 CEST. Six hours later a second instance was discovered running from the
plugin cache
(`~/.claude/plugins/cache/makato-suite/makato-orchestrate/ca8b02a2807f/scripts/loop.sh`)
with default arguments. Both wrote to the same `loop-status.json`, both consumed the
same `specs/` tree for in-flight filtering, and both had dispatched PO-agents against
the shared repo working tree. The 35× repeated `dispatching #145` in the operator's
log had a mirror in the plugin-cache log at the same cadence — six hours of network
and token spend on a run whose audit trail could not be trusted.

**Consequences of a second concurrent instance**:

- Race on `active_workflow` — either loop can flip it, and the loser's PO-agent
  dispatch runs with no state ownership.
- Race on `queue` / `queue_depth` / `last_poll` — either loop overwrites the other's
  poll snapshot atomically, so the audit becomes non-deterministic.
- Two PO-agents in the same repo working tree — NEVER 10 already forbids the inline
  branch creation that #170 relied on, but shared-tree contention across
  `workflow-state.json` in `specs/` remains a design failure.

**Layered defence**:

1. **Mutex** — `cmd_run` writes `$$` to `$PIDFILE` after checking that any existing
   entry names a dead PID; an `EXIT` trap removes the file on clean shutdown.
2. **Audit** — the same startup path stamps `startup_audit` into `loop-status.json`
   (`script_path` canonicalised, `pid`, `ppid`, `pidfile`, CLI args) so a `ps`
   sighting of multiple `loop.sh` processes can be cross-referenced to the state file.
3. **Escape hatch** — `--force` for operators who confirm the incumbent is stuck;
   cooperative `kill -TERM <pid>` is still preferred because the incumbent's own
   `EXIT` trap gets to clean up its pidfile.

**Enforcement**: layered as above. Bypassable only by pointing two invocations at
different `MAKATO_LOOP_PIDFILE` paths, which is the correct behaviour when the
operator genuinely wants two loops against two state dirs.

**HALT code**: none — the failure mode is refuse-to-start with exit 3, not a
mid-run HALT. Configuration mismatch (plugin-cache script vs. working-tree script)
is caught at operator-observation time via the exit code and `startup_audit` fields.

---

## See also

- `plugins/makato-orchestrate/halt-conditions.md` — the full HALT-code table.
- `plugins/makato-orchestrate/AGENTS.md` § Security Model — the PO-agent permission contract.
- `plugins/makato-build/agents/RETURN-CONTRACT.md` — the R1 envelope every sub-agent emits.
