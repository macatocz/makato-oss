# daff → makato-oss Upstream Improvement Plan

> **Source:** `DCP/daff:main` commits not yet in `impact/impact-market:main`
> **Analysed:** 15 commits (opencode + daff-compass excluded)
> **Date:** 2026-09-25
> **Status:** DRAFT — pending prioritisation

---

## Context

makato-oss was forked from daff. The plugin/skill mapping is:

| daff | makato-oss |
|------|-----------|
| `daff-shape` | `makato-plan` |
| `daff-core` | `makato-core` |
| `daff-build` | `makato-build` |
| `daff-cr` | `makato-change` |

The items below are grouped by impact tier. Each item carries:

- **Effort** — S / M / L
- **Harness-independent** — whether it requires hooks or Node.js infra
- **Affected plugins** — which `plugins/<name>/` directories are touched
- **Dependencies** — which other items must land first

---

## Tier 1 — Token Reduction

### S1 · Point-of-use loading in `makato-plan`

| | |
|---|---|
| **Source commit** | `cd645cc` `refactor(daff-shape): move reference-heavy content to point-of-use loading` |
| **Effort** | M |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-plan` |
| **Dependencies** | None |

#### Problem

~301 lines of static reference content (interview protocols, slicing tables, architecture steps,
dispatch compression tables) are front-loaded into the initial prompt on every invocation of the
five opus-tier skills. This wastes context window on every call, even for steps that never reach
the section needing that content.

#### What to do

For each of the five skills below, extract large inline blocks into a `references/<name>.md` file
and replace with a `@references/<name>.md` load directive placed **at the step that actually
needs it**:

| Skill | Blocks to extract | Estimated lines saved |
|---|---|---|
| `brainstorming` | Interview protocol, round-trigger table | ~70 |
| `create-prd` | UI scope signals, dispatch compression table | ~80 |
| `create-architecture` | Architecture interview steps | ~60 |
| `decompose` | Story template, vertical-slicing rules | ~55 |
| `create-prototype` | HTML review structure | ~36 |

#### Steps

1. For each skill, open `SKILL.md` and identify large static blocks (>20 lines) not used in Step 1.
2. Move block to `<skill>/references/<block-name>.md`.
3. Replace inline block with `@references/<block-name>.md` at the step that first uses it.
4. Clean information about historic changes from the original `SKILL.md` files (like information in which version a block was added).
5. Run the skill once in a real session and confirm the reference is loaded at the right step (no behavioral regression).
6. Add smoke test confirming reference file exists when `SKILL.md` references it.

#### Acceptance criteria (S1)

- Each modified `SKILL.md` is ≤ 50% of its previous line count.
- No behavioral change: the information available to the model at each step is identical.
- `references/` files follow the canonical layout in `standards/patterns.md`.

---

### S2 · `maxTurns` caps on all agents

| | |
|---|---|
| **Source commit** | `b4da0b6` `perf(daff-fix): bound agents, tier fix-reviewer to sonnet` |
| **Effort** | S |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-build`, `makato-change` |
| **Dependencies** | None |

#### Problem (S2)

`coder` (makato-build) has `bypassPermissions` with no turn limit. All other agents are also
uncapped. A stuck agent burns tokens indefinitely before the HALT mechanism fires.

#### What to do (S2)

Add `maxTurns:` to every agent's frontmatter. Recommended starting values (tune up based on logs):

| Agent | Plugin | Tier | Recommended `maxTurns` |
|---|---|---|---|
| `coder` | makato-build | large | 30 |
| `diff-reviewer` | makato-build | large | 20 |
| `sensor-fixer` | makato-build | large | 20 |
| `knowledge-scout` | makato-build | small | 10 |
| `plan-analyst` | makato-build | small | 10 |
| `gate-scout` | makato-build | small | 10 |
| `runtime-qa` | makato-build | small | 15 |
| `code-explorer` | makato-change | small | 10 |
| `test-analyzer` | makato-change | small | 10 |
| `requirements-diff-analyzer` | makato-change | large | 20 |
| `quality-guard` | makato-change | small | 10 |
| `code-reviewer` | makato-change | large | 20 |
| `change-implementer` | makato-change | large | 30 |
| `context-scout` | makato-plan | small | 10 |
| `dev-reviewer` | makato-plan | large | 20 |
| `po-reviewer` | makato-plan | large | 20 |
| `qa-reviewer` | makato-plan | large | 20 |

