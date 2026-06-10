# Changelog — makato-plan

Changes are grouped by skill/agent/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## `brainstorming` skill

- **1.1.6**
  - review HTML template robustness fixes from PR #39 bot review: `copyFeedback()` now reads the feature name from the DOM rather than embedding `{{FEATURE_NAME}}` in a JS string literal (would break on apostrophes or backslashes)
  - `next-btn` is now disabled on initial load when only one slide exists
  - `has-comment` step-track indicator now checks all textareas in a slide instead of only the first
- **1.1.5**
  - rebuild `brainstorm-review.html` as a slide-style review (matching create-prd / create-architecture / decompose) with per-slide feedback textareas, sticky step track, comments strip, and prev/next navigation
  - each top concept gets its own slide with a dedicated feedback input — replaces the prior single-page-scroll layout
  - `doc-writer` agent updated with new placeholder list (`CONCEPT_SLIDES`, stats, `EPIC_KEY`, `DECISIONS_TABLE_ROWS`)
- **1.1.4**
  - make image attachment download explicit. Previously, when `download_attachment` streamed an image's base64 for inline visual inspection, the agent could skip persisting it to disk because it had "already seen" the image. Step 1.1 now states that visual inspection is not a substitute for writing bytes to disk, and adds a post-download `ls` verification step
