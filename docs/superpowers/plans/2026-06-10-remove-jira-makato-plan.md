# Remove Jira — makato-plan Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all Jira/DCP coupling from the 9 makato-plan skills, making the pipeline
fully provider-agnostic with GitHub.com as the only optional external integration.

**Architecture:** Each skill is a self-contained markdown file. Changes are pure text edits
— no code compilation, no tests. Verification is grep-based (no Jira term should survive)
plus a manual read of the two most-changed files. The `publish` skill is a full rewrite;
`brainstorming` is a structural rework; the other 6 skills need targeted find-replace edits.

**Tech Stack:** Markdown files, bash grep for verification, git for commits.

---

## File Map

| Action | File |
|--------|------|
| Full rewrite | `plugins/makato-plan/skills/brainstorming/SKILL.md` |
| Full rewrite | `plugins/makato-plan/skills/publish/SKILL.md` |
| Delete | `plugins/makato-plan/skills/publish/references/jira-field-mapping.md` |
| Delete | `plugins/makato-plan/skills/publish/references/dcp-story-panels.md` |
| Delete | `plugins/makato-plan/skills/publish/references/subtask-templates.md` |
| Delete | `plugins/makato-plan/skills/publish/references/confluence-page-template.md` |
| Create | `plugins/makato-plan/skills/publish/references/github-issue-template.md` |
| Targeted edit | `plugins/makato-plan/skills/decompose/SKILL.md` |
| Full rewrite | `plugins/makato-plan/skills/decompose/references/stories-json-schema.md` |
| Full rewrite | `plugins/makato-plan/skills/decompose/references/dcp-story-template.md` |
| Full rewrite | `plugins/makato-plan/skills/decompose/references/team-repository-mapping.md` |
| Targeted edit | `plugins/makato-plan/skills/create-prd/SKILL.md` |
| Targeted edit | `plugins/makato-plan/skills/create-architecture/SKILL.md` |
| Targeted edit | `plugins/makato-plan/skills/create-acceptance-tests/SKILL.md` |
| Targeted edit | `plugins/makato-plan/skills/create-prototype/SKILL.md` |

---

## Task 1: Rewrite `brainstorming/SKILL.md`

**Files:**

- Modify: `plugins/makato-plan/skills/brainstorming/SKILL.md`

The current skill hard-gates on a Jira ITDB key. Replace the entire workflow with
4-way input detection, slug-only folder naming, and GitHub MCP for attachments.

- [ ] **Step 1: Replace frontmatter and intro block**

Replace lines 1–26 (frontmatter through "When NOT to Use") with:

```markdown

---
name: brainstorming
description: Structured divergent-convergent ideation on a feature — brainstorm,
  explore ideas, creative exploration. Use when starting a new feature that needs
  ideation before PRD.
version: "1.2.0"
model: opus
---

# Brainstorming Ideas Into Designs

Structured exploration of a feature through divergent ideation (62 techniques) followed
by convergent selection (top 3-5 concepts with rationale). Produces documented decisions
ready for grilling and PRD creation.

## When to Use

- Starting work on a new feature that needs creative exploration
- Need structured ideation before committing to an approach
- Want to ensure all angles are explored before PRD
- Comparing multiple approaches to a feature

## When NOT to Use

- Feature is already well-defined with clear requirements (go straight to PRD)
- Quick bug fix or small change (no brainstorming needed)
- Technical refinement of already-pland stories

---

```text

- [ ] **Step 2: Replace Step 1 (Load ITDB Feature) with 4-way input detection**

Replace the entire `### Step 1: Load ITDB Feature` section (lines 30–43) and the
`### Step 1.1: Import Attachments` section (lines 45–108) with:

```markdown

### Step 1: Detect Feature Origin

When the user runs `/brainstorming [arg]`, detect the origin in this order:

**1. GitHub Issue** — arg matches `https://github.com/owner/repo/issues/123`
or short form `owner/repo#123`:

Use the GitHub MCP to fetch the issue:

```text

mcp: mcp__plugin_general_github-mcp__get_issue(owner, repo, issue_number)

```text

Extract: title, body. Slug is derived from the issue title (kebab-case, max 60 chars).
Record `source: "github:{owner}/{repo}#{number}"` — this will be written to
`stories.json` later.

Offer to import attachments if any exist on the issue.

**2. Existing slug** — `specs/{arg}/` directory exists on disk:

```bash

ls specs/{arg}/

```text

If found → resume prior session. Load existing `brainstorm.md` and `decisions.md`.

**3. Plain text** — any other non-empty arg:

Use the arg as the feature description. Derive the slug from it:

- Lowercase, replace spaces and special chars with hyphens
- Truncate to 60 chars
- Example: "Checkout cart redesign" → `checkout-cart-redesign`

**4. No arg** — auto-detect most recently modified `specs/*/` folder:

```bash

ls -td specs/*/ | head -1

```text

If a folder exists → offer to resume it. If no `specs/` folder or user declines
→ prompt: "Describe the feature in one line:" and derive slug from their answer.

---

After detecting origin, determine the spec folder path: `specs/{slug}/`

Present a brief summary and confirm this is the feature to brainstorm.

---

### Step 1.1: Import Attachments (GitHub Issue origin only)

Skip this step if origin was plain text or existing slug with no new attachments.

Check if reference files already exist:

```bash

ls specs/{slug}/reference/original/

```text

**If `reference/original/` exists and is non-empty**: prior import completed.
Load converted markdown from `reference/*.md` and images from `reference/original/`
as context. Inform the user:
> "Found existing reference files — loading as context."

**If no reference directory or empty**: check for attachments on the GitHub Issue.