#### Steps (S2)

1. Add `maxTurns: <N>` to each agent's YAML frontmatter.
2. Verify no existing tests rely on unlimited turn counts.
3. Run one full `build-implement-tdd` story and confirm the cap does not fire prematurely.
4. Document tune-up procedure in `makato-build/AGENTS.md`.

#### Acceptance criteria (S2)

- All agents have `maxTurns` in frontmatter.
- A HALT code (e.g. `MAX_TURNS_REACHED`) is emitted if the cap is hit, not a silent stop.
- No regression in a standard end-to-end story run.

---

## Tier 2 — Contract Standardisation

### S3 · Unified reviewer finding schema

| | |
|---|---|
| **Source commit** | `bf267ac` `feat(daff-core): standardize reviewer finding schema across fix/build/cr plugins` |
| **Effort** | L |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-core` (new contract), `makato-build`, `makato-change`, `makato-plan` |
| **Dependencies** | None (but coordinate with makato-orchestrate PO-agent update) |

#### Problem (S3)

Three reviewer agents, three output shapes:

- `diff-reviewer` (makato-build): formal R1 `data` schema, verdict in `status` field.
- `code-reviewer` (makato-change): prose markdown, no JSON envelope, no machine-parseable verdict.
- Three Amigos reviewers (makato-plan): prose only, no schema.

The PO-agent must use brittle regex to parse reviewer output. Cross-plugin verdict comparison is
impossible.

#### What to do (S3)

1. **Create `makato-core/contracts/reviewer-finding-schema.md`** defining:

   ```text
   Severity tiers: CRITICAL | MAJOR | SUGGESTION | NITPICK
   Verdicts:       APPROVED | APPROVED WITH SUGGESTIONS | REQUIRES CHANGES
   Finding fields: severity, file, line, category, description, evidence
   Verdict rules:
     - CRITICAL present                   → REQUIRES CHANGES
     - MAJOR present, no CRITICAL         → APPROVED WITH SUGGESTIONS
     - Only SUGGESTION/NITPICK or none    → APPROVED
   ```

2. **Update `diff-reviewer` (makato-build):**
   - Rename `MAJOR` → `SUGGESTION`, `MINOR` → `NITPICK` in output (match new schema).
   - Replace `status: approved | changes_required` with `**Verdict**: <value>` bold field at top.
   - Remove `DESIGN_DEVIATION` tier; move informational design notes to `## Design Notes`.
   - Keep R1 `data` fields: update `critical_count`, `major_count` → `suggestion_count`, `nitpick_count`.

3. **Update `code-reviewer` (makato-change):**
   - Add `**Verdict**: <value>` bold field at top of output.
   - Adopt severity tiers from schema.
   - Note: no R1 envelope yet in makato-change — this is a precursor for adding it.

4. **Add schema reference to Three Amigos agents (makato-plan):**
   - `dev-reviewer`, `po-reviewer`, `qa-reviewer` load `@makato-core/contracts/reviewer-finding-schema.md`
     — **NO** — cross-plugin file loads violate golden rules.
   - Instead: copy the severity rubric into `makato-plan/shared/reviewer-finding-schema.md` and load locally. The canonical source remains in `makato-core/contracts/`.

5. **Update PO-agent (makato-orchestrate):** Update verdict parsing to handle the new `**Verdict**:` field.

> ⚠️ **Breaking change on `diff-reviewer`** — version bump required; update `build-review/SKILL.md` verdict parsing.

#### Acceptance criteria (S3)

- `makato-core/contracts/reviewer-finding-schema.md` exists and is referenced in `makato-core/AGENTS.md`.
- `diff-reviewer` and `code-reviewer` output `**Verdict**: <one of three values>` as the first bold
  line.
