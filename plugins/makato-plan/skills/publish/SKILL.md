---
name: publish
description: Publish pland stories to Jira and Confluence — publish stories, create epic, push to jira, publish spec, create jira issues. Use after stories.json is approved.
version: "1.1.0"
model: sonnet
argument-hint: "[ITDB-KEY]"
---

# Publish

Publish pland artifacts from `stories.json` to Jira (Epic + Stories + Subtasks + links) and Confluence (stakeholder spec page). Single atomic action — stories.json is the input, Jira/Confluence become the source of truth after publish.

## When to Use

- After stories.json is approved (status: "approved")
- Ready to hand off pland work to development teams
- Want to create the full Jira structure (Epic, Stories, Subtasks, links)
- Want a stakeholder-facing Confluence spec page

## When NOT to Use

- stories.json doesn't exist yet (run decompose first)
- Want to modify existing Jira issues during sprint (that's makato-build refine)
- Want to assign stories to sprints or people (that's sprint planning)
- Want to transition issue statuses (manual or makato-build)

---

## Workflow

### Step 1: Resolve Spec Folder & Validate

#### 1.1: Resolve Spec Folder

From the argument (ITDB key) or auto-detect the most recently modified `specs/{ITDB-KEY}-*/` folder.

```
Args: /publish [ITDB-KEY]
Examples:
  /publish ITDB-1234    → use specs/ITDB-1234-*/  (prefix match)
  /publish              → auto-detect most recently modified specs/ folder
```

If no spec folder found, inform the user and suggest running upstream skills first.

#### 1.2: Load and Validate stories.json

Read `stories.json` from the resolved spec folder. Validate:

1. File exists and is valid JSON
2. Has `epic` object with `summary`, `objective`, `pi`, `labels`
3. Has at least one story in `stories[]`
4. Check `status` field:

```
If status == "approved" → proceed
If status == "draft" →
  AskUserQuestion:
    question: "stories.json status is 'draft' (not yet approved). Publish anyway?"
    options: ["Yes, publish draft", "No, abort"]
  If "No" → exit with message to approve first
```

#### 1.3: Check Idempotency State

Check if stories.json already has `jiraKeys` (from a previous publish run):
- `epic.jiraKey` exists → will UPDATE the epic (not create)
- `stories[].jiraKey` exists → will UPDATE those stories (not create)

Report to user: "Resuming previous publish — N items already published, M remaining."

---

### Step 2: Load Supporting Artifacts

Read from the spec folder (all optional, for linking purposes only):
- `prd.md` — will link in story artifact panel
- `design.md` — will link in story artifact panel
- `prototype.html` — will link in story artifact panel
- `decisions.md` — for context on open questions

Note which artifacts exist. Missing artifacts are simply not linked.

---

### Step 3: Detect Git Remote URL

Auto-detect the repository URL for artifact links:

```bash
git remote get-url origin
```

Transform SSH URLs to HTTPS browse URLs:
- `git@github.tools.sap:ORG/REPO.git` → `https://github.tools.sap/ORG/REPO`
- `https://github.tools.sap/ORG/REPO.git` → `https://github.tools.sap/ORG/REPO`

Determine the default branch (main/master) for building file links:
```bash
git symbolic-ref refs/remotes/origin/HEAD
```

Build artifact URLs (where `{specFolder}` is the directory name resolved in Step 1.1, e.g., `ITDB-1234-checkout-redesign`):
- PRD: `{repoUrl}/blob/{branch}/specs/{specFolder}/prd.md`
- Design: `{repoUrl}/blob/{branch}/specs/{specFolder}/design.md`
- Prototype: `{repoUrl}/blob/{branch}/specs/{specFolder}/prototype.html`

---

### Step 4: Ask Target Jira Project

```
AskUserQuestion:
  question: "Which Jira project should the epic and stories be created in?"
  options:
    - "DCP (production)" (Recommended)
    - "DCPAI (testing)"
```

Store the selected project key for all subsequent Jira operations.

---

### Step 5: Validate PI Component

Check that the PI component from `epic.pi` exists in the target project:

```
Use: mcp__plugin_makato-core_jira__get_project_components
  project: {targetProject}
```

The tool call above returns an array of components. Find the one whose `name` equals `PI | {epic.pi}` after trimming whitespace and lowercasing both sides (e.g., `epic.pi` of `26/03` matches a component named `PI | 26/03`).

- Exactly one match → use its `id`
- No match → filter the array to components whose `name` starts with `PI |`, present them to the user, and ask which to use (or abort)

---

### Step 6: Prepare Creation Summary (Gate 1)

Build a summary of what will be created/updated and present to the user:

```
AskUserQuestion:
  question: "Ready to publish to Jira ({project}). Confirm creation plan?"
  
  Show:
  - Epic: {epic.summary} [CREATE/UPDATE]
  - Stories (N):
    1. {story.summary} ({story.storyPoints} SP) [CREATE/UPDATE]
    2. ...
  - Subtasks: 4 per story (Implementation, QA Verification, Documentation, Automate acceptance test cases)
  - Links: Epic→ITDB (Parent-Child), Stories→Epic (epicLink), Story→Story (Dependency)
  
  options:
    - "Proceed with publish"
    - "Abort"
```

If aborted → exit gracefully.

---

### Step 7: Create/Update Epic

Load @references/jira-field-mapping.md for field IDs.

#### 7.1: Create or Update Epic

If `epic.jiraKey` exists → update:
```
Use: mcp__plugin_makato-core_jira__update_issue
  key: {epic.jiraKey}
  summary: {epic.summary}
  labels: {epic.labels}
```

If no `epic.jiraKey` → create:
```
Use: mcp__plugin_makato-core_jira__create_issue
  project: {targetProject}
  issuetype: "Epic"
  summary: {epic.summary}
  labels: {epic.labels}
  components: ["PI | {epic.pi}"]
```

Save the returned key to `epic.jiraKey` in stories.json immediately.

#### 7.2: Link Epic to ITDB Feature

Create Parent-Child link (epic is child-of ITDB feature).

Reads as: "ITDB feature is parent-of epic". The `Parent-Child` link type has outward = "parent-of", so `sourceIssue` is the parent and `targetIssue` is the child.

```
Use: mcp__plugin_makato-core_jira__create_issue_link
  type: "Parent-Child"
  sourceIssue: {feature}          (parent = ITDB feature key)
  targetIssue: {epic.jiraKey}     (child = epic)
```

---

### Step 8: Create/Update Stories

Load @references/dcp-story-panels.md for the description panel structure.

For each story in `stories[]` (in sequence order):

#### 8.1: Render Story Description

Render the full Jira wiki markup description using the panel template:
- Background panel ← `story.description.background`
- Scope panel ← `story.description.scope`
- Dependencies panel ← `story.externalDependencies` (rendered as bullet list, or "N/A")
- Feature Toggle panel ← `story.description.featureToggle` fields
- Success Scenario panel ← `story.description.successScenarios` (rendered as Gherkin)
- Solution Approach panel ← `story.description.solutionApproach` (or placeholder text)
- Acceptance Test Cases panel ← `story.description.acceptanceTestCases` (or placeholder text)
- Wiki documentation panel ← `story.description.wikiDocumentation` (or placeholder text)
- Out of Scope panel ← `story.description.outOfScope` (bullet list, or "N/A")

Append a "Shaping Artifacts" panel with git links to PRD, design, prototype (only those that exist):
```
{panel:title=Shaping Artifacts|borderColor=#deebff|titleBGColor=#deebff|bgColor=#f0f7ff}
* [PRD|{prdUrl}]
* [Design|{designUrl}]
* [Prototype|{prototypeUrl}]
{panel}
```

Append a "Definition of Done" panel:
```
{panel:title=Definition of Done|borderColor=#e3fcef|titleBGColor=#e3fcef|bgColor=#f1fdf6}
* {dod item 1}
* {dod item 2}
* ...
{panel}
```

#### 8.2: Create or Update Story

If `story.jiraKey` exists → update:
```
Use: mcp__plugin_makato-core_jira__update_issue
  key: {story.jiraKey}
  summary: {story.summary}
  description: {renderedDescription}
  labels: {story.labels}
```

If no `story.jiraKey` → create:
```
Use: mcp__plugin_makato-core_jira__create_issue
  project: {targetProject}
  issuetype: "Story"
  summary: {story.summary}
  description: {renderedDescription}
  labels: {story.labels}
  epicLink: {epic.jiraKey}
  storyPoints: {story.storyPoints}
```

Set teams field (customfield_16240) if available in the MCP create_issue tool.

Save the returned key to `story.jiraKey` in stories.json immediately after each creation.

---

### Step 9: Create Subtasks

Load @references/subtask-templates.md for the 4 subtask templates.

For each story that was just created (has `jiraKey` but no `subtaskKeys`), create 4 subtasks:

1. **Implementation** — empty description
2. **QA Verification** — pre-populated with acceptance criteria from story's `successScenarios` + `acceptanceTestCases`
3. **Documentation** — pre-populated with artifact links (git URLs, Confluence page once created)
4. **Automate acceptance test cases** — pre-populated with Gherkin scenarios and test automation instructions

For each subtask:
```
Use: mcp__plugin_makato-core_jira__create_issue
  project: {targetProject}
  issuetype: "Sub-Task"
  parent: {story.jiraKey}
  summary: {subtaskSummary}
  description: {subtaskDescription from template}
```

Save subtask keys to `story.subtaskKeys` in stories.json as a keyed object (not an array), so downstream steps reference subtasks by name instead of by position:

```json
"subtaskKeys": {
  "Implementation": "DCP-...",
  "QA Verification": "DCP-...",
  "Documentation": "DCP-...",
  "Automate acceptance test cases": "DCP-..."
}
```

> NOTE: Subtask content is pre-populated during publish but may be enriched further by the makato-build `refine` skill during sprint planning.

---

### Step 10: Create Inter-Story Dependency Links

For each story that has `dependencies.blockedBy` entries:

Reads as: "this story depends on blocker". The `Dependency` link type has outward = "depends on", so `sourceIssue` is the dependent (blocked) story and `targetIssue` is the blocker.

```
Use: mcp__plugin_makato-core_jira__create_issue_link
  type: "Dependency"
  sourceIssue: {thisStory.jiraKey}            (this story "depends on" the other)
  targetIssue: {blockerStory.jiraKey}         (the other story "has dependency")
```

Map sequence numbers from `blockedBy[]` to actual jiraKeys via the stories array.

**Idempotency**: Skip links that already exist. Before creating each link, check `story.dependencyLinksCreated` (a boolean flag saved to stories.json after all dependency links for that story succeed). If the flag is set, skip that story's links entirely. After successfully creating all links for a story, set the flag. This prevents duplicate links on partial-run resume.

---

### Step 11: Detect Confluence Domain (Gate 2 Preparation)

Search for the feature's domain in Confluence hierarchy:

```
Use: mcp__plugin_makato-core_dcp-mcp-wiki__get_child_pages
  pageId: "2134905309"    (Functional Documentation root in DCPL)
```

This returns domain pages. For each domain page, check its children for "Feature Specifications - {Domain}" pages.

Heuristic for domain detection:
1. Check if ITDB feature has a domain label or component
2. Match against Confluence domain page names
3. If ambiguous → ask user

---

### Step 12: Confirm Confluence Page (Gate 2)

```
AskUserQuestion:
  question: "Ready to create Confluence spec page. Confirm placement?"
  
  Show:
  - Space: DCPL
  - Parent page: "Feature Specifications - {Domain}"
  - Page title: "Spec - {epic.summary stripped of tag} ({ITDB-key})"
  
  options:
    - "Create page"
    - "Change parent page"
    - "Skip Confluence"
```

If "Change parent page" → ask for parent page ID or let user search.
If "Skip" → proceed to Step 15 without creating page.

---

### Step 13: Create/Update Confluence Spec Page

Load @references/confluence-page-template.md for the XHTML structure.

Build a stakeholder overview page containing:
- Feature objective (from `epic.objective`)
- Epic link (Jira URL)
- Story summary table (sequence, title, SP, status, Jira link)
- Links to shaping artifacts (PRD, Design, Prototype — git URLs)
- Phase breakdown (foundation → happy-path → edge-cases)

If `confluencePageId` exists in stories.json → update:
```
Use: mcp__plugin_makato-core_dcp-mcp-wiki__update_page
  pageId: {confluencePageId}
  title: {pageTitle}
  content: {renderedXhtml}
```

If no `confluencePageId` → create:
```
Use: mcp__plugin_makato-core_dcp-mcp-wiki__create_page
  spaceKey: "DCPL"
  parentId: {parentPageId from Step 12}
  title: {pageTitle}
  content: {renderedXhtml}
```

Save the Confluence page ID to stories.json as `confluencePageId` immediately after creation.

---

### Step 14: Update Documentation Subtasks

After the Confluence page is created, update each story's Documentation subtask to include the Confluence link:

```
Use: mcp__plugin_makato-core_jira__update_issue
  key: {story.subtaskKeys["Documentation"]}
  description: {updated description with Confluence link added}
```

Only run this step if a Confluence page was created in Step 13 (skip if user chose "Skip Confluence").

---

### Step 15: Create Epic & Story Folders

After all Jira keys are known, create the folder hierarchy inside the spec folder. The spec folder itself (e.g., `specs/ITDB-1234-feature-name/`) stays unchanged — it's the stable workspace for all shaping artifacts.

#### 15.1: Create Epic Folder

Inside the spec folder, create a subfolder for the epic:

Pattern: `{epicKey}-{slugified-summary}`

Slug rules:
- Take `epic.summary`
- Strip the `[Component]` prefix tag if present
- Lowercase, replace spaces with hyphens
- Remove special characters
- Truncate to reasonable length (max 60 chars)

```bash
mkdir -p specs/{spec-folder}/{epicKey}-{slug}
```

#### 15.2: Create Story Folders

Inside the epic folder, create one subfolder per story:

Pattern: `{storyKey}-{slugified-summary}`

Slug rules same as above (strip `[Component]` tag, kebab-case, max 60 chars).

```bash
mkdir -p specs/{spec-folder}/{epicKey}-{slug}/{storyKey}-{slug}
```

Example structure after publish:
```
specs/ITDB-1234-checkout-redesign/
├── brainstorm.md
├── prd.md
├── design.md
├── prototype.html
├── decisions.md
├── stories.json
└── DCP-56000-redesign-checkout-flow/
    ├── DCP-56001-cart-validation-service-foundation/
    ├── DCP-56002-realtime-validation-errors-cart-ui/
    ├── DCP-56003-quantity-limit-validation-rule/
    └── DCP-56004-validation-timeout-degraded-mode/
```

These folders are empty at publish time — they serve as named anchors indicating that the Jira epic and stories exist. The makato-build `refine` skill populates them with implementation context during sprint planning.

Add a `.gitkeep` in each story folder so git tracks them:
```bash
touch specs/{spec-folder}/{epicKey}-{slug}/{storyKey}-{slug}/.gitkeep
```

---

### Step 16: Final Summary

Present the complete publish result:

```
✓ Published to {project}

Epic: {epicKey} — {epic.summary}
  ↳ linked to {ITDB-key} (Parent-Child)
  ↳ component: PI | {pi}

Stories:
  1. {storyKey} — {story.summary} ({SP} SP)
     ↳ 4 subtasks created
  2. ...

Dependency links: {N} created
Confluence: {pageTitle} (page ID: {pageId})
Folders: {epicKey}-{slug}/ with {N} story subfolders created

stories.json updated with all jiraKeys.
Jira is now the source of truth for these stories.
```

---

## Error Handling

- **Stop on error**: If any Jira/Confluence operation fails, stop immediately and report the error.
- **Progress saved**: After each successful creation, the jiraKey is written to stories.json. A re-run will skip already-created items.
- **No duplicates**: The create-or-update pattern ensures re-running publish is always safe.
- **Rate limiting**: Add a brief pause between Jira API calls to avoid overwhelming the server.
