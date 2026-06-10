---
name: publish
description: Publish pland stories — create handoff summary, story folders, and optionally GitHub Issues. Use after stories.json is approved.
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
```

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
```

#### 1.3: Check Idempotency State

Check if stories.json already has `githubIssue` fields (from a previous publish run):

- Any `stories[].githubIssue` exists → report "Resuming previous publish — N stories already published."
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
```

Transform SSH URLs to HTTPS browse URLs:

- `git@github.com:owner/repo.git` → `https://github.com/owner/repo`
- `https://github.com/owner/repo.git` → `https://github.com/owner/repo`

Determine the default branch for building file links:

```bash
git symbolic-ref refs/remotes/origin/HEAD
```

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
**Stories:** {N} ({foundation count} foundation, {happy-path count} happy-path, {edge-cases count} edge-cases)
**Total SP:** {sum of storyPoints}

## Shaping Artifacts

- [PRD]({prdUrl}) ← only if prd.md exists
- [Design]({designUrl}) ← only if design.md exists
- [Prototype]({prototypeUrl}) ← only if prototype.html exists

## Stories

| # | Summary | Phase | SP | Teams |
|---|---------|-------|----|-------|
| 1 | {story.summary} | {story.phase} | {story.storyPoints} | {story.teams joined} |

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
```

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
```

Example after publish:

```text
specs/checkout-redesign/
├── brainstorm.md
├── prd.md
├── design.md
├── stories.json
├── handoff.md
├── 01-cart-validation-service/
│   └── .gitkeep
├── 02-realtime-cart-errors/
│   └── .gitkeep
└── 03-quantity-limit-rule/
    └── .gitkeep
```

---

### Step 6: Check for GitHub Provider Config

Read `makato.config.yml` from the repository root (the directory containing the `specs/` folder):

```bash
cat makato.config.yml 2>/dev/null
```

If the file is absent or `provider` is not `github` → skip to Step 10 (final summary).
If `provider: github` → continue to Step 7.

---

### Step 7: Resolve GitHub Repo Target

Read `github.repo` from `makato.config.yml`. If absent, ask:

```text
AskUserQuestion:
  question: "Which GitHub repo should the Issues be created in?"
  (free-form answer: owner/repo-name)
```

Store as `{owner}/{repo}` for all subsequent GitHub operations.

---

### Step 8: Confirm GitHub Creation Plan

```text
AskUserQuestion:
  question: "Ready to create GitHub Issues in {owner}/{repo}. Confirm?"

  Show:
  - Epic label: epic:{slug}
  - Issues ({N}):
    1. {story.summary} ({story.storyPoints} SP) [CREATE]
    2. ...

  options:
    - "Proceed"
    - "Abort"
```

If aborted → skip to Step 10 (print local-only summary).

---

### Step 9: Create GitHub Epic Tracking Issue and Story Issues

#### 9.1: Create Epic Label

Create a label to group all stories under this epic:

```text
mcp: mcp__plugin_general_github-mcp__create_issue(
  owner: {owner},
  repo: {repo},
  title: "[epic] {epic.summary}",
  body: "**Objective:** {epic.objective}\n\nThis is the tracking issue for the `{slug}` epic. All story issues will be labelled `epic:{slug}`."
)
```

Save the returned issue number as the epic tracking issue. All story issues will reference this via the `epic:{slug}` label.

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
  labels: {story.labels combined with ["epic:{slug}"]}
)
```

Save the returned issue number to `story.githubIssue` in `stories.json` immediately after each creation.

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
  Epic tracking issue: #{epicIssueNumber} — {epic.summary}
  Stories:
    1. #{issueNumber} — {story.summary}
    2. ...
{end if}

{if local-only:}
GitHub Issues: skipped (no provider configured in makato.config.yml)
To enable: add `provider: github` to makato.config.yml
{end if}
```

---

## Error Handling

- **Stop on error**: if any GitHub operation fails, stop immediately and report the error.
- **Progress saved**: after each successful issue creation, `githubIssue` is written to `stories.json`. A re-run will skip already-created items.
- **Local handoff always succeeds**: Steps 4 and 5 (handoff.md and folders) never depend on GitHub — they always run regardless of provider config.
