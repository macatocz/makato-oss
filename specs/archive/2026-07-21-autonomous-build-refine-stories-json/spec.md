# Spec: Autonomous build-refine — materialize full-tier plans from committed stories.json

> **Status:** draft — brainstormed design, pending review.
> **Domain:** makato-orchestrate (cross-plugin: makato-build, makato-plan).
> **GitHub issue:** macatocz/makato#527
> **Scope:** the autonomous lane (loop / po-agent) plan-materialization gate.
> **NOT in scope:** the interactive lane (`build-start` → interactive
> `build-refine`) stays byte-for-byte; the plan.md-singleton work of #499.

## Problem

When `/loop` (or a direct po-agent dispatch) hits a **full-tier** issue with no
`plan-<N>.md`, the po-agent HALTs (HALT-006 → needs-human-review) instead of
building the plan itself. In autonomous mode the po-agent should not be
"surprised" that the plan is missing — it should materialize it from the
**committed** `stories.json` via `build-refine --autonomous`, which needs no
interactive content questions. Interactive work keeps its own entry point
(`build-start` → interactive `build-refine`), so the autonomous lane never
blocks on a human.

## Findings (verified in code v0.101.0 + on disk)

1. **`stories.json` IS committed** in sagibeast
   (`specs/platform-core-phase-1/stories.json`, 80 KB, tracked) → survives a
   fresh clone/worktree. **Caveat (new):** in the *makato* repo itself
   `specs/**` is gitignored (`.gitignore:175`, only `!spec.md`/`!build.jsonl`
   escape). So the "commit stories.json" prerequisite is **per-consumer** and
   depends on that repo's gitignore policy — see Phase C.
2. **`build-refine` already builds a plan FROM `stories.json`** (Step 3 ticket
   path: matches key, AC from `description.successScenarios[]`, oracle from
   `acceptanceTestCases[]`, writes `plan-<N>.md` in Step 10). It does **not**
   synthesize from the issue body and does **not** ask about content.
3. **Both interactive gates are ALREADY resolved in autonomous mode**
   (`AUTONOMOUS-MODE.md`): Step 1 work-item-key = use arg or HALT
   `MISSING_INPUT`; Step 11 plan-review = write plan, skip review, log
   `autonomous_bypass`. There is **no "second planning"** — key is *identity*,
   plan-review is *output-control*; neither asks about content.
4. **The only gap:** po-agent Step 1a never calls `build-refine` for full-tier.
   `should-materialize-spec.sh` returns `materialize` only for `plan-tier:light`
   (→ light-planner from issue body); full-tier → `halt`.

## Relationship to makato#499 (closed)

#499 **rejected** "wire build-refine into po-agent Step 1a auto-materialize"
with: *"build-refine consumes stories.json … on a fresh clone it just relocates
the failure to MISSING_ARTIFACTS."* That rejection **assumed stories.json is not
committed**. Where a consumer commits it (sagibeast), the assumption fails and
the build-refine path is valid. #499 itself solved a *different* problem
(plan.md singleton vs. N issues; opt6 per-issue filename + opt5 substantive plan
+ opt11 fingerprint) — this spec **consumes** its per-issue `plan-<N>.md`
contract, it does not re-author it.

## Decision table — `should-materialize-spec.sh` (final)

Priority top-down, first match wins:

| # | Condition | Verdict | Engine |
|---|---|---|---|
| 1 | `plan-<N>.md` valid | `proceed` | — |
| 2 | missing/stub plan **AND** stories.json has entry with matching key | `materialize-refine` | `build-refine --autonomous <KEY>` |
| 3 | missing/stub plan **AND** `plan-tier:light` (no matching key) | `materialize` | light-planner (unchanged) |
| 4 | otherwise | `halt` | HALT-006 → needs-human-review (unchanged) |

Row 2 precedes row 3 (stories.json is the richer, authoritative source).
Key-miss in stories.json → resolve **by tier**: light → `materialize`, full →
`halt` (preserves today's human-shaping gate for full-tier without a stories
entry).

## Decisions (confirmed)

1. Route on **presence of a committed `stories.json` with a matching key**, not
   on the `plan-tier` label.
2. New separate verdict `materialize-refine` (not a param on `materialize`) —
   explicit audit trail in `build.jsonl`.
3. Key-miss handled **by tier** (light → light-planner, full → HALT-006).
4. **Guard now:** `to-issues` fails when stories.json is untracked after write
   (source); `should-materialize-spec.sh` warns on untracked stories.json and
   degrades to the tier fallback (consumer).

## Phases

- **A — po-agent Step 1a + `should-materialize-spec.sh`:** new `materialize-refine`
  verdict; sub-flow dispatches `build-refine --autonomous <KEY>` (uses exported
  `$AGENT_ID` to bypass both gates), forwards `WORKTREE_PATH`, bounded once,
  re-validates via `validate-plan-body.sh`, retries Step 1.
- **B — build-refine ticket-path autonomous cleanliness:** verify no
  `AskUserQuestion` beyond the bypassed Step 1/Step 11; Step 3 "confirm the key"
  branch takes autonomous default **HALT** (never prompt) on key-miss.
- **C — to-issues commits stories.json + guard:** `git add` stories.json +
  created-issues.json; fail on untracked. **Resolved:** makato's own `specs/**`
  gitignore blocks these artifacts, so this phase adds a `!specs/**/stories.json`
  (and `!specs/**/created-issues.json`) negation to makato's `.gitignore`
  immediately after the existing `!specs/**/spec.md` / `!specs/**/build.jsonl`
  escapes (`.gitignore:175-178`). The negation must sit after `specs/**` and the
  `!specs/**/` directory-descent escape (line 176), or Git will not reach the
  file. This makes the autonomous stories.json path work in makato itself, not
  just sagibeast — the prerequisite becomes repo-policy, not a per-consumer
  accident.
- **D — interactive lane unchanged (confirmation).**
- **E — tests + docs:** four-row gate tests, key-miss HALT test, to-issues
  commit/guard test, regression for light + full-without-stories;
  `AUTONOMOUS-MODE.md` documents `materialize-refine`.

## Acceptance criteria

- [ ] `should-materialize-spec.sh` returns `materialize-refine` per the table; tests cover all four rows.
- [ ] po-agent Step 1a dispatches `build-refine --autonomous <KEY>` on `materialize-refine`, bounded once, re-validated, then retries.
- [ ] Key-miss resolves by tier (light → light-planner, full → HALT-006).
- [ ] `build-refine` Step 3 autonomous key-miss HALTs (never prompts).
- [ ] `to-issues` git-adds stories.json + created-issues.json and fails when untracked; makato `.gitignore` gains `!specs/**/stories.json` + `!specs/**/created-issues.json` negations (after the `!specs/**/` descent escape) so the artifacts are trackable in makato itself.
- [ ] `should-materialize-spec.sh` warns on untracked stories.json and degrades to tier fallback.
- [ ] `AUTONOMOUS-MODE.md` documents the `materialize-refine` verdict and precedence.
- [ ] Regression: light-tier and full-tier-without-stories paths byte-for-byte unchanged.
- [ ] CHANGELOG entries for makato-orchestrate, makato-build, makato-plan.
