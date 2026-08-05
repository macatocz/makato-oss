# Workflow-State Field Quickref — Manual-Tier Assertions

**Load trigger:** MANDATORY when asserting Manual-tier items 3, 4, or 6 from
`workflow-state.json`. Not needed for items 1, 2, or 5.

Schema source:
`plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json`

---

## Fields used by Manual-tier assertions

### `outer_iteration` (integer, minimum 0)

Re-plan-and-retry counter. Incremented each time the PO-agent re-dispatches
`build-refine` + `build-implement-*` after a non-passing review or quality gate.

**Manual-tier item 3:** `outer_iteration < 3` (HALT-008 fires when `outer_iteration >= 3`).
Read directly from `workflow-state.json`; do NOT infer from build.jsonl step counts.

Distinct counters that also trigger HALT-008 (but are NOT checked by Manual-tier item 3):
- `merge_conflict_cycles` (default ceiling 3) — conflict-resolution budget
- `ci_failure_cycles` (default ceiling 3) — CI re-run budget

### `human_review_cycles` (integer, minimum 0)

Count of times the issue was labelled `needs-human-review` during this run.

**Manual-tier item 4:** `human_review_cycles < MAX`. Default `MAX = 3`; operator
can override via `MAKATO_MAX_HUMAN_REVIEW_CYCLES` (check `halt-conditions.md`
HALT-010 for the exact env var). Read directly from `workflow-state.json`.

### `skip-review` key in `makato.config.json`

Organization-level opt-in that satisfies Manual-tier item 6 without a GitHub reviewer
approval. The key must be **explicitly present and set to `true`** in `makato.config.json`
at the repo root. The key is not propagated into `workflow-state.json` — assert it by
reading `makato.config.json` directly.

Authorization chain for item 6:
1. `gh pr view --json reviewDecision` → `reviewDecision == "APPROVED"` → item 6 MET
2. `jq '.["skip-review"]' makato.config.json` → `true` → item 6 MET
3. Anything else (label, flag, commit message, `--autonomous` arg) → item 6 UNMET

---

## What this quickref does NOT cover

- `current_phase` field routing — see `skills/workflow-state/SKILL.md`
- Full schema with all required/optional fields — see the schema file directly
- HALT code payloads beyond items 3 and 4 — see `halt-conditions.md`