- **1.1.3**
  - cross-platform browser-open commands: list `open` (macOS), `xdg-open` (Linux), and `start` (Windows) for review-HTML launch instead of macOS-only `open` (closes #25)
- **1.1.2**
  - rebuild HTML review template with terminal-themed design tokens, dark/light theme toggle, structured stats grid, observation/concept/rejected/question card variants, copy-to-clipboard approval actions
- **1.1.1**
  - remove static Integration section from end of file
- **1.1.0**
  - attachment import now downloads to `reference/original/`, converts to markdown in `reference/`, with separate handling for "Images only" option
- **1.0.0**
  - Initial — structured divergent-convergent ideation on Jira ITDB features (62 techniques, 50+ ideas target, HTML approval gate)

## `create-prd` skill

- **1.0.5**
  - add Step 5.0 "Interview Consolidation" as REQUIRED CHECKPOINT between grill (Step 4) and story sketching (Step 5.1). Internal-only consolidation that builds a slot table across all rounds + brainstorm + grill, applies later-wins on intra-interview contradictions (superseded answers logged to `decisions.md` audit trail), and re-evaluates story coverage so late answers that unlock additional vertical slices aren't missed
  - story sketches now require a "Derived from: <slot refs>" footer as observable trace that consolidation informed sketching
  - skipped in refine mode
  - replaces Step 5.2's "Interview supersedes brainstorm" paragraph with a pointer back to 5.0 (avoids duplicate `decisions.md` audit rows for the same contradiction)
- **1.0.4**
  - make grill checkpoint mandatory after Round 3 (model was skipping the soft "I recommend..." prompt and jumping straight to PRD generation)
  - add reconciliation rule so interview answers that contradict `brainstorm.md` / `decisions.md` win — contradicted content is dropped from the PRD and recorded in `decisions.md` Decision Summary as an audit trail (keeps PRD clean, prevents stale brainstorm content leaking into downstream stories)
- **1.0.3**
  - cross-platform browser-open commands: list `open` (macOS), `xdg-open` (Linux), and `start` (Windows) for review-HTML launch instead of macOS-only `open` (closes #25)
- **1.0.2**
  - reference `shared/refinement-contract.md` (refine flow rules) and `shared/repositories-yml-schema.md`
- **1.0.1**
  - inline constraints at point of use, remove end-of-file NEVER and Composes With sections
- **1.0.0**
  - Initial — create Product Requirements Documents from brainstorming output with vertical story sketches, product strategy interview, and HTML review gate

## `create-architecture` skill

- **1.0.3**
  - cross-platform browser-open commands: list `open` (macOS), `xdg-open` (Linux), and `start` (Windows) for review-HTML launch instead of macOS-only `open` (closes #25)
- **1.0.2**
  - reference `shared/refinement-contract.md` (refine flow rules) and `shared/repositories-yml-schema.md`
- **1.0.1**
  - inline constraints at point of use, remove end-of-file NEVER and Composes With sections
- **1.0.0**
  - Initial — create Architecture Design Documents from PRD output through structured architect interviews, grill integration, and interactive HTML review gate

## `create-prototype` skill

- **1.0.2**
  - reference `shared/refinement-contract.md` (refine flow rules) and `shared/repositories-yml-schema.md`
- **1.0.1**
  - inline constraints at point of use, remove end-of-file NEVER and Composes With sections
- **1.0.0**
  - Initial — create interactive high-fidelity HTML prototypes of new UI surfaces with integrated review, design system research, adaptive UX interview, and grill integration

## `decompose` skill

- **1.1.1**
  - cross-platform browser-open commands: list `open` (macOS), `xdg-open` (Linux), and `start` (Windows) for review-HTML launch instead of macOS-only `open` (closes #25)
- **1.1.0**
  - add Round 2.5 (epic-level feature toggle interview), Round 3 (epic objective capture from PRD or fresh prompt), draft-status handling for `prd.md`/`design.md`, and Step 7 substeps that copy qa-reviewer drafts into `description.successScenarios[]` and require `epic.objective`
  - fix `acceptanceTestCases` field type in `stories-json-template.json` (was `""` string, now `[]` array matching schema)
  - reference `shared/refinement-contract.md` and `shared/repositories-yml-schema.md`
- **1.0.1**
  - inline constraints at point of use, remove end-of-file NEVER and Composes With sections
- **1.0.0**
  - Initial — decompose pland features into vertically-sliced stories with acceptance criteria, Three Amigos simulation, and interactive HTML review

## `grill` skill

- **1.1.0**
  - capture feature-scoped vocabulary inline as terms are sharpened during interviews — writes `specs/{ITDB-KEY}-{slug}/glossary.md` with canonical-term + `_Avoid_:` aliases + relationships + flagged ambiguities (DDD ubiquitous-language pattern, adapted from the global `grill-with-docs` skill)
  - load `glossary.md` on entry alongside `decisions.md` so established terms are not re-asked
  - new "Sharpen feature vocabulary" sub-section in Step 2 lists the trigger patterns (acronyms, synonyms, contested terms, vague nouns)
  - HTML review template now includes a "Changes to glossary.md" section with added/revised/flagged-ambiguity highlighting
- **1.0.3**
  - cross-platform browser-open commands: list `open` (macOS), `xdg-open` (Linux), and `start` (Windows) for review-HTML launch instead of macOS-only `open` (closes #25)
- **1.0.2**
  - rebuild HTML review template with terminal-themed design tokens, dark/light theme toggle, change-card variants (Added/Revised/Confirmed/Deferred) for decisions audit
- **1.0.1**
  - remove static pipeline diagram from end of file
- **1.0.0**
  - Initial — adversarial interview that stress-tests any phase artifact, challenges decisions depth-first

## `publish` skill

- **1.1.0**
  - fix Jira `create_issue_link` parameter names (`inwardIssue`/`outwardIssue` → `sourceIssue`/`targetIssue`) and document direction semantics for Parent-Child and Dependency links
  - add update-mode for existing `confluencePageId` (calls `update_page` instead of always creating)
  - drop "if available" hedge on `create_page` and the manual-fallback note
- **1.0.0**
  - Initial — publish pland stories.json to Jira (Epic + Stories + Subtasks + dependency links) and Confluence (stakeholder spec page), with pre-populated subtask templates, create-or-update idempotency, and two confirmation gates

## `create-acceptance-tests` skill

- **1.0.1**
  - fix `definitionOfDone` dispatch path (was `story.description.definitionOfDone`, now top-level `story.definitionOfDone` matching schema)
- **1.0.0**
  - Initial — refine draft Gherkin scenarios into polished acceptance test cases (3-5 per story), dispatches acceptance-writer agent, quality self-review, interactive HTML review

## `acceptance-writer` agent

- **1.0.0**
  - Initial — Sonnet subagent that refines draft scenarios into high-level, manually testable Gherkin per story

## `po-reviewer` agent

- **1.0.0**
  - Initial — Product Owner perspective for Three Amigos story review (value, scope, phase assignment)

## `dev-reviewer` agent

- **1.0.0**
  - Initial — Lead Developer perspective for Three Amigos story review (feasibility, dependencies, estimates)

## `qa-reviewer` agent

- **1.0.0**
  - Initial — QA Engineer perspective for Three Amigos story review (testability, draft Gherkin)

## `prototype-builder` agent

- **1.0.0**
  - Initial — creative Sonnet subagent for generating interactive HTML prototypes with target app design tokens

## `context-scout` agent

- **1.0.0**
  - Initial — read-only Haiku subagent that scans `context/{repo}/` for relevant files

## `doc-writer` agent

- **1.0.0**
  - Initial — write-capable Haiku subagent for generating HTML reviews and writing markdown artifacts

## `markitdown` MCP server

- **1.0.0**
  - Initial — converts downloaded attachments (PPTX, PDF, DOCX) to markdown for content extraction

## Plugin-level

- **0.2.0**
  - rename `shared/glossary.md` → `shared/terminology.md` to free the word *glossary* for the new per-spec, runtime-written glossary produced by the `grill` skill. The plugin-level file remains a contributor-maintained terminology reference; the per-spec `glossary.md` is the feature-scoped, agent-read vocabulary
  - update README, AGENTS.md, and the file's own header to reflect the rename and clarify the two layers
- **0.1.0** — 2026-05-12
  - initial plugin with governance files, plugin manifest (`plugin.json`), contributor guide (`AGENTS.md`)
  - cross-skill `shared/` resources (`scenario-schema.md`, `repositories-yml-schema.md`, `refinement-contract.md`, `glossary.md` — renamed to `terminology.md` in 0.2.0) wired via [within-plugin symlinks](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks). Each consuming skill carries `skills/<name>/shared` → `../../shared`, and skill files reference resources as plain `shared/<file>.md` (no `../`). Replaces the prior `@../../shared/...` notation, which did not resolve at runtime under cached plugin installs.
