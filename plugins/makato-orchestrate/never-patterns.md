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
- `.claude/state/resume-{KEY}.sh` (via `context-handoff.sh`)
- `.claude/state/daily-budget-{YYYY-MM-DD}.json` (via `kill-switch`)

**Enforcement**: PO-agent frontmatter must set `disallowedTools` to deny `Edit` and `Write`
on any path outside the allow-list above.
**HALT code**: N/A — this is a frontmatter contract, not a runtime check. A PR that loosens
the disallowedTools list violates the AGENTS.md security model and must be rejected.

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

## See also

- `plugins/makato-orchestrate/halt-conditions.md` — the full HALT-code table.
- `plugins/makato-orchestrate/AGENTS.md` § Security Model — the PO-agent permission contract.
- `plugins/makato-build/agents/RETURN-CONTRACT.md` — the R1 envelope every sub-agent emits.