If attachments exist, offer download:

```text

AskUserQuestion:
  question: "Issue has {N} attachments. Import for brainstorming context?"
  options:

    - "Yes — download all (Recommended)"
    - "Images only"
    - "Skip — brainstorm without attachments"

```text

**If "Yes — download all" accepted:**

1. Download every attachment to `specs/{slug}/reference/original/`.

   Write base64-decoded bytes to disk for every attachment — visual inspection is
   not a substitute. Skipping the write step is a bug.

2. Resolve the absolute path to the reference directory:

   ```bash

   realpath specs/{slug}/reference/original/

   ```text

3. Convert non-image files to markdown using markitdown:

   ```text

   mcp: markitdown convert_to_markdown(uri: "file://{resolved_path}/{filename}")

   ```text

   Save output as `specs/{slug}/reference/{filename}.md`.

4. Verify every attachment landed on disk before continuing:

   ```bash

   ls specs/{slug}/reference/original/

   ```text

5. Images remain in `reference/original/` — read them visually via the Read tool

   (multimodal) when needed during ideation.

**If "Images only" accepted:**

1. Download image attachments to `specs/{slug}/reference/original/`.
2. Verify with `ls specs/{slug}/reference/original/` that every image is saved.
3. No conversion step.

**Directory layout:**

```text

reference/
├── feature-brief.md      ← converted markdown (what skills consume as text)
└── original/
    ├── feature-brief.pptx  ← source binary (provenance)
    └── screenshot.png       ← images read directly via Read tool

```text

Use markdown files in `reference/` as text context. For images in `reference/original/`,
describe them visually using the Read tool (multimodal).

```text

- [ ] **Step 3: Replace Step 1.2 context-scout reference to ITDB**

In `### Step 1.2: Scan Repository Context`, replace:

```text

Spawn the `context-scout` agent with the ITDB summary and keywords.

```text

with:

```text

Spawn the `context-scout` agent with the feature summary and keywords.

```text

- [ ] **Step 4: Replace Step 1.3 folder glob pattern**

In `### Step 1.3: Open Questions Startup Check`, replace:

```bash

ls specs/*{ITDB-KEY}*/decisions.md

```text

with:

```bash

ls specs/{slug}/decisions.md

```text

- [ ] **Step 5: Replace Step 2 folder glob patterns**

In `### Step 2: Session Setup`, replace:

```bash

ls specs/*{ITDB-KEY}*/brainstorm.md

```text

with:

```bash

ls specs/{slug}/brainstorm.md

```text

And replace:

```text

1. Confirm the brainstorming topic (derived from ITDB + context)
2. Set goals: what does a successful brainstorm look like?
3. Identify known constraints (from ITDB + context-scout + attachments)

```text

with:

```text

1. Confirm the brainstorming topic (derived from feature description + context)
2. Set goals: what does a successful brainstorm look like?
3. Identify known constraints (from feature description + context-scout + attachments)

```text

- [ ] **Step 6: Replace Step 3 ITDB reference in technique selection**

In `### Step 3: Technique Selection`, replace:

```text

    - "AI-recommended based on the ITDB type (Recommended)"

```text

with:

```text

    - "AI-recommended based on the feature type (Recommended)"

```text

And replace:

```text

For AI-recommended: analyze the ITDB content and suggest 2-3 techniques from different
categories that fit the problem type

```text

with:

```text

For AI-recommended: analyze the feature description and suggest 2-3 techniques from
different categories that fit the problem type

```text

- [ ] **Step 7: Replace Step 7 HTML review OUTPUT_PATH and content fields**

In `### Step 7: HTML Review & Approval Gate`, replace:

```text

  - **OUTPUT_PATH**: `specs/{ITDB-KEY}-{slug}/reviews/brainstorm-review.html`
  - **CONTENT**: structured brainstorming results including:
    - feature_name (ITDB summary)
    - date (today)
    - epic_key (ITDB key)

```text

with:

```text

  - **OUTPUT_PATH**: `specs/{slug}/reviews/brainstorm-review.html`
  - **CONTENT**: structured brainstorming results including:
    - feature_name (feature summary)
    - date (today)
    - slug (feature slug)

```text

And replace all three `open` commands:

```bash

open specs/{ITDB-KEY}-{slug}/reviews/brainstorm-review.html        # macOS
xdg-open specs/{ITDB-KEY}-{slug}/reviews/brainstorm-review.html    # Linux
start specs/{ITDB-KEY}-{slug}/reviews/brainstorm-review.html       # Windows

```text

with:

```bash

open specs/{slug}/reviews/brainstorm-review.html        # macOS
xdg-open specs/{slug}/reviews/brainstorm-review.html    # Linux
start specs/{slug}/reviews/brainstorm-review.html       # Windows

```text

- [ ] **Step 8: Replace Step 8 artifact OUTPUT_PATH**

In `### Step 8: Write Artifacts`, replace:

```text

  - **OUTPUT_PATH**: `specs/{ITDB-KEY}-{slug}/`

```text

with:

```text

  - **OUTPUT_PATH**: `specs/{slug}/`

```text

And replace:

```text

Files written:

- `specs/{ITDB-KEY}-{slug}/brainstorm.md` — all ideas, themes, top concepts
- `specs/{ITDB-KEY}-{slug}/decisions.md` — decisions + open questions with Q# IDs

```text

with:

```text

Files written:

- `specs/{slug}/brainstorm.md` — all ideas, themes, top concepts
- `specs/{slug}/decisions.md` — decisions + open questions with Q# IDs

```text

- [ ] **Step 9: Verify no Jira/ITDB terms remain**

