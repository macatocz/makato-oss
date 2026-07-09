<!-- markdownlint-disable MD013 MD033 -->
# Changelog — makato-plan

Changes are grouped by skill/agent/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## Plugin-level

- **Added** `config/skill-bundles.yml` (#145) — bundles `plan-skills`, `plan-prd`, `plan-decompose`, `plan-issues` route PRD/architecture spec files, plan.md/stories.md, created-issues.json, and plan skill files to the appropriate planning skills (brainstorming, create-prd, grill, decompose, to-issues, issue-to-project, etc.).

---

## `archive-spec` skill — removed (wrong plugin)

- Skill moved to `makato-orchestrate/skills/archive-spec`; `makato-plan` does pre-dev shaping,
  not post-merge lifecycle management

---

## `to-issues` skill

- **3.4.0**
  - new `points:*` label dimension (10th total): `metadata.points` if explicit (positive integer), else derived from `metadata.effort` via SIZE_MAP (`s→1, m→3, l→8, xl→13`). Symmetric design to the v3.3.0 `severity→priority` derivation
  - **closes the Estimate field gap** in the to-issues → issue-to-project chain: `issue-to-project` v2.4+ already has the number-field resolver for `points:N` but no upstream label source — now `to-issues` emits them so the GitHub Project board's Estimate column populates automatically without manual `gh project item-edit --number` calls
  - METADATA_BLOCK in the issue body now renders `**Points:** N *(derived from effort)*` alongside the existing Severity/Phase/Effort/Priority lines
  - 7 new label colors documented in `label-taxonomy.md` (`points:1..21`, grey gradient — small to large)
  - Strictly additive: stories.json without `metadata.points` AND without `metadata.effort` produces no `points:*` label (existing v3.3.x behavior unchanged)
- **3.3.1**
  - **collision fix:** `phase:*` enum changed from `p1..p5` to bare `1..5`. The `p` prefix is now reserved exclusively for `priority:*` so a reader scanning issue bodies or board chips can never mistake a Phase value for a Priority value. The body's `**Phase:**` line now renders `1` instead of `P1`.
  - Backward-compat: stories.json files written for v3.3.0 with `metadata.phase: "p1"` are still accepted on input — auto-normalized to `"1"` before label emission with a soft-warn. New stories.json files should write bare digits.
  - Color palette for `phase:1..5` is unchanged (same blue gradient applies to the renamed labels). Existing repos that already created `phase:p1..p5` need to either rename the labels manually (`gh label edit phase:p1 --name phase:1`) or have `to-issues` Step 4 create the new bare-digit labels alongside (the old ones can be deleted by hand once unused).
- **3.3.0**
  - extend the label taxonomy from 5 dimensions to 9 — adds `severity:*` (critical/high/medium/low), `phase:*` (p1–p5, distinct from `tier:`), `effort:*` (s/m/l/xl), and `priority:*` (p0–p3) — all sourced from a new optional `stories[].metadata` block in `stories.json`
  - `priority:*` two-stage resolution: explicit `metadata.priority` wins; otherwise derived from `metadata.severity` via `critical→p0`, `high→p1`, `medium→p2`, `low→p3` — keeps severity (intrinsic) and priority (board-display) as separable axes so an operator can re-prioritize without touching the severity label
  - `priority:*` is consumed verbatim by `issue-to-project` v2.4+ via its `signal_prefix: "priority"` resolver — the chain `to-issues` → `created-issues.json` → `issue-to-project --fields-only` now writes the GitHub Project board's Priority column without any manual `gh project item-edit` calls
  - issue body gains an optional `{{METADATA_BLOCK}}` placeholder that renders `Severity / Phase / Effort / Priority` as human-readable lines inside the existing `## Details` section — when `metadata` is absent the block collapses to the empty string (no change for existing stories.json files)
  - all four new dimensions are sparse-by-default: stories.json without a `metadata` block produces the byte-identical labels to v3.2.1
  - colors documented in `label-taxonomy.md`: severity uses red→green gradient matching urgency; phase uses dark→light blue gradient matching earliest→latest; effort uses light→dark purple gradient matching small→large; priority mirrors severity colors so the board priority column and the severity label visually agree
- **3.2.1**
  - sagibeast-alignment audit: removed trailing `## NEVER` section (makato-skill-creator rule: no NEVER sections at end of file — high context-compaction-drop risk). Inlined the two constraints that lived only there: enterprise-host prohibition moved to Step 0 (GH_ENTERPRISE_TOKEN / TLS-bypass guard) and ADR-file-contents prohibition moved to Step 2 (folder-names-only, cites D5).

## `excalidraw` skill

- **1.3.1**
  - sagibeast-alignment audit: removed trailing `## NEVER` section and inlined all 9 constraints as sub-bullets under Workflow Step 4 where they apply
  - removed extraneous `metadata.version` from frontmatter (not a recognized field per frontmatter-spec.md)

## `create-architecture` skill

- **1.0.4**
  - sagibeast-alignment audit: fixed two corruption artifacts — "architectural makato" → "architectural impact" in When NOT to Use, and "most makatoful technical choices" → "most impactful technical choices" in Round 2 interview (PATCH wording fixes only)

## `create-acceptance-tests` skill

- **1.0.2**
  - sagibeast-alignment audit: fixed duplicate `1.` numbering in Step 7 (second item changed to `2.`)

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

- **1.1.0**
  - summarise artifacts before dispatch (Fix A): design tokens → flat JSON, mock data → typed record samples, decisions → resolved-only, all content wrapped in delimited blocks — prevents prompt injection and cuts dispatch payload by ≥ 30% on complex features
  - enforce hard CONTEXT_SCOUT_TOKEN_BUDGET: 2000 ceiling on context-scout findings entering session context (Fix C) — defined as named constant, passed to every scout dispatch
  - remove `references/skill-plan.html` (41 KB design artefact, ~10 k tokens wasted per invocation) (Fix D)
  - HTML validation step now explicitly greps for `http://`, `https://`, `//cdn`, `data:` URIs — cannot be bypassed by malformed slide fragments (security)
  - partial re-dispatch on slide failure targets only the failing surface fragment, not the full file (Fix B integration)
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
  - Initial — decompose shaped features into vertically-sliced stories with acceptance criteria, Three Amigos simulation, and interactive HTML review

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
  - Initial — publish shaped stories.json to Jira (Epic + Stories + Subtasks + dependency links) and Confluence (stakeholder spec page), with pre-populated subtask templates, create-or-update idempotency, and two confirmation gates

## `create-acceptance-tests` skill

- **1.0.1**
  - fix `definitionOfDone` dispatch path (was `story.description.definitionOfDone`, now top-level `story.definitionOfDone` matching schema)
- **1.0.0**
  - Initial — refine draft Gherkin scenarios into polished acceptance test cases (3-5 per story), dispatches acceptance-writer agent, quality self-review, interactive HTML review

## `issue-to-project` skill

- **2.7.0**
  - `Ready` and `In review` routing: `STATUS_MAP` and `PRIORITY` extended to surface all six GitHub Projects v2 Status options from `labels[]` — adds `status:ready` → `Ready` and `status:in-review` → `In review`; collision priority is `blocked > done > in-review > in-progress > ready > todo`. Both new `options.*` keys are optional; absent options fall through to `Todo` with a loud WARN
  - PR-open lifecycle remap: `pull_request.opened` now writes `In review` (outcome `pr_opened_set_in_review`) when `options.in_review` is present; falls back to `In Progress` with a loud WARN (outcome `pr_opened_set_in_progress_fallback`) when absent. v2.0's `pr_opened_set_in_progress` outcome is retired for new artifacts but remains in the schema enum so old artifacts re-validate
  - `PR` repo label stamp: `sync-lifecycle` and `--from-webhook` call `gh issue edit --add-label <pr_label_name>` whenever a linked open PR is detected on an issue; the label is a permanent historical marker and is never removed by the skill. `--init` creates the label in the repo (color `0E8A16`) via a new Step 6c with pre-flight token-scope check
  - `ready_queue_mode` config key and autonomous auto-promotion: new optional config key (`"manual"` default, `"autonomous"` opt-in). Autonomous mode auto-promotes Todo → Ready for issues that carry no `status:*`, `needs-human-review`, `blocked-by:*`, or `hold-in-todo` labels; manual mode never writes `Ready` autonomously
  - `pr_label_name` config key with empty-string disable sentinel: new optional config key (default `"PR"`) that sets the repo label name stamped on linked-PR issues; empty string `""` explicitly disables all label calls
  - Reconcile drift cases extended: `label_ready_board_not`, `label_in_review_board_not`, and `label_pr_drift` added to `reconcile-process.md` and `reconcile-report.schema.json`; repaired by `--repair-aggressive` only (`--repair-additive` scope is unchanged)
  - Schema bumps: `project-sync.schema.json` `schema_version` enum gains `"2.7"`; 8 new `outcome` values; 5 new optional `summary` keys (`set_ready`, `set_in_review`, `auto_promoted_ready`, `pr_label_added`, `pr_label_failed`); 2 new optional per-row fields (`pr_label_action`, `pr_label_error`). All additions are purely additive — v2.6 artifacts re-validate unchanged
  - `SUPPORTED` / `schema_version` gate extensions: `lifecycle-process.md`, `webhook-lifecycle.md`, and `retry-process.md` gates extended to accept all `1.x` and `2.x` artifacts through `"2.7"`, fixing a pre-existing v2.1 regression where the shipped files rejected every v2.0+ artifact
  - `[issue-to-project:auto]` log prefix introduced for autonomous-mode auto-promotion decisions (both successful promotions and per-issue skip reasons); the `:auto` prefix is reserved for inference decisions and is gated entirely behind `ready_queue_mode == "autonomous"` — manual-mode operators see no `:auto` lines

- **2.6.0**
  - GitHub Enterprise Server (GHES) host support: new optional `github_project` config keys `host` (bare hostname, default `"github.com"`), `host_type` (`"cloud"` | `"enterprise"`, default `"cloud"`), and `min_ghes_version` (`"MAJOR.MINOR"` string, default `"3.10"`). Existing v1 configs are fully backward-compatible — missing keys resolve to github.com cloud defaults with no re-init required
  - All `gh` invocations updated from `GH_HOST=github.com gh ...` prefix to `gh --hostname <resolved_host> ...` flag (D1). `GH_HOST` env var is still read by `gh` if set but is no longer set by the skill — see NEVER section for the `GH_HOST` env conflict note
  - New pre-flight Check 6 (enterprise only): when `host_type == "enterprise"`, calls `gh --hostname <host> api /meta` and extracts `installed_version`; halts with `GHES_TOO_OLD` if version is below `min_ghes_version`. Version comparison uses integer-tuple semantics (not lexicographic) to correctly handle `"3.9"` < `"3.10"`. Check is skipped for `host_type == "cloud"`
  - Three new HALT codes: `GHES_TOO_OLD` (exit 1, GHES installed version below 3.10), `RATE_LIMIT_EXCEEDED` (exit 1, HTTP 429 or `rate limit exceeded` stderr from any `gh project` call in steps 3–4), `TLS_TRUST_FAILED` (exit 1, TLS/SSL certificate verification failure — no `--insecure` escape hatch; install the CA in the system trust store). All v1.0.0–v2.5.0 HALT codes inherit unchanged
  - Rate-limit guard and TLS guard wrap every `gh project item-list`, `item-add`, and `item-edit` call; halt immediately on detection (no automatic retry per D7, no TLS bypass per D8). `Retry-After` value from the rate-limit response is surfaced in the HALT message
  - `project-sync.json` artifact: `project.host` key added and made required (string, value `"github.com"` for cloud, GHES hostname for enterprise). `schema_version` gains enum value `"2.6"`. Downstream consumers validating artifacts against the v2.6 schema must set `project.host`; v1 artifacts lacking `project.host` fail v2.6 schema validation — treat missing host as `"github.com"` or regenerate the artifact
  - `--init` wizard gains Step 0 (prompt for host before any API calls, auto-derive `host_type` from the entered value, run GHES version gate for enterprise). URL synthesis updated: `https://<host>/orgs-or-users/<owner>/projects/<number>`. `init_skill_version` written as `"2.6.0"`. NEVER section updated: old `"NEVER target the enterprise GitHub host"` line replaced with `GH_ENTERPRISE_TOKEN` ban, TLS bypass ban, and host-isolation logging rule
  - Backward-compatible: all prior HALT codes, exit codes, R1 sentinel keys (optional additive `host` key emitted when `host != "github.com"`), `created-issues.json` usage, and `project-sync.json` fields other than the new `project.host` are unmodified. New GHES consumers run `gh auth login --hostname <host> --scopes project,read:project` then `issue-to-project --init`; existing github.com consumers see no behavior change

- **2.5.0**
  - New auto-re-init sub-path: when the stale-config trigger fires (2 consecutive item-add failures matching the stale-id pattern), `--auto-reinit` opt-in activates an inline recovery path that re-discovers the same project via `gh project list` (matching by number + title + owner), validates the Status field and options are unchanged, rewrites cached IDs in `.claude/config.json`, and resumes the item-add loop without operator intervention. Default **OFF** in v2.5 (pass `--auto-reinit` to opt in); default will flip to ON in v2.6 after burn-in. New reference file `references/auto-reinit-process.md` (MANDATORY on normal runs when `--auto-reinit` is active) documents all 7 phases, exact `gh` invocations, HALT conditions, loop guard, and DRY_RUN interaction
  - New `title` required config field (v2.5+): `--init` caches the human-readable project title in `github_project.title` for disambiguation. On the first v2.5 run against a v1-format config (`title` absent), a silent one-time migration runs `gh project view` to fetch and cache the title; migration failure degrades gracefully (auto-reinit unavailable this run only; normal sync continues)
  - Three new optional audit keys appended to `github_project` block after auto-re-init fires: `reinit_timestamp`, `reinit_skill_version`, `reinit_reason`. `init_timestamp` and `init_skill_version` are immutable — never overwritten by auto-re-init; they record the first-ever human-triggered `--init` setup
  - Two new HALT codes: `AMBIGUOUS_REINIT` (exit 1 — auto-re-init could not safely identify the same project: title mismatch, owner-type change, Status field/option structure drift, zero or multiple matches) and `STALE_CONFIG_PERSISTENT` (exit 1 — auto-re-init succeeded but new IDs are also stale; loop guard fired). `INIT_FAILED` extended to cover auto-reinit config-write failure. All v1.0.0–v2.4.0 HALT codes are immutable and inherit unchanged
  - New `--auto-reinit` and `--no-auto-reinit` flags documented in Argv contract. `--auto-reinit` activates auto-re-init in v2.5 burn-in. `--no-auto-reinit` is a no-op in v2.5 (logs INFO); becomes meaningful in v2.6 when default flips. Both flags are mutually exclusive with `--init`
  - `project-sync.json` artifact: `schema_version` bumped to `"2.5"` on runs that include `auto_reinit_log`. New optional top-level key `auto_reinit_log` (array, present only when auto-re-init fired; empty runs omit the key). New `outcome` enum value `recovered_via_auto_reinit` for issues that land on the board via the recovery path. New optional `summary.recovered` integer (count of `recovered_via_auto_reinit` rows). `project-sync.schema.json` updated accordingly
  - Backward-compatible: all prior HALT codes, exit codes, R1 sentinel keys, `created-issues.json` usage, and existing `project-sync.json` fields are unmodified. Operators upgrading from v1.0.0–v2.4.0 see no behavior change (auto-reinit defaults OFF). Downstream consumers must accept `schema_version: "2.5"` and treat `auto_reinit_log` as an optional additive key. Consumers using strict `outcome` enum validation must extend their validator with `recovered_via_auto_reinit`

- **2.4.0**
  - New `--fields-only [<slug>]` flag: skips item-add entirely and runs only the field-write loop for issues already on the board. Items not on the board are recorded as `outcome: "not_on_board_skipped"`. Mutually exclusive with `--init`. Useful for backfilling Priority/Iteration/Estimate/Date Target fields after config is extended without triggering duplicate-add attempts (D10)
  - New `fields` nested dict in `github_project` config block (v2.4 canonical shape written by `--init`): keyed by stable lowercase identifier (`status`, `priority`, `iteration`, `estimate`, `date_target`, custom); each entry carries `id`, `name`, `type`, and type-specific optional keys (`options` for single-select, `current_only` for iteration, `size_map` for estimate). New reference file `references/field-type-routing.md` (MANDATORY on normal-run and `--fields-only` runs with `fields` config) documents the per-type `gh project item-edit` flag (`--single-select-option-id`, `--iteration-id`, `--number`, `--date`), signal resolution rules, `SIZE_MAP` constant, and `resolve_field_write` dispatch function
  - v1 flat config read-compat (D2): v2.4 detects the v1-shaped `status_field_id` / `options.*` config and translates it in-memory to the v2 `fields` dict. Emits `[issue-to-project] WARN: v1 config shape detected — please re-run '--init' to migrate to v2.4 schema`. Translation removed in v2.5; hard-error in v3.0
  - `--init` gains Steps 4a–4c: field discovery loop (Priority, Iteration, Estimate, Date Target from the same `gh project field-list` response), Priority option validation prompt, and a field-wiring confirmation UX before writing. Writes `fields` dict to config in place of the flat `status_field_id` / `options.*` keys. `init_skill_version` bumped to `"2.4.0"` in written configs
  - Step 2.5 (signal extraction) added to normal-run flow: extracts `priority:`, `iter:`, `points:N` (canonical estimate), `size:S/M/L/XL` (deprecated fallback via `SIZE_MAP`), and milestone `due_on` per issue; cached as a per-issue `signals` dict. New env var `ITP_SKIP_FIELDS` (comma-separated field keys to skip per run). Per-issue soft-warns: multiple `priority:*` labels, non-integer `points:N`, deprecated `size:*` label
  - Step 3 snapshot enriched with current field values for all configured fields (idempotency extension). `FIELD_NOT_FOUND` check validates all cached field IDs against live project before any mutations. Field write is skipped (`skipped_already_set`) when `signals[key] == snapshot[url].fieldValues[key]`
  - Two new HALT codes: `FIELD_TYPE_UNSUPPORTED` (exit 1, config references a field `type` not in v2.4 write matrix — `"text"`, `"multi-select"` etc.) and `FIELD_NOT_FOUND` (exit 1, cached field id absent from current project). All v1.0.0–v2.3.0 HALT codes are immutable and inherit unchanged
  - `project-sync.json` `schema_version` bumped to `"2.4"`. Each result row gains a `fields[]` array (one entry per configured non-Status field) with `name`, `intended_value`, `current_value`, `outcome` (enum: `set`, `skipped_already_set`, `no_signal`, `write_failed`, `unsupported_type`, `dry_run`), `error`. New `outcome` value `not_on_board_skipped` for `--fields-only` mode. Three new `summary` integers: `field_writes_attempted`, `field_writes_succeeded`, `field_writes_failed`. `status: "partial"` fires when `field_writes_failed > 0`. The v1 `final_status` key is kept on result rows as a deprecated alias for `fields[name="Status"].current_value`; removed in v2.5. New RESULT sentinel keys `field_writes_attempted/succeeded/failed` (0 for v1-config consumers)
  - Backward-compatible: all prior HALT codes, exit codes, R1 keys, `created-issues.json` usage, and `project-sync.json` fields are unmodified. Downstream consumers must accept `schema_version: "2.4"` and treat `fields[]` as an optional additive array. Scripts reading `final_status` from result rows should migrate to `fields[name="Status"].current_value` before v2.5 ships. Board-add behavior is byte-for-byte identical to v2.3.0 when no `fields` block is present in config

- **2.3.0**
  - New `--board-audit` flag: read-only board-wide snapshot that calls `gh project item-list --limit 9999`, groups items by `repository.nameWithOwner` into known-repo (`known_repos`) and unknown-repo buckets, and writes `board-audit.json` to the repo root. Mutually exclusive with `--init` and positional slug. Emits `RESULT: {"status":"ok","artifact_path":"board-audit.json","total_items":N,"known_repos_count":N,"unknown_repos_count":N}`. New reference file `references/board-audit.md` (MANDATORY on `--board-audit` runs) and co-shipped `references/board-audit.schema.json` (JSON Schema draft-07)
  - New optional config keys `known_repos` (array of `"owner/repo"` strings, default `[]`) and `reconcile_scope` (`"this-repo-only"` | `"all-known-repos"`, default `"this-repo-only"`) inside the `github_project` block. Empty / absent = exact v1 behaviour. `--init` auto-discovers `known_repos` from live board items and prompts `"Add all as known_repos? [Y/n/edit]:"` before writing
  - Pre-flight check 5 (verify-on-first-call): after config read, runs `gh project view <number> --owner <owner> --format json` to confirm `project_node_id` and `status_field_id` still match the live board before any mutations. Skippable via `ITP_SKIP_VERIFY=1` (logs a WARN). Skipped for `--board-audit` and `--init`. HALT `CROSS_REPO_VERIFY_FAILED` on mismatch or probe failure
  - Two new HALT codes: `CROSS_REPO_VERIFY_FAILED` (exit 1, check 5 probe returned mismatched IDs or failed) and `UNKNOWN_REPO` (exit 1 when `ITP_UNKNOWN_REPO_BEHAVIOR=error` and a board item is from a repo not in `known_repos` during `all-known-repos` reconcile). All v1.0.0–v2.2.0 HALT codes are immutable and inherit unchanged
  - Two new env vars: `ITP_SKIP_VERIFY` (bypass check 5 in flaky-network CI) and `ITP_UNKNOWN_REPO_BEHAVIOR` (`"warn"` default | `"error"` for strict governance); neither affects `--board-audit`
  - `schema_version` in `project-sync.json` bumped to `"2.3"` for v2.3.0+ artifacts. Optional `cross_repo` top-level block (present only when `known_repos` is configured, omitted when absent so v1 consumers see no unexpected keys). `project-sync.schema.json` adds enum value `"2.3"` and the `cross_repo` object definition with `known_repos`, `reconcile_scope`, and `verify_on_first_call` sub-keys
  - Normal-run RESULT sentinel gains optional `cross_repo` key `{"verify_passed":bool,"known_repos_count":N}` when `known_repos` is configured; omitted when absent so v1 parsers are unaffected
  - Backward-compatible: all prior HALT codes, exit codes, R1 keys, `created-issues.json` usage, and `project-sync.json` fields are unmodified. Downstream consumers must accept `schema_version ∈ {"1","1.1","1.2","2","2.1","2.2","2.3"}` and treat the `cross_repo` top-level key as optional. `board-audit.json` should be added to `.gitignore` in consumer repos that do not want it committed

- **2.2.0**
  - New `reconcile [<slug>]` positional subcommand (with `--reconcile` alias for backward compatibility) that diffs the live board snapshot against `specs/*/created-issues.json` and emits a `reconcile-report.json` artifact without mutating by default
  - Two opt-in repair modes: `--repair-additive` (safe, fixes `sync_gap` only, identical logic to v1 normal-run add path, no confirmation) and `--repair-aggressive` (all repairable drift, labels win over board Status, requires interactive TTY confirmation or `--yes-i-know` for non-TTY/CI; exit 2 on cancel)
  - Six drift case classifiers: `orphan`, `sync_gap`, `label_blocked_board_not`, `board_blocked_label_not`, `pr_merged_not_done` (deferred → `pending_future_feature`/`info`), `field_disagrees` (deferred → `pending_future_feature`/`info`)
  - Paged board snapshot loop (D2): `ITP_RECONCILE_PAGE_SIZE` env var (default `100`) controls items-per-page; `gh project view` provides `totalCount` for progress logging; page 1 failure → existing `SNAPSHOT_FAILED`; page ≥ 2 failure → new `PAGED_SNAPSHOT_FAILED`
  - Two new HALT codes: `RECONCILE_NEEDS_CONFIRM` (exit 1, `--repair-aggressive` on non-TTY without `--yes-i-know`) and `PAGED_SNAPSHOT_FAILED` (exit 1, any page ≥ 2 of multi-page board snapshot failed mid-loop). All v1.0.0–v2.1.0 HALT codes are immutable and inherit unchanged
  - New artifact `specs/{slug}/reconcile-report.json` (or `specs/.reconcile-report.json` for union/slug-less runs) with per-row `drift[]`, `orphans_for_review[]`, and `summary.by_case` counts; `schema_version: "1"`; validated against new `references/reconcile-report.schema.json` (JSON Schema draft-07, co-shipped)
  - New reference file `references/reconcile-process.md` (MANDATORY on `reconcile` runs): full 6-step flow, paged snapshot pseudocode, 6 drift-case classifiers with decision tables, repair-mode dispatch, TTY check, artifact emission, and human summary format
  - Backward-compatible: `project-sync.json` is never touched by the reconcile path; all prior HALT codes, exit codes, R1 sentinel keys, and `created-issues.json` usage are unmodified; downstream `project-sync.json` consumers are unaffected; existing scripts parsing `HALT:` lines receive unrecognized codes gracefully with `case`/`switch` defaults

- **2.1.0**
  - New `--from-webhook <path>` flag for push-mode lifecycle sync. Mutually exclusive with `--init` and with a positional slug (enforced via `argparse.add_mutually_exclusive_group`). When present, bypasses `created-issues.json` discovery and builds a synthetic single-issue input from the webhook payload. Five events are supported by the lifecycle transition map: `issues.opened` → add issue (Todo default), `issues.labeled` (`status:blocked`) → Blocked, `pull_request.opened` → In Progress on linked issue, `pull_request.closed` (merged=true) → Done, `pull_request.closed` (merged=false) → Todo (abandon)
  - PR→issue link resolution via case-insensitive body scan using `(?i)\b(?:Closes|Fixes|Resolves|…)\b[ \t]+#(\d+)\b`. First match wins. No match with `ITP_WEBHOOK_STRICT_LINK=0` (default) → exit 0 `WEBHOOK_NOT_ACTIONABLE`; with `ITP_WEBHOOK_STRICT_LINK=1` → exit 1. New env var `ITP_WEBHOOK_STRICT_LINK` (default `0`) lets CI jobs enforce strict PR→issue linking
  - Synthetic single-issue input replaces `created-issues.json`: `{"schema_version":"1","slug":"_webhook","issues":[{"number":N,"url":"…","title":"…","labels":[]}]}`. Downstream steps 3–5 (snapshot, add/edit, artifact write) run unchanged against this input
  - Two new optional config keys (written by `--init` if absent, no re-prompting): `webhook_audit_dir` (default `.issue-to-project/lifecycle`) and `webhook_pr_link_patterns` (default `["Closes","Fixes","Resolves"]`). All existing `github_project` keys remain required and unchanged
  - New HALT codes: `WEBHOOK_PAYLOAD_INVALID` (payload not valid JSON or missing `action` / `issue` / `pull_request` fields, exit 1) and `WEBHOOK_NOT_ACTIONABLE` (event not in transition map or no linked issue found, exit 0 by default). All v1 HALT codes unchanged
  - Per-delivery audit artifacts written to `<webhook_audit_dir>/<YYYY-MM-DD>/<delivery-id>.json` (one file per `GITHUB_DELIVERY`; atomic-rename via `os.replace`; auto-mkdir). New `webhook` block in the artifact schema (schema_version `"2.1"`) carries `delivery_id`, `event_type`, `action`, `merged`, `lifecycle_transition`. `slug` sentinel is always `"_webhook"`. Fallback filename `<YYYYMMDDTHHMMSS>-<8-hex>.json` when `GITHUB_DELIVERY` is not set (soft-warn)
  - New outcome value `webhook_status_updated`: emitted when the issue is already on the board at a different Status and webhook-mode flips it to the transition target (webhook is the authoritative Status driver in this mode, unlike the manual-run precedence rule D5). New R1 RESULT keys: `webhook_event` (string `"<type>/<action>"`) and `webhook_transition` (string Status written or `"none"`); both are `null` in non-webhook runs (additive — v1 parsers unaffected)
  - v1 contracts fully unchanged: all prior HALT codes, exit codes, R1 sentinel keys, audit artifact fields, and `created-issues.json` usage are unmodified. Downstream consumers must accept `schema_version: "2.1"` in addition to prior versions. GitHub Actions workflow YAML template shipped in `references/webhook-lifecycle.md` for operator copy-paste

- **2.0.0**
  - Add `sync-lifecycle [<slug>] [--dry-run]` subcommand: queries GitHub via GraphQL `closingPullRequests` once per input issue and flips board Status to `In Progress` (open PR) or `Done` (merged PR). Calling the command repeatedly is safe and idempotent — the precedence rule (D5) ensures human-pinned Status values are never overwritten
  - Implement precedence rule (D5): if `current_board_status ≠ last_written_status` the item is treated as externally owned; `sync-lifecycle` records `outcome: "lifecycle_skipped_externally_set"` and skips the write
  - Implement PR selection rule (D3): merged-wins-over-open; among open PRs, most-recently-updated governs; closed-unmerged PRs produce `pr_closed_no_change` with no Status change (D4, O6)
  - Add optional `include_draft_prs` config key (default `true`): when `false`, draft PRs are ignored and do not advance Status to `In Progress` (D6). `--init` gains a step 6b prompt for this setting
  - Advance `schema_version` to `"2"` for `sync-lifecycle` artifacts; prior v1/v1.2 file is backed up to `project-sync.v1.bak.json` (one-generation soft backup) before overwrite (D9)
  - New per-row fields: `linked_pr_url` (governing PR URL or null) and `linked_pr_state` (`"open"`, `"merged"`, `"closed"`, `"null"`, or JSON null) added to all v2 artifact rows
  - New `summary` keys (additive): `set_in_progress`, `set_done`, `lifecycle_lookup_failed`, `lifecycle_skipped`; new HALT code `LIFECYCLE_LOOKUP_FAILED` fires when GraphQL lookup fails for every issue in the batch; per-issue lookup failures are soft-warns (exit 0)
  - New reference file `references/lifecycle-process.md` documents the 5-step `sync-lifecycle` flow: config read, input read, board snapshot, per-issue GraphQL + precedence + outcome routing, and atomic artifact write

- **1.2.0**
  - Generalize Step 4 status routing from the single `status:blocked` → `Blocked` mapping to the full four-status GitHub Projects v2 surface: `status:todo` → `Todo` (explicit no-op), `status:in-progress` → `In Progress`, `status:blocked` → `Blocked` (unchanged), `status:done` → `Done`. Routing is pure: a single `resolve_status_label(labels)` function operates over `created-issues.json`'s `labels[]` only — no live GitHub queries (Hard Guarantee 3 preserved)
  - Multi-label collision (e.g. `status:blocked` + `status:in-progress`) resolved by explicit priority: `blocked > done > in-progress > todo`. Loud `WARN` records the full collision set; never aborts (matches v1's soft-warn philosophy)
  - Unknown `status:*` labels (e.g. `status:wontfix`, future `status:review`) fall through to project default (Todo) with a loud `WARN`. Forward-compatible: a custom-label release can extend `STATUS_MAP` without breaking existing artifacts
  - New `outcome` values: `added_todo_explicit` (audit-distinguishes "operator labeled this Todo" from "no status label"), `added_in_progress` / `added_in_progress_edit_failed`, `added_done` / `added_done_edit_failed`. All three `*_edit_failed` outcomes carry `needs_status_retry: true` — `--retry-blocked-edits` from v1.1 retries all three uniformly (the verb already replays `item-edit` for any `needs_status_retry: true` row; the new edit-failed outcomes drop into the same recovery path)
  - New `summary` integers (additive, not renames): `set_todo`, `set_in_progress`, `set_done` join the existing `set_blocked`. `edit_failed` is the combined count across all three edit-failed targets. `left_default` semantics unchanged: counts items currently at Todo because no status label / unknown status label / edit-failed-stayed-at-Todo
  - `schema_version` bumped to `"1.2"` (the `"1.1"` slot is consumed by v1.1.0's retry verb; v1.2's additions stack on top — a v1.2 normal-run artifact is a valid retry source for `--retry-blocked-edits`). All additions purely additive — no fields removed or renamed
  - `config-schema.md` updated to mark `options.in_progress` and `options.done` as write targets (no longer "reserved for v2"). No `.claude/config.json` shape change; `--init` from v1.0.0 already cached all four option IDs, so existing configs are fully compatible without re-init
  - `DRY_RUN=1` extended: the `cli_command` for an issue that would receive a status edit is now a two-step shell line (the `item-add` joined to the `item-edit` with `&&`) so a single copy-paste reproduces the full routing intent
  - Backward-compatible by design: when `to-issues` only emits `status:blocked` (the current v3.2.0 contract), v1.2 behavior is byte-for-byte identical to v1.0.0 except for the additional summary keys and the `schema_version` string. The new routing paths are dormant until `to-issues` adds emission for the other three labels or operators manually relabel issues
  - Downstream consumers must accept `schema_version ∈ {"1", "1.1", "1.2"}` (relax from `== "1"` to `startswith("1")` or a `>=`-equivalent). Consumers using strict `outcome` enum validation must extend their validator with the five new values
  - Out of scope (deferred): custom status options (`status:review`, `status:qa`) — needs config-declared routing table, ships with a future field-generalization release; reconcile/repair-aggressive verb to re-route already-on-board items after relabeling — explicit opt-in to overwrite externally-changed Status; per-target edit-failed summary split (would break v1.0/v1.1 R1 consumers); lifecycle transitions from PR events (PR-open → In Progress, PR-merge → Done)

- **1.1.0**
  - Add `--retry-blocked-edits [<slug>] [--from <path>]` recovery verb that replays the `item-edit` step for prior-artifact rows tagged `needs_status_retry: true`, without touching the snapshot, `created-issues.json`, or re-adding the item. Single attempt per invocation (operator decides cadence); two-thirds of the v1.0.0 manual recovery procedure (delete-and-re-add) is now redundant
  - Slug resolution mirrors normal-run: explicit positional slug, or `--from <path>`, or most-recent-mtime over `specs/*/project-sync.json`. Mutually-exclusive group extended to cover `--init`, `--retry-blocked-edits`, and (with `--from`) positional slug; documented `RETRY_SOURCE_MISSING` and `RETRY_SOURCE_MALFORMED` HALT codes
  - New `outcome` values: `retry_succeeded` (200 ok on `item-edit`), `retry_failed` (any non-404 failure — `needs_status_retry` stays `true` for the next run), `retry_item_gone` (404 from `gh` — item deleted since the original run; terminal, `needs_status_retry: false`)
  - Forwarded-artifact contract: every row from the prior run is written into the new artifact (retried rows with their new outcome, non-retried rows verbatim). `schema_version` bumped to `"1.1"`; new top-level `retry_source` object (null on normal-run artifacts, populated on retry runs with the prior artifact's provenance); new `summary` integers `retry_attempted`, `retry_succeeded`, `retry_failed`, `retry_item_gone`
  - Retry-run R1 sentinel shape: `RESULT: {"status":…,"slug":…,"artifact_path":…,"retried_count":N,"retry_succeeded":N,"retry_failed":N,"retry_item_gone":N}` (counts reflect this invocation, not the prior artifact's add/edit totals)
  - `DRY_RUN=1` honoured by `--retry-blocked-edits` — emits `outcome: "dry_run"` with the literal `item-edit` command in `cli_command` for each row that would be retried; non-retry rows forwarded verbatim. `ITP_GH_TIMEOUT_SECONDS` applies to each `item-edit` call
  - Zero-retry early exit: `--retry-blocked-edits` against an artifact with no `needs_status_retry: true` rows writes a forwarded artifact, exits 0 with `retried_count: 0`. The "nothing to do" case is a valid success, not a HALT
  - Backward compatible: v1.0.0 normal-run artifacts (`schema_version: "1"`) are valid inputs to the retry verb. v1.1.0 normal-run continues to emit `"1"` artifacts (only retry runs emit `"1.1"`); consumers must accept both. Downstream consumers using strict `outcome` enum validation must extend their validator to cover the three new values. No `.claude/config.json` changes; no `--init` re-run required
  - New reference file: `references/retry-process.md` (3-step retry flow, exact `gh` invocations, 404-detection logic, outcome routing, forwarded-artifact rules, dry-run handling, boundary cases)
  - Out of scope (deferred to later versions): retrying `add_failed` rows (no `project_item_id` cached — normal re-run handles), bulk multi-slug retry, configurable retry count / back-off, automatic retry after normal-run, board-state verification post-edit via `item-list`, lifecycle transitions (`In Progress`, `Done`)

- **1.0.0**
  - Initial release. Two execution modes: `issue-to-project --init` (one-time setup wizard that discovers a GitHub Projects v2 board, resolves Status field + four option IDs, writes `github_project` block to `.claude/config.json`) and normal-run `issue-to-project [slug]` (reads `specs/{slug}/created-issues.json`, snapshots existing board items, adds each not-yet-on-board issue, sets Status=Blocked only when `status:blocked` is in `labels[]`)
  - Hard dependency: `to-issues` v3.2.0+ (consumes the `created-issues.json` contract from that schema, including the v3.2.0 `status:blocked` label emission rules)
  - github.com only: every `gh` invocation prefixed `GH_HOST=github.com`. No enterprise-host support
  - Audit artifact at `specs/{slug}/project-sync.json` (schema-validated, overwrite-with-atomic-rename, draft-07 schema co-shipped at `references/project-sync.schema.json`)
  - Idempotency: re-runs never overwrite a Status changed externally. `added_blocked_edit_failed` outcomes are marked `needs_status_retry: true` for recovery via deletion + re-run, or manual UI fix
  - Stable contracts for orchestrators: `RESULT: {...}` stdout sentinel as second-to-last line; `HALT: <code>` as final line on non-zero exit (14 codes documented)
  - `DRY_RUN=1` env var preserves the snapshot read (step 3); short-circuits all `item-add` / `item-edit` calls and emits per-issue `cli_command` for inspection. `ITP_GH_TIMEOUT_SECONDS` and `PROJECT_LIST_LIMIT` env vars override defaults
  - Pre-flight checks for `gh` presence / auth / version (≥ v2.13.0) / `project` OAuth scope before any `issue-to-project` config or spec read
  - Out of scope (deferred to v2): PR-open/merge lifecycle transitions, webhook listeners, bulk reconciliation, cross-repo project sync, non-Status field sync, automatic re-init on drift, `--retry-blocked-edits` recovery verb (annotation shipped in v1; verb in v2), per-`status:*` routing beyond `status:blocked`

## `to-issues` skill

- **3.2.0**
  - Rewrote `references/slice-patterns.md` for sagibeast topology — dropped `Context Boundary Detection` (k8s + AWS context labels that aren't in the v3.0.0 taxonomy and don't match sagibeast's stack) and dropped `Autonomous vs Needs Human Decision Tree` (governance signals belong on labels, not in a decision tree)
  - Added four named tracer-bullet shapes covering ~80% of sagibeast's data-flow topologies: **Web/API** (FastAPI request/response), **Brain agent / LangGraph node** (agent reasoning), **Pipeline** (Docling/BGE-M3/pgvector/MinIO ingest+query), **Cross-cutting** (middleware / Langfuse instrumentation / sandbox policy wraps). Each shape has 5 layers + an anti-pattern callout. Config-only and lifecycle/governance work are explicitly NOT tracer-shaped and handled in prose
  - Trimmed `Issue Body Quality Checklist` from 5 items to 4 (dropped the obsolete "Slice type — Autonomous or Needs Human" item)
  - Added `status:` as the **5th label dimension** (sparse — emitted only when non-default). Four documented values match the sagibeast GitHub Project board's `Status` field: `status:todo` (green `0E8A16`), `status:in-progress` (yellow `FBCA04`), `status:done` (purple `5319E7`), `status:blocked` (red `B60205`)
  - `to-issues` auto-emits **only** `status:blocked` on creation, when ANY of: (a) story has unresolved `dependencies.blockedBy`, (b) story was inferred as `type:future-enhancement`, (c) story's `stories[].labels` array contains the literal `status:blocked`
  - `status:in-progress` and `status:done` are reserved in the taxonomy so labels exist on the repo, but lifecycle transitions are deferred to a future `manage-github-project` skill (out of scope for v3.2.0)
  - Explicit operator override: any `status:*` value present in `stories[].labels` wins over inference; conflicts are logged in autonomous mode
  - `label-taxonomy.md` opening updated from "4-dimension label set" → "5-dimension label set" with a note that `status:` is sparse; dimensions table extended with a 5th row; new `## Status Dimension` subsection added; GitHub-label-creation color table extended with the four `status:*` colors. **`tier:` migrated from `5319E7` (purple) to `8B5CF6` (violet)** to free `5319E7` for `status:done`'s exact project-board match. `gh label create` is no-op-on-existing, so existing `tier:*` labels keep their old color — to force-recolor, run `gh label edit "tier:foundation" --color 8B5CF6 ...` manually.
  - `SKILL.md` Step 3 inference loop gains a 5th bullet (`status:`) that delegates to `references/label-taxonomy.md` `## Status Dimension` for rules. Reference-Files note updated to mention the 5th dimension. Description frontmatter updated from `(type/tier/tech/module)` → `(type/tier/tech/module/status)`
  - Backward compatible: existing `stories.json` infer exactly as in v3.1.0; the `status:` dimension is purely additive and sparse. No schema changes to `created-issues.schema.json` (labels[] already accepts the new values); no body-template changes to `issue-template.md` (status is a label, not body content)
  - Out of scope (deferred to future PRs): GitHub Project board column sync (PR-B `manage-github-project`); `needs-human-review` governance signal (would belong to a separate `review:` dimension if wanted later)

- **3.1.0**
  - Added `type:future-enhancement` as a 7th value in the `type:` dimension — for real work parked until a trigger condition is met (e.g. "wait until Brain v2", "v3 milestone", "icebox")
  - Trigger keywords: `future`, `someday`, `eventually`, `parked`, `deferred`, `icebox`, `backlog`, `wait until`, `after we`, `once we`, `when X then`, `v2`/`v3`/`vNext`, `milestone-2..9`
  - Future-enhancement issues SKIP the `tier:` label entirely (pre-phase work); `tech:` and `module:` still apply for filter visibility
  - New optional `stories[].description.trigger` field (free-form string) renders a `## Trigger Condition` section in the issue body when present; absent/empty → section omitted (zero visual noise for the common case)
  - Phase rendering for future-enhancement issues becomes `_n/a — future enhancement_` instead of the literal phase value
  - Label color added: `type:future-enhancement` → `D4C5F9` (lavender — distinguishes from active `type:` work at a glance)
  - `issue-template.md` bumped v1 → v2 (added `{{TRIGGER_CONDITION_BLOCK}}` placeholder)
  - Backward compatible: existing stories.json files infer correctly; new field is purely opt-in

- **3.0.0** (BREAKING)
  - Retarget `github.com` only — removed all `GH_HOST=github.concur.com`, `GH_ENTERPRISE_TOKEN`, and TLS-bypass references including the `compatibility:` frontmatter line
  - Project name now read from `.claude/config.json` (`"project"` key, fallback `"sagibeast"`); legacy `.claude/rules/project-information.md` is detected and a migration warning is emitted, but the file is no longer written
  - Added 4-dimension label taxonomy in new `references/label-taxonomy.md` — `type` inferred from story keywords (default `feat`), `tier` from `stories[].phase`, `tech` from extensible keyword map, `module` from ADR folder-name pattern match (no ADR content reads)
  - Added `references/issue-template.md` — versioned `{{PLACEHOLDER}}` body template; single edit point for issue body format
  - Added `references/created-issues.schema.json` — JSON Schema (draft-07) for the new `specs/<slug>/created-issues.json` artifact consumed by `makato-build/build-create-pr`
  - Added `DRY_RUN=1` mode — prints assembled `gh` commands and writes a schema-valid artifact with synthetic issue numbers without touching the GitHub API
  - Removed `references/project-info-format.md` (obsolete mechanism)
  - Defined partial-failure semantics: halt batch on first `gh issue create` failure, persist partial artifact, exit non-zero (no rollback)
  - Migration: copy your project name into `.claude/config.json` (`{ "project": "<name>" }`); delete `.claude/rules/project-information.md` if present

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

- **1.1.0**
  - surface-by-surface N+3 pass generation (Fix B): Pass 1 writes head+CSS+chrome, Passes 2…N+1 write one slide each, Pass N+2 writes JS+close, Pass N+3 assembles and validates — no single tool call output exceeds ~200 lines
  - incremental write+append assembly (Fix E): each fragment appended to OUTPUT_PATH in order; assembly overhead is negligible vs. single-buffer write
  - temp fragment naming convention: `prototype-head.tmp`, `prototype-slide-{n}.tmp`, `prototype-js.tmp` — all cleaned up on success and failure, no orphaned files
  - failure recovery: re-dispatch targets only the failing slide fragment; surviving fragments are preserved and re-assembled
  - validation is a single read + structural grep — not an LLM re-parse; checks `<!DOCTYPE>`, slide count, external refs, lorem ipsum, file size
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

## `arch-ux` skill

- **1.0.0**
  - Initial — create UX design documents with screen inventory, wireframes, interaction patterns, user testing plan, and accessibility notes for PRD UI surfaces

## Plugin-level

- **0.2.0**
  - rename `shared/glossary.md` → `shared/terminology.md` to free the word *glossary* for the new per-spec, runtime-written glossary produced by the `grill` skill. The plugin-level file remains a contributor-maintained terminology reference; the per-spec `glossary.md` is the feature-scoped, agent-read vocabulary
  - update README, AGENTS.md, and the file's own header to reflect the rename and clarify the two layers
- **0.1.0** — 2026-05-12
  - initial plugin with governance files, plugin manifest (`plugin.json`), contributor guide (`AGENTS.md`)
  - cross-skill `shared/` resources (`scenario-schema.md`, `repositories-yml-schema.md`, `refinement-contract.md`, `glossary.md` — renamed to `terminology.md` in 0.2.0) wired via [within-plugin symlinks](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks). Each consuming skill carries `skills/<name>/shared` → `../../shared`, and skill files reference resources as plain `shared/<file>.md` (no `../`). Replaces the prior `@../../shared/...` notation, which did not resolve at runtime under cached plugin installs.