- PO-agent successfully parses the verdict from a `build-review` run without regex hacks.
- All Three Amigos agents use the same severity terms.

---

### S4 · Auto-inject `model` field from session-start cache

| | |
|---|---|
| **Source commit** | `ad8b582` `feat(repo-wide): auto-inject model field in JSONL log scripts` |
| **Effort** | S |
| **Harness-independent** | 🟡 Requires `build-log.sh` update |
| **Affected plugins** | `makato-build/shared/build-log.sh`, `makato-change` (if it has own log script) |
| **Dependencies** | None |

#### Problem (S4)

`model` field is absent from `build-jsonl.md` schema and from most log entries. Agents with
hardcoded `"model":"sonnet"` in per-step log templates will log wrong model if the harness
changes the default.

#### What to do (S4)

1. In `build-log.sh`, on first call with `step:session, status:start`:
   - Write `model` value to `/tmp/makato-log-<plugin>-model-<md5(repoRoot+storyKey)>`.
2. On every subsequent call: if `model` key is absent in the passed JSON, inject the cached value.
3. Remove hardcoded `"model":"sonnet"` or `"model":"haiku"` from all per-step log templates in agents.
4. Add `model` as Required field in `makato-core/contracts/build-jsonl.md`.
5. Add CI check `scripts/check-no-hardcoded-model.sh` that fails if any `skills/**/*.md` or
   `agents/*.md` contains `"model":"haiku"` or `"model":"sonnet"` in a non-session-start template.

#### Acceptance criteria (S4)

- Every JSONL entry in a fresh `build.jsonl` run carries a `model` field.
- No agent file contains a hardcoded model name in a per-step template.
- `build-jsonl.md` lists `model` as Required.

---

### S5 · `QARefinement` label auto-apply

| | |
|---|---|
| **Source commit** | `4b71995` `feat(daff-shape): auto-apply QARefinement label to stories with Gherkin scenarios` |
| **Effort** | S |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-plan` (`decompose`, `to-issues`) |
| **Dependencies** | None (value increases once orchestrate acts on label) |

#### Problem (S5)

Stories with Gherkin in `successScenarios[]` are not labelled differently from stories without.
Downstream tooling (orchestrate, QA passes) cannot identify which stories need a QA refinement
pass.

#### What to do (S5)

1. In `decompose/SKILL.md` Step 7, substep 5 (new): after copying `qa-reviewer` Gherkin drafts to
   `successScenarios[]`, set `story.labels[] += "QARefinement"` for any story with non-empty
   `successScenarios`. Remove `QARefinement` for stories where it becomes empty (handles
   refinement-mode re-runs).
2. In `to-issues/SKILL.md` Step 8.2: before each `create_issue`/`update_issue`, compute
   `effectiveLabels` — merge `QARefinement` if `successScenarios` or `acceptanceTestCases` is
   non-empty. Safety net for legacy `stories.json` files.
3. Update `stories-json-schema.md` example `labels` to show `["makato", "QARefinement"]`.

#### Acceptance criteria (S5)

- Any story with a non-empty `successScenarios[]` has `QARefinement` in `labels[]` after `to-issues`.
- A story with empty `successScenarios[]` does NOT have the label.
- `stories-json-schema.md` example reflects the new convention.

---

### S6 · Decomposition guardrails for 5 anti-patterns

| | |
|---|---|
| **Source commit** | `f4bdea8` `feat(daff-shape): add decomposition guardrails for 5 anti-patterns` |
| **Effort** | S |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-plan` (`decompose`, Three Amigos agents) |
| **Dependencies** | None |

#### Problem (S6)

The decompose step can produce `stories.json` entries that are fundamentally unsound — test-only
stories, spike-as-stories, pure refactors — causing `makato-build` to HALT mid-loop because
stories don't map to deliverable code.

#### What to do (S6)