```bash

grep -n "ITDB\|jira\|Jira\|confluence\|Confluence" \
  plugins/makato-plan/skills/brainstorming/SKILL.md

```text

Expected: no output.

- [ ] **Step 10: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/brainstorming/SKILL.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "feat(makato-plan): rework brainstorming — 4-way input, slug-only folders, no Jira"

```text

---

## Task 2: Rewrite `publish/SKILL.md`

**Files:**

- Modify: `plugins/makato-plan/skills/publish/SKILL.md`

The current skill is 100% Jira + Confluence. Replace entirely with the new design:
local handoff always, GitHub Issues only if `makato.config.yml` configures it.

- [ ] **Step 1: Replace the entire file content**

Write the full new `publish/SKILL.md`:

```markdown

---
name: publish
description: Publish pland stories — create handoff summary, story folders, and
  optionally GitHub Issues. Use after stories.json is approved.
version: "2.0.0"
model: sonnet
argument-hint: "[slug]"
---

# Publish

Publish pland artifacts from `stories.json`. Always produces a local handoff — a
`handoff.md` summary and story subfolders. Optionally creates GitHub Issues if
`makato.config.yml` configures a GitHub provider.

## When to Use

- After `stories.json` is approved (status: "approved")
- Ready to hand off pland work to development teams
- Want a machine-readable handoff summary with all story details
- Want to optionally create GitHub Issues for the epic stories

## When NOT to Use

