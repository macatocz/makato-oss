# Changelog — makato-build

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## `grill-with-docs` skill

- **1.1.0**
  - Replace CONTEXT.md + context-snapshot.md with direct enrichment of `spec/<key>/glossary.md` (the feature vocabulary written by `/makato-plan:grill`); adds `_Code_:` annotations for codebase conflicts; removes repo-detection logic and per-story snapshot file — one glossary, one truth
  - `implement-tdd` and `implement-goal` updated to read `glossary.md` instead of `context-snapshot.md`
  - `context-md-format.md` reference updated to describe glossary enrichment (entry annotation rules, `_Code_:` format, purity rules)
- **1.0.0**
  - Initial — aligns implementation plan terminology to the codebase domain model; probes codebase for canonical names; conducts adversarial alignment interview (Q1/Q2/…); writes `CONTEXT.md` with repo-detection logic (single, monorepo, multi-repo); writes `spec/<key>/context-snapshot.md`; routes decisions to `decisions.md` vs ADR via three-criteria test; ADR path lookup with per-repo discovery and `docs/governance/adr/` default; complexity signals trigger Opus recommendation

## `address-pr-comments` skill

- **1.0.1**
  - Step 9: prefer `mcp__github-tools__add_reply_to_pull_request_comment` over raw `gh api` for posting replies; `gh api` kept as fallback when MCP is not configured
- **1.0.0**
  - Initial — classify and resolve all PR comments (human and bot); four-tier MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE classification with source-heuristic defaults for bot comments; presents classification for approval; implements fixes grouped by file; re-runs build and unit gates; commits and pushes with interactive confirmation; posts reply per comment

## `create-pr` skill

- **1.0.1**
  - Step 3: use `.github/PULL_REQUEST_TEMPLATE.md` (already loaded in Step 1) as the body structure instead of constructing a free-form body; maps each template section to a spec artifact source
- **1.0.0**
  - Initial — draft PR description from spec artifacts (ACs→How to Test, plan tasks→What changed, prd.md→Goal Alignment); optional Jira remote-link or GitHub `Closes #N` issue linking; interactive draft review before `gh pr create`

## `push-to-git` skill

- **1.0.0**
  - Initial — atomic conventional commits from plan task structure; one commit per task with tests bundled; staged per-file (never `git add -A`); interactive push confirmation before affecting remote; verbatim error reporting on push rejection

## `verify` skill

- **1.0.0**
  - Initial — sequential gate pipeline (build → lint → unit → integration → conditional coverage); each gate runs separately so failures are attributable; re-runs from the failed gate after a fix; structural failures escalate to `/refine`

## `review` skill

- **1.0.1**
  - Step 4: add explicit `git diff main...HEAD -- <file>` command for reading per-file diffs; prevents agents from picking inconsistent diff ranges
- **1.0.0**
  - Initial — autonomous adversarial review loop; auto-fixes mechanical issues silently before reporting; CRITICAL findings loop until clean; zero-findings first pass triggers mandatory source-anchored recheck (every changed file must be cited with path, line range, and evidence)

## `simplify` skill

- **1.1.1**
  - Step 3: remove hard-stop on pre-existing test failures; record failing count as the pre-simplification baseline and proceed — only *new* failures introduced during the session block in Step 7
- **1.1.0**
  - `repo-patterns-guide.md`: replace stale `CONTEXT.md` + `context-snapshot.md` references with `spec/<key>/glossary.md` (single glossary source since grill-with-docs 1.1.0)
- **1.0.0**
  - Initial — interactive complexity review post-implementation; checks against AI over-engineering anti-pattern catalog and local repo conventions; presents SIMPLIFY/KEEP/ESCALATE findings for approval before applying; verifies zero new failures after changes

## `implement-goal` skill

- **1.0.0**
  - Initial — autonomous BUILD→VERIFY RUNTIME→TEST→VERIFY loop for UI, config, and migration work; post-implementation tests document observed behavior (not internal state); conditional branch coverage gate

## `implement-tdd` skill

- **1.1.0**
  - Tracer Bullet phase: conditional pre-loop step for plans spanning ≥ 3 distinct architectural layers; detects layers from plan file targets; writes thin stubs and one end-to-end integration test before the per-task loop; tracer test stays green throughout as stubs are replaced; `tdd-cycle-rules.md` extended with Tracer Bullet Phase section
- **1.0.0**
  - Initial — autonomous RED→GREEN→INTEGRATE→VERIFY loop per task; unit tests first (isolated, mocked), then integration tests against real dependencies; conditional branch coverage gate before advancing to next task

## `refine` skill

- **1.3.0**
  - Step 1: use `AskUserQuestion` tool as fallback when no argument is passed, instead of a plain text prompt
  - Step 4: document that `stories.json` is the authoritative source over the Jira ticket when content diverges
  - Step 6: check for pre-built `context/` directory at the target repo root before direct file exploration; validate freshness via timestamp in `index.yml` / `index.md`; add optional `gh pr list` hint to surface recent merged changes
  - Step 11: add `AskUserQuestion` for terminal vs browser review choice; browser path generates `spec/<key>/plan-review.html` from `templates/plan-review-template.html` and opens it
  - New: `templates/plan-review-template.html` — 3-slide HTML review page (Story overview, Task list, AC coverage) with per-slide feedback textareas and "Copy All Feedback" button, consistent with makato-plan review templates
- **1.2.0**
  - Step 2: if `spec/<key>/` does not exist, stop and redirect the user to run `/makato-plan:decompose` before returning to `/refine`
- **1.1.0**
  - Read `AGENTS.md` and `CLAUDE.md` from the target codebase root at the start of Step 6; extracts project goal, decision test, naming conventions, and contributor constraints as hard constraints on the implementation plan
- **1.0.0**
  - Initial — bridges pland work items to implementable plans; reads Jira story and spec/ artifacts (prd.md, design.md, decisions.md); produces plan.md with tasks, file targets, unit/integration test strategy, and AC mapping; interactive; entry point to the build pipeline

## Plugin-level

- **0.2.0**
  - add full build pipeline: refine, implement-tdd, implement-goal, simplify, review, verify, push-to-git, create-pr, address-pr-comments; all skills emit JSONL build audit log to `spec/<key>/build.jsonl`
- **0.1.0** — 2026-05-14
  - initial plugin with governance files, plugin manifest (`plugin.json`), contributor guide (`AGENTS.md`)