1. Add **5 hard-reject rules** to `decompose/SKILL.md` Step 3, firing before Three Amigos
   simulation:

   | Rule | Condition | Action |
   |---|---|---|
   | test-only | Story contains only test additions, no feature code | Merge into parent feature story |
   | value-conditional dependency | Removing `blockedBy` makes story pointless | Merge with blocker |
   | spike-as-story | Story is an investigation, not a deliverable | Move to `decisions.md` |
   | capability-driven | No user workflow outcome | Reframe or absorb into adjacent story |
   | pure-refactor | No new functionality, no bug fix | Remove from feature scope |

2. Extend `references/vertical-slicing-rules.md` anti-patterns table from current entries to
   include these 5 (with examples).
3. Add 1–2 FA items to each of `dev-reviewer.md`, `po-reviewer.md`, `qa-reviewer.md` that surface
   these as Major Concern during refinement mode.

#### Acceptance criteria (S6)

- A decompose run with a spike story results in a `decisions.md` entry, not a `stories.json`
  entry.
- `vertical-slicing-rules.md` covers all 5 anti-patterns with examples.
- Three Amigos reviewers flag anti-patterns during refinement mode with `Major Concern`.

---

### S8 · `build-coordinate-repos` skill

| | |
|---|---|
| **Source commit** | `3c22d7f` `feat(daff-build): add build-coordinate-repos skill for multi-repo story coordination` |
| **Effort** | M |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-build` (new skill + `build-push-to-git` update) |
| **Dependencies** | None |

#### Problem (S8)

Stories spanning multiple repos (e.g. infra + application + K8s) require manual PR coordination.
There is no supported skill for opening, cross-linking, and Jira-linking multiple PRs atomically.

#### What to do (S8)

1. Create `makato-build/skills/build-coordinate-repos/SKILL.md` implementing:
   - Pre-flight each repo: uncommitted changes check, feature branch check, `build-verify` gate
     scoped to that repo via `"repo":"<name>"` filter in `build.jsonl`, pushed check.
   - Optional integration verification step.
   - Open PRs per repo with user approval per repo; cross-link all PRs in description.
   - Link all PRs to Jira.
   - Post coordination comment listing all PR URLs.
   - Transition Jira ticket to In Review.
2. Create `references/pr-description-guide.md` with PR body template.
3. Update `build-push-to-git/SKILL.md` Step 8: detect `repos_pushed > 1` → route to
   `/build-coordinate-repos` instead of `/build-create-pr`.
4. Register in `skill-registry.json` (if applicable).

#### Acceptance criteria (S8)

- A two-repo story produces two PRs, each linking to the other in the description.
- Both PRs are linked to the Jira ticket.
- A coordination comment is posted on the Jira issue with all PR URLs.
- Single-repo stories are unaffected (still route to `/build-create-pr`).

---

### S9 · `analyze-log` skill in `makato-core`

| | |
|---|---|
| **Source commit** | `1a9101e` `feat(daff-core): add analyze-log skill` |
| **Effort** | M |
| **Harness-independent** | ✅ Yes |
| **Affected plugins** | `makato-core` (new skill) |
| **Dependencies** | S4 (model field) recommended before; S11 (token telemetry) for cost breakdown |

#### Problem (S9)

Debugging an autonomous run requires manually parsing raw JSONL. There is no supported skill to
render a human-readable audit report from `build.jsonl`.

#### What to do (S9)

1. Create `makato-core/skills/analyze-log/SKILL.md` that:
   - Accepts a story key or direct `.jsonl` path.
   - Renders: audit trail table (skill | outcome | duration | `↩` retry markers), per-phase time
     totals (refine / implement / simplify / review / verify / push / pr / change), token breakdown
     from `telemetry` entries, model distribution, deduplicated critical findings.
   - Matches sessions by name + timestamp order (not `session_id`, which rotates on reconnect).
   - Flags: `--since <date>`, `--save`, `--output <path>`, `--jira` (opt-in comment posting with
     explicit confirmation).
   - Deduplicates `critical-finding` entries.
2. Create `analyze-log/references/log-schema.md` documenting all JSONL entry types consumed.

#### Acceptance criteria (S9)

- Running the skill against a real `build.jsonl` produces an audit table with retry markers.
- `--jira` posts a comment only after explicit user confirmation.
- Skill fails gracefully with a clear message if the file does not exist.