- `stories.json` doesn't exist yet (run `/decompose` first)
- Want to modify existing GitHub Issues during sprint (use makato-build refine)
- Want to assign stories to sprints or people (that's sprint planning)

---

## Workflow

### Step 1: Resolve Spec Folder & Validate

#### 1.1: Resolve Spec Folder

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text

Args: /publish [slug]
Examples:
  /publish checkout-redesign    → use specs/checkout-redesign/
  /publish                      → auto-detect most recently modified specs/ folder

```text

If no spec folder found, inform the user and suggest running upstream skills first.

#### 1.2: Load and Validate stories.json

Read `stories.json` from the resolved spec folder. Validate:

1. File exists and is valid JSON
2. Has `version: "2.0"` (warn if older — schema mismatch may cause issues)
3. Has `epic` object with `summary` and `objective`
4. Has at least one story in `stories[]`
5. Check `status` field:

```text

If status == "approved" → proceed
If status == "draft" →
  AskUserQuestion:
    question: "stories.json status is 'draft' (not yet approved). Publish anyway?"
    options: ["Yes, publish draft", "No, abort"]
  If "No" → exit with message to approve first

```text

#### 1.3: Check Idempotency State

Check if stories.json already has `githubIssue` fields (from a previous publish run):

- Any `stories[].githubIssue` exists → report "Resuming previous publish — N stories

  already published."

- No `githubIssue` fields → fresh publish.

---

### Step 2: Load Supporting Artifacts

Read from the spec folder (all optional, for linking in handoff.md):

- `prd.md`
- `design.md`
- `prototype.html`
- `decisions.md`

Note which artifacts exist. Missing artifacts are simply not linked.

---

### Step 3: Detect Git Remote URL

Auto-detect the repository URL for artifact links in handoff.md:

```bash

git remote get-url origin

```text

Transform SSH URLs to HTTPS browse URLs:

- `git@github.com:owner/repo.git` → `https://github.com/owner/repo`
- `https://github.com/owner/repo.git` → `https://github.com/owner/repo`

Determine the default branch for building file links:

```bash

git symbolic-ref refs/remotes/origin/HEAD

```text

Build artifact URLs (where `{slug}` is the spec folder name):

- PRD: `{repoUrl}/blob/{branch}/specs/{slug}/prd.md`
- Design: `{repoUrl}/blob/{branch}/specs/{slug}/design.md`
- Prototype: `{repoUrl}/blob/{branch}/specs/{slug}/prototype.html`

---

### Step 4: Write handoff.md

Write `specs/{slug}/handoff.md` with this structure:

```markdown

# Handoff: {epic.summary}

**Objective:** {epic.objective}
**Published:** {today ISO date}
**Stories:** {N} ({foundation count} foundation,
  {happy-path count} happy-path, {edge-cases count} edge-cases)
**Total SP:** {sum of storyPoints}

## Shaping Artifacts

- [PRD]({prdUrl}) ← only if prd.md exists
- [Design]({designUrl}) ← only if design.md exists
- [Prototype]({prototypeUrl}) ← only if prototype.html exists

## Stories

| # | Summary | Phase | SP | Teams |
|---|---------|-------|----|-------|
| 1 | {story.summary} | {story.phase} | {story.storyPoints} | {story.teams joined} |
...

## Story Details

### Story 1: {story.summary}

**Background:** {story.description.background}

**Scope:** {story.description.scope}

**Definition of Done:**
{story.definitionOfDone as bullet list}

**Acceptance Scenarios:**
{story.description.successScenarios rendered as Gherkin — Given/When/Then}

**Dependencies:** {story.dependencies.blockedBy as "blocked by story N" list, or "none"}

**External Dependencies:** {story.externalDependencies as bullet list, or "none"}

---

```text

Repeat the Story Details block for every story in sequence order.

---

### Step 5: Create Story Subfolders

Create one subfolder per story inside the spec folder:

Pattern: `specs/{slug}/{sequence:02d}-{story-slug}/`

Story slug rules:

- Take `story.summary`
- Strip any `[Component]` prefix tag if present
- Lowercase, replace spaces and special chars with hyphens
- Truncate to 60 chars

```bash

mkdir -p specs/{slug}/01-{story-1-slug}/
touch specs/{slug}/01-{story-1-slug}/.gitkeep
# repeat for each story

```text

Example after publish:

```text

specs/checkout-redesign/
├── brainstorm.md
├── prd.md
├── design.md
├── stories.json
├── handoff.md          ← written in Step 4
├── 01-cart-validation-service/
│   └── .gitkeep
├── 02-realtime-cart-errors/
│   └── .gitkeep
└── 03-quantity-limit-rule/
    └── .gitkeep

```text

---

### Step 6: Check for GitHub Provider Config

Read `makato.config.yml` from the repository root (the directory containing the
`specs/` folder):

```bash

cat makato.config.yml 2>/dev/null

```text

If the file is absent or `provider` is not `github` → skip to Step 10 (final summary).
If `provider: github` → continue to Step 7.

---

### Step 7: Resolve GitHub Repo Target

Read `github.repo` from `makato.config.yml`. If absent, ask:

```text

AskUserQuestion:
  question: "Which GitHub repo should the Issues be created in?"
  (free-form answer: owner/repo-name)

```text

Store as `{owner}/{repo}` for all subsequent GitHub operations.

---

### Step 8: Confirm GitHub Creation Plan

```text

AskUserQuestion:
  question: "Ready to create GitHub Issues in {owner}/{repo}. Confirm?"

  Show:

  - Milestone: {epic.summary}
  - Issues ({N}):
    1. {story.summary} ({story.storyPoints} SP) [CREATE]
    2. ...

  options:

    - "Proceed"
    - "Abort"

```text

If aborted → skip to Step 10 (print local-only summary).

---

### Step 9: Create GitHub Milestone and Issues

#### 9.1: Create Milestone for the Epic

```text

mcp: mcp__plugin_general_github-mcp__create_milestone(
  owner: {owner},
  repo: {repo},
  title: {epic.summary},
  description: {epic.objective}
)

```text

Save the returned milestone number for use in issue creation.

#### 9.2: Create One Issue per Story

Load @references/github-issue-template.md for the issue body template.

For each story in sequence order:

If `story.githubIssue` already exists → skip (idempotency).

Render the issue body from the template using the story fields, then:

```text

mcp: mcp__plugin_general_github-mcp__create_issue(
  owner: {owner},
  repo: {repo},
  title: "[{story.phase}] {story.summary}",
  body: {renderedBody},
  milestone: {milestoneNumber},
  labels: {story.labels}
)

```text

Save the returned issue number to `story.githubIssue` in `stories.json`
immediately after each creation.

---

### Step 10: Final Summary

Print the complete publish result:

```text

✓ Publish complete

Spec folder: specs/{slug}/
handoff.md: written
Story folders: {N} created (01-{slug}/ … {N:02d}-{slug}/)

{if GitHub provider was used:}
GitHub: {owner}/{repo}
  Milestone: #{milestoneNumber} — {epic.summary}
  Issues:

    1. #{issueNumber} — {story.summary}
    2. ...

{end if}

{if local-only:}
GitHub Issues: skipped (no provider configured in makato.config.yml)
To enable: add `provider: github` to makato.config.yml
{end if}

```text

---

## Error Handling

- **Stop on error**: if any GitHub operation fails, stop immediately and report the error.
- **Progress saved**: after each successful issue creation, `githubIssue` is written to

  `stories.json`. A re-run will skip already-created items.

- **Local handoff always succeeds**: Steps 4 and 5 (handoff.md and folders) never

  depend on GitHub — they always run regardless of provider config.

```text

- [ ] **Step 2: Verify no Jira/Confluence terms remain**

```bash

grep -n "jira\|Jira\|JIRA\|confluence\|Confluence\|ITDB\|DCP\|pi_planning\|jiraKey\|subtaskKeys\|epicLink\|customfield" \
  plugins/makato-plan/skills/publish/SKILL.md

```text

Expected: no output.

- [ ] **Step 3: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/publish/SKILL.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "feat(makato-plan): rewrite publish — local handoff always, GitHub Issues optional"

```text

---

## Task 3: Delete Jira/Confluence Reference Files from `publish/references/`

**Files:**

- Delete: `plugins/makato-plan/skills/publish/references/jira-field-mapping.md`
- Delete: `plugins/makato-plan/skills/publish/references/dcp-story-panels.md`
- Delete: `plugins/makato-plan/skills/publish/references/subtask-templates.md`
- Delete: `plugins/makato-plan/skills/publish/references/confluence-page-template.md`

- [ ] **Step 1: Delete the four files**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  rm plugins/makato-plan/skills/publish/references/jira-field-mapping.md \
     plugins/makato-plan/skills/publish/references/dcp-story-panels.md \
     plugins/makato-plan/skills/publish/references/subtask-templates.md \
     plugins/makato-plan/skills/publish/references/confluence-page-template.md

```text

- [ ] **Step 2: Verify deletion**

```bash

ls /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato/plugins/makato-plan/skills/publish/references/

```text

Expected: only `skill-plan.html` remains (plus the new `github-issue-template.md`
from Task 4).

- [ ] **Step 3: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "chore(makato-plan): delete Jira/Confluence reference files from publish"

```text

---

## Task 4: Create `publish/references/github-issue-template.md`

**Files:**

- Create: `plugins/makato-plan/skills/publish/references/github-issue-template.md`

- [ ] **Step 1: Write the new file**

```markdown

# GitHub Issue Body Template

Use this template when rendering a story from `stories.json` into a GitHub Issue body.
Replace each `{{placeholder}}` with the corresponding story field value.

---

## Background

{{story.description.background}}

## Scope

{{story.description.scope}}

## Acceptance Scenarios

{{story.description.successScenarios — render each as:}}

**{{scenario.title}}**

```gherkin

Given {{scenario.given}}
When {{scenario.when}}
Then {{scenario.then}}
{{#each scenario.and}}And {{this}}{{/each}}

```text

{{/each}}

## Definition of Done

{{story.definitionOfDone — render each item as a task list:}}

- [ ] {{dod item 1}}
- [ ] {{dod item 2}}

## Out of Scope

{{story.description.outOfScope — render as bullet list, or "None"}}

## Feature Toggle

- Already in place: {{story.description.featureToggle.alreadyInPlace}}
- New needed: {{story.description.featureToggle.newNeeded}}
- Name: {{story.description.featureToggle.name or "N/A"}}
- Default state: {{story.description.featureToggle.defaultState or "N/A"}}

## External Dependencies

{{story.externalDependencies — render each as "Team: description (status)",
or "None"}}

## Shaping Artifacts

- [PRD]({{prdUrl}}) ← omit line if prd.md does not exist
- [Design]({{designUrl}}) ← omit line if design.md does not exist
- [Prototype]({{prototypeUrl}}) ← omit line if prototype.html does not exist

---

Published by makato-plan/publish

```text

- [ ] **Step 2: Verify file exists**

```bash

ls /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato/plugins/makato-plan/skills/publish/references/github-issue-template.md

```text

Expected: file listed.

- [ ] **Step 3: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/publish/references/github-issue-template.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "feat(makato-plan): add github-issue-template for publish GitHub provider"

```text

---

## Task 5: Update `decompose/references/stories-json-schema.md`

**Files:**

- Modify: `plugins/makato-plan/skills/decompose/references/stories-json-schema.md`

Rewrite to schema v2.0: remove all Jira fields, add `slug`/`source`/`githubIssue`.

- [ ] **Step 1: Replace the Top-Level Structure section**

Replace lines 1–21 (the intro note and top-level JSON block) with:

```markdown

# stories.json Schema

> Canonical schema for `stories.json` (version 2.0). The scenario object used inside
> `successScenarios[]` and `acceptanceTestCases[]` is defined in the shared scenario
> schema — read `shared/scenario-schema.md` (sibling of this skill's SKILL.md).
> Do not redefine the scenario plan here.

## Top-Level Structure

```json

{
  "version": "2.0",
  "slug": "checkout-redesign",
  "source": "github:owner/repo#123",
  "created": "2026-05-14",
  "status": "draft",
  "epic": {
    "summary": "Epic title",
    "objective": "One-line objective statement",
    "labels": ["makato"]
  },
  "stories": [ ... ]
}

```text

`source` is optional — omit when the feature originated from plain text, not a
GitHub Issue.

```text

- [ ] **Step 2: Replace the Story Object section**

Replace the Story Object JSON block to remove `jiraKey` and add `githubIssue`:

```json

{
  "sequence": 1,
  "phase": "foundation",
  "summary": "User outcome title",
  "storyPoints": 3,
  "teams": ["team-name"],
  "labels": ["makato"],
  "githubIssue": null,
  "description": {
    "background": "Why this story exists, context...",
    "scope": "What to build — specific, bounded...",
    "featureToggle": {
      "alreadyInPlace": false,
      "newNeeded": true,
      "longTermUsage": false,
      "name": "feature-name.enabled",
      "defaultState": "disabled"
    },
    "successScenarios": [
      {
        "title": "Scenario 1: Happy path",
        "given": "...",
        "when": "...",
        "then": "...",
        "and": ["Optional additional Then assertions"]
      }
    ],
    "solutionApproach": "",
    "acceptanceTestCases": [],
    "wikiDocumentation": "",
    "outOfScope": ["Explicit exclusion 1"]
  },
  "definitionOfDone": [
    "User can do X without Y",
    "Error code ABC returned when condition met"
  ],
  "dependencies": {
    "blockedBy": [],
    "blocks": [2, 3]
  },
  "externalDependencies": [
    {
      "team": "Platform Team",
      "description": "Need API X to be available",
      "status": "pending"
    }
  ]
}

```text

- [ ] **Step 3: Replace the Field Reference table**

Replace the entire `## Field Reference` table to remove Jira-specific fields and add
the new ones:

```markdown

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | string | Yes | Always `"2.0"` |
| `slug` | string | Yes | Kebab-case feature identifier — the spec folder name |
| `source` | string | No | `"github:owner/repo#123"` if origin was a GitHub Issue |
| `created` | string | Yes | ISO date |
| `status` | string | Yes | `"draft"` or `"approved"` |
| `epic.summary` | string | Yes | Epic title |
| `epic.objective` | string | Yes | One-liner stakeholder-facing objective |
| `epic.labels` | string[] | Yes | Always includes `"makato"` |
| `stories[].sequence` | number | Yes | Order (1 = walking skeleton) |
| `stories[].phase` | enum | Yes | `"foundation"` / `"happy-path"` / `"edge-cases"` |
| `stories[].summary` | string | Yes | Story title |
| `stories[].storyPoints` | number | Yes | Fibonacci (1,2,3,5,8,13) |
| `stories[].teams` | string[] | Yes | Free-text team names — user-defined |
| `stories[].labels` | string[] | Yes | Always includes `"makato"` |
| `stories[].githubIssue` | number | No | Set by `publish` when GitHub provider used |
| `stories[].description.background` | string | Yes | Context/rationale |
| `stories[].description.scope` | string | Yes | Bounded scope statement |
| `stories[].description.featureToggle` | object | Yes | Toggle configuration |
| `stories[].description.successScenarios` | array | Yes | 1-3 high-level Gherkin (draft) |
| `stories[].description.solutionApproach` | string | No | Empty — filled during refinement |
| `stories[].description.acceptanceTestCases` | array | No | Empty — filled by create-acceptance-tests |
| `stories[].description.wikiDocumentation` | string | No | Empty — filled post-implementation |
| `stories[].description.outOfScope` | string[] | No | Explicit exclusions |
| `stories[].definitionOfDone` | string[] | Yes | 3-5 story-specific product conditions |
| `stories[].dependencies.blockedBy` | number[] | No | Other story sequences |
| `stories[].dependencies.blocks` | number[] | No | Other story sequences |
| `stories[].externalDependencies` | array | No | External team dependencies |

```text

- [ ] **Step 4: Delete the Jira Field Mapping section entirely**

Remove the `## Jira Field Mapping` section (the entire table at the bottom of the file).

- [ ] **Step 5: Verify no Jira terms remain**

```bash

grep -n "jira\|Jira\|JIRA\|ITDB\|pi_planning\|epic\.pi\|jiraKey\|customfield\|epicLink" \
  plugins/makato-plan/skills/decompose/references/stories-json-schema.md

```text

Expected: no output.

- [ ] **Step 6: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/decompose/references/stories-json-schema.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "feat(makato-plan): bump stories.json schema to v2.0 — remove Jira fields"

```text

---

## Task 6: Rewrite `decompose/references/dcp-story-template.md`

**Files:**

- Modify: `plugins/makato-plan/skills/decompose/references/dcp-story-template.md`

The file is entirely DCP/Jira wiki-markup rendering. Replace with a generic markdown
rendering guide for the GitHub Issue template and the handoff.md format.

- [ ] **Step 1: Replace the entire file content**

```markdown

# Story Rendering Guide

Describes how story fields from `stories.json` render into two outputs:
`handoff.md` (always) and GitHub Issue body (when GitHub provider is configured).

## Sections Filled by Decompose vs. Deferred

| Section | Filled by Decompose | Notes |
|---------|---------------------|-------|
| Background | Yes | Why this story exists |
| Scope | Yes | Bounded description of what to build |
| Dependencies | Yes | External team dependencies |
| Feature Toggle | Yes | At minimum newNeeded yes/no |
| Success Scenarios | Yes (draft) | 1-3 high-level Gherkin from QA agent |
| Solution Approach | No | Left empty — team fills during refinement |
| Acceptance Tests | No | Left empty — QAs fill via acceptance-tests skill |
| Wiki Documentation | No | Left empty — team fills post-implementation |
| Out of Scope | Yes | Explicit boundaries |

## Gherkin Rendering

Success scenarios render as fenced Gherkin code blocks:

```gherkin

Given the user has items in their cart
When they proceed to checkout
Then the total is calculated correctly

```text

If a scenario has `and[]` entries, render them as `And ...` continuation lines after
`Then`.

## Definition of Done Rendering

Render as a GitHub-flavoured markdown task list:

```markdown

- [ ] User can complete checkout without errors
- [ ] Toggle `checkout.redesign.enabled` controls the feature independently

```text

## handoff.md vs. GitHub Issue

Both outputs use the same story fields. The difference is context:

- **handoff.md** — flat markdown, no interactive checkboxes, appended to a single

  file that covers the entire epic

- **GitHub Issue** — uses the template at

  `publish/references/github-issue-template.md`; each story is its own issue

See `github-issue-template.md` in the publish skill for the full GitHub Issue
body template.

```text

- [ ] **Step 2: Verify no Jira terms remain**

```bash

grep -n "jira\|Jira\|JIRA\|panel\|wiki markup\|DCP\|customfield" \
  plugins/makato-plan/skills/decompose/references/dcp-story-template.md

```text

Expected: no output.

- [ ] **Step 3: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/decompose/references/dcp-story-template.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "chore(makato-plan): replace dcp-story-template with generic rendering guide"

```text

---

## Task 7: Rewrite `decompose/references/team-repository-mapping.md`

**Files:**

- Modify: `plugins/makato-plan/skills/decompose/references/team-repository-mapping.md`

Remove DCP-specific team names and Jira `customfield` reference. Make it a generic guide.

- [ ] **Step 1: Replace the entire file content**

```markdown

# Team-Repository Mapping

## Usage

During decomposition, stories are assigned to teams based on which repositories
they touch. This file holds the mapping for the current project.

**This file is project-specific** — update it with the actual teams and repositories
for the project you are working on. The entries below are examples only.

## Example Mapping

| Team | Repositories | Focus |
|------|-------------|-------|
| Platform | platform-core, shared-libs | Shared infrastructure and utilities |
| Frontend | web-app, mobile-app | User-facing interfaces |
| Backend | api-service, data-service | Business logic and data access |

## Mapping Logic

1. Identify repositories from `repositories.yml`
2. Match to teams using the table above
3. Present proposed mapping to user for confirmation
4. If a story touches repos from multiple teams → assign all relevant teams
5. If a story is pure integration (no single repo owns it) → assign the team closest

   to the user-facing outcome

## When Mapping Fails

If the user identifies a repository or team not in this table:

- Accept their input as authoritative
- Note: this reference should be updated with new mappings for future sessions

## teams Field in stories.json

`stories[].teams` is a free-text string array. Enter team names exactly as your
project uses them. There is no fixed allowlist.

```text

- [ ] **Step 2: Verify no DCP/Jira terms remain**

```bash

grep -n "DCP\|jira\|Jira\|customfield\|ITDB" \
  plugins/makato-plan/skills/decompose/references/team-repository-mapping.md

```text

Expected: no output.

- [ ] **Step 3: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/decompose/references/team-repository-mapping.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "chore(makato-plan): make team-repository-mapping generic — remove DCP names"

```text

---

## Task 8: Targeted Edits to `decompose/SKILL.md`

**Files:**

- Modify: `plugins/makato-plan/skills/decompose/SKILL.md`

Three targeted find-replace edits: frontmatter `argument-hint`, folder glob patterns,
and Jira next-step references.

- [ ] **Step 1: Update frontmatter argument-hint**

Replace:

```yaml

argument-hint: "[ITDB-KEY]"

```text

with:

```yaml

argument-hint: "[slug]"

```text

- [ ] **Step 2: Replace all `specs/{ITDB-KEY}-*/` folder glob patterns**

Replace all occurrences of `specs/{ITDB-KEY}-*/` with `specs/*/`.

Also replace argument examples like:

```text

Args: /decompose [ITDB-KEY]
Examples:
  /decompose ITDB-1234    → use specs/ITDB-1234-*/  (prefix match)
  /decompose              → auto-detect most recently modified specs/ folder

```text

with:

```text

Args: /decompose [slug]
Examples:
  /decompose checkout-redesign    → use specs/checkout-redesign/
  /decompose                      → auto-detect most recently modified specs/ folder

```text

- [ ] **Step 3: Remove Jira next-step references in When NOT to Use**

Replace:

```text

- Want to create Jira issues (that's the publish skills downstream)

```text

with:

```text

- Want to create GitHub Issues (that's the publish skill downstream)

```text

- [ ] **Step 4: Fix epic.objective prompt — remove "appears on Jira epic"**

In the Round 3 epic objective capture section, replace:

```text

> "What's the one-line objective for this epic? (Stakeholder-facing — appears on
> the Confluence spec page and Jira epic.)"

```text

with:

```text

> "What's the one-line objective for this epic? (Stakeholder-facing — appears in
> handoff.md and optionally as the GitHub milestone description.)"

```text

- [ ] **Step 5: Fix decompose's ITDB feature references in header**

Replace:

```text

- After PRD and architecture design are complete (ideally Approved) for an ITDB feature

```text

with:

```text

- After PRD and architecture design are complete (ideally Approved)

```text

Replace:

```text

- Want vertically-sliced stories with acceptance criteria and story point estimates

```text

Keep as-is (no change needed here).

- [ ] **Step 6: Fix stories-final-review HTML output path**

In `### Step 10: Final HTML Review & Approval`, replace any occurrence of:

```text

specs/{folder}/reviews/stories-final-review.html

```text

Confirm it uses `{folder}` not `{ITDB-KEY}-{slug}`. If it uses the old pattern,
replace with `specs/{slug}/reviews/stories-final-review.html`.

- [ ] **Step 7: Fix three-amigos-review HTML output path**

In `### Step 6: Three Amigos HTML Review`, replace any occurrence of:

```text

specs/{folder}/reviews/three-amigos-review.html

```text

Confirm it uses `{folder}`. If it uses the old pattern, replace with
`specs/{slug}/reviews/three-amigos-review.html`.

- [ ] **Step 8: Fix stories.json handoff reference**

In `### Step 11: Status & Handoff`, replace the next steps that mention Jira:

```text

  - /publish-epic — create the Jira epic (planned)
  - /publish-stories — create Jira stories from stories.json (planned)

```text

with:

```text

  - /publish — create handoff.md, story folders, and optionally GitHub Issues

```text

- [ ] **Step 9: Verify no Jira/ITDB terms remain**

```bash

grep -n "ITDB\|jira\|Jira\|Confluence\|confluence\|jiraKey\|epic\.pi\|pi_planning" \
  plugins/makato-plan/skills/decompose/SKILL.md

```text

Expected: no output (the word "ITDB" in the commit message comment is fine — grep
the skill file only).

- [ ] **Step 10: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/decompose/SKILL.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "feat(makato-plan): update decompose — slug folders, no Jira references"

```text

---

## Task 9: Targeted Edits to 4 Minor Skills

**Files:**

- Modify: `plugins/makato-plan/skills/create-prd/SKILL.md`
- Modify: `plugins/makato-plan/skills/create-architecture/SKILL.md`
- Modify: `plugins/makato-plan/skills/create-acceptance-tests/SKILL.md`
- Modify: `plugins/makato-plan/skills/create-prototype/SKILL.md`

All four have the same two patterns to fix: folder path glob and Jira next-step wording.

- [ ] **Step 1: Fix `create-prd/SKILL.md`**

Update frontmatter:

```yaml

argument-hint: "[slug]"

```text

Replace folder glob example:

```text

Args: /create-prd [ITDB-KEY]
Examples:
  /create-prd ITDB-1234    → use specs/ITDB-1234-*/  (prefix match, pick most recently modified)
  /create-prd              → auto-detect most recently modified specs/ folder

```text

with:

```text

Args: /create-prd [slug]
Examples:
  /create-prd checkout-redesign    → use specs/checkout-redesign/
  /create-prd                      → auto-detect most recently modified specs/ folder

```text

Replace spec folder path reference:

```text

The folder already exists — it was created during the brainstorming phase
(named `specs/{ITDB-KEY}-{slug}/`).

```text

with:

```text

The folder already exists — it was created during the brainstorming phase
(named `specs/{slug}/`).

```text

Replace "When to Use" ITDB reference:

```text

- After brainstorming and grilling are complete for an ITDB feature

```text

with:

```text

- After brainstorming and grilling are complete

```text

Replace "When NOT to Use" Jira reference:

```text

- Want to create Jira issues (use publish skills downstream)
- Want to publish to Confluence (use publish skills downstream)

```text

with:

```text

- Want to create GitHub Issues or publish externally (use /publish downstream)

```text

- [ ] **Step 2: Fix `create-architecture/SKILL.md`**

Same pattern — update argument-hint, folder example, ITDB reference, Jira references:

Replace:

```text

argument-hint: "[ITDB-KEY]"

```text

with:

```text

argument-hint: "[slug]"

```text

Replace folder example:

```text

Args: /create-architecture [ITDB-KEY]
Examples:
  /create-architecture ITDB-1234    → use specs/ITDB-1234-*/

```text

with:

```text

Args: /create-architecture [slug]
Examples:
  /create-architecture checkout-redesign    → use specs/checkout-redesign/

```text

Replace:

```text

- After PRD is complete (ideally Approved) for an ITDB feature

```text

with:

```text

- After PRD is complete (ideally Approved)

```text

Replace:

```text

- Want to create Jira issues (use publish skills downstream)
- Want to publish to Confluence (use publish skills downstream)

```text

with:

```text

- Want to create GitHub Issues or publish externally (use /publish downstream)

```text

- [ ] **Step 3: Fix `create-acceptance-tests/SKILL.md`**

Replace:

```text

argument-hint: "[ITDB-KEY]"

```text

with:

```text

argument-hint: "[slug]"

```text

Replace folder example:

```text

Args: /create-acceptance-tests [ITDB-KEY]
Examples:
  /create-acceptance-tests ITDB-1234    → use specs/ITDB-1234-*/  (prefix match)
  /create-acceptance-tests              → auto-detect most recently modified specs/ folder

```text

with:

```text

Args: /create-acceptance-tests [slug]
Examples:
  /create-acceptance-tests checkout-redesign    → use specs/checkout-redesign/
  /create-acceptance-tests                      → auto-detect most recently modified specs/ folder

```text

Replace:

```text

- Need acceptance criteria formalized before publish creates Jira stories

```text

with:

```text

- Need acceptance criteria formalized before running /publish

```text

Replace:

```text

- Want to create DCPAT Jira tickets (that's part of the publish/implementation workflow)

```text

with:

```text

- Want to create implementation tasks (that's the development workflow)

```text

- [ ] **Step 4: Fix `create-prototype/SKILL.md`**

Replace:

```text

argument-hint: "[ITDB-KEY]"

```text

with:

```text

argument-hint: "[slug]"

```text

Replace folder example:

```text

Args: /create-prototype [ITDB-KEY]

```text

with:

```text

Args: /create-prototype [slug]

```text

Replace the ITDB folder path anywhere it appears (e.g., `specs/{ITDB-KEY}-*/`):

```text

specs/{ITDB-KEY}-*/

```text

with:

```text

specs/*/

```text

Replace:

```text

- Want to create Jira issues (use publish skills downstream)
- Want to publish to Confluence (use publish skills downstream)

```text

with:

```text

- Want to create GitHub Issues or publish externally (use /publish downstream)

```text

- [ ] **Step 5: Verify no Jira/ITDB terms remain in all four files**

```bash

grep -rn "ITDB\|jira\|Jira\|Confluence\|confluence\|ITDB-KEY" \
  plugins/makato-plan/skills/create-prd/SKILL.md \
  plugins/makato-plan/skills/create-architecture/SKILL.md \
  plugins/makato-plan/skills/create-acceptance-tests/SKILL.md \
  plugins/makato-plan/skills/create-prototype/SKILL.md

```text

Expected: no output.

- [ ] **Step 6: Commit**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/create-prd/SKILL.md \
      plugins/makato-plan/skills/create-architecture/SKILL.md \
      plugins/makato-plan/skills/create-acceptance-tests/SKILL.md \
      plugins/makato-plan/skills/create-prototype/SKILL.md
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "chore(makato-plan): update folder paths and remove Jira wording in 4 minor skills"

```text

---

## Task 10: Full Verification Pass

- [ ] **Step 1: Grep for all remaining Jira/DCP terms across the entire makato-plan skills tree**

```bash

grep -rn \
  "jira\|Jira\|JIRA\|confluence\|Confluence\|ITDB\|DCP\|pi_planning\|jiraKey\|subtaskKeys\|epicLink\|customfield\|dcp-mcp-wiki\|mcp-jira" \
  /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato/plugins/makato-plan/skills/

```text

Expected: no output. If any remain, fix them and commit with:

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  add plugins/makato-plan/skills/
git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  commit -m "chore(makato-plan): remove remaining Jira/DCP references"

```text

- [ ] **Step 2: Verify publish references directory is clean**

```bash

ls /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato/plugins/makato-plan/skills/publish/references/

```text

Expected files: `github-issue-template.md`, `skill-plan.html`

- [ ] **Step 3: Verify stories.json schema example parses**

```bash

python3 -c "
import json
schema = {
  'version': '2.0',
  'slug': 'test-feature',
  'created': '2026-06-10',
  'status': 'draft',
  'epic': {
    'summary': 'Test epic',
    'objective': 'One-liner',
    'labels': ['makato']
  },
  'stories': []
}
print(json.dumps(schema, indent=2))
print('OK — schema v2.0 is valid JSON')
"

```text

Expected: prints the JSON and "OK — schema v2.0 is valid JSON".

- [ ] **Step 4: Confirm git log looks clean**

```bash

git -C /Users/I346175/Library/CloudStorage/OneDrive-SAPSE/GITHUB/makato \
  log --oneline -8

```text

Expected: 6-7 commits from this plan visible at the top.
