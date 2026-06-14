---
name: build-refine
description: >-
  Bridge a shaped Jira story, GitHub issue, or any work unit to an
  implementation plan — tasks, file targets, unit/integration test
  strategy, acceptance mapping. Use to start a build session before
  implement-tdd or implement-goal.
version: "1.5.2"
model: opus
argument-hint: "[work-item-key]"
---

# refine

## When to Use

Use at the start of every build session, after a story has been shaped by daff-shape (or an equivalent process). Spec artifacts must exist in `specs/<key>-*/` before this skill can run.

**Do NOT use when:**
- The story has not been shaped (no spec artifacts exist) — run daff-shape first
- You want to continue an in-progress implementation — read `plan.md` in the spec folder directly
- You are fixing a hotfix or ad-hoc defect — use daff-fix instead

## Workflow

### Step 1 — Ask for the work item key

If an argument was passed when invoking this skill, use it directly. Otherwise, use the `AskUserQuestion` tool to ask for the work item key, with example options: `DCP-1234`, `#123`, or a freeform key. Remind the user they can skip this prompt next time by passing the key directly: `/daff-build:build-refine DCP-1234`.

Accept any identifier: Jira key (`DCP-1234`), GitHub issue (`#123` or `gh-123`), or freeform. Sanitize for use as a filesystem path component: replace `#` and spaces with `-`, lowercase.

### Step 2 — Log session start and prepare workspace

Check that a spec folder exists by prefix-matching `specs/<key>-*/`. If no match is found, stop immediately and tell the user:

> "No spec found for `<key>`. This story has not been shaped yet — run `/daff-shape:decompose` (or the full daff-shape pipeline) first, then return to `/refine`."

Do not proceed past this step until the directory exists.

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-refine","story":"<key>","step":"session","status":"start","data":{}}'
```

### Step 3 — Load spec artifacts

Load @references/spec-artifacts-schema.md to know what fields to extract from each file.

Read from the resolved spec folder (`specs/<key>-*/`):
- `stories.json` — required for ticket-based work; absent for local work (see below)
- `prd.md` — required for ticket-based work; optional for local work
- `design.md` — required for local work; optional for ticket-based work
- `decisions.md` — optional
- `prototype.html` — optional; if present, flag the story as having a UI reference

**Local-work path** (key starts with `local-`): `stories.json` will not exist.
If `design.md` is present, read it as the sole input artifact. Derive the goal from the
`## Goal` section and treat each sentence in `## Constraints` as a fixed decision. There
are no acceptance criteria from a stories.json — `/build-refine` will produce tasks whose
done-condition is the goal statement itself. Continue without stopping.

If `design.md` is also missing → stop: tell the user to run `/build-start` first to
create the design document.

**Ticket path** (key does not start with `local-`): if `stories.json`, `prd.md`, or
`design.md` is missing, report which files are absent and stop. Tell the user to run
daff-shape first or confirm the correct spec path. Append an `"status":"error"` entry to
`build.jsonl` before stopping.

### Step 4 — Extract story details

**Ticket path**: find the entry in `stories.json` whose key matches `<key>`. Extract:
- Title and functional description
- Acceptance criteria — full list, numbered AC-1, AC-2, … by index
- Phase assignment and story type
- Dependencies (work item keys that must be merged before this one)

If the key is not found in stories.json: report it and ask the user to confirm the key.

`stories.json` is the authoritative source for story content. If the content diverges from the Jira ticket, prefer `stories.json` — it captures the shaped and refined version of the story.

**Local-work path**: no stories.json. The goal from `design.md` serves as the story
description. Generate one synthetic acceptance criterion: *"AC-1: <goal statement> is
implemented and all tests pass."* Note in the plan that this story has no formal ACs and
the done-condition is self-evident from the goal.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"extract-story","status":"ok","data":{"ac_count":<N>}}'`

### Step 5 — Read domain and architecture context

From `prd.md`: understand the user-facing goal, non-functional requirements, success metrics, and explicitly out-of-scope items.

From `design.md`: identify which components are involved, API contracts, data model, and the prescribed technical approach.

From `decisions.md` (if present): note constraints from prior decisions that bound the implementation. Treat every decision record as a fixed constraint — do not re-open decisions here.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"load-artifacts","status":"ok","data":{"files_read":[…]}}'`

### Step 5.5 — Load knowledge graph (conditional)

Before exploring the local `context/` directory, attempt to load knowledge from the project specs repository:

Derive REPO_NAME from the last path segment of the target repo root. Extract 5–10 key terms from the story title and description (from `stories.json`) as KEYWORDS.

Dispatch the `knowledge-scout` agent with REPO_ROOT, REPO_NAME, and KEYWORDS. The agent handles dcp-specs discovery internally (daff.config.json → sibling scan → skip).

Receive the Knowledge Scout Findings and:
- Apply every item in `## Hard Constraints` as a mandatory rule in the implementation plan — note these in the plan header so the user sees them
- Apply `## Standards` as naming and pattern conventions for all tasks, file targets, and interfaces
- Use `## Architecture Context` to inform layer structure and file placement decisions

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"load-knowledge-graph","status":"ok","data":{"loaded":<true|false>,"source":"<local|none>","constraints":<N>}}'`

If the agent returns `loaded: false`: log and continue to Step 6 without change.

When constraints are found, include a summary line in the plan header presented to the user:
> "Knowledge graph: {N} hard constraints loaded from dcp-specs ({source}). Applied to all tasks."

### Step 6 — Explore the codebase

Before exploring code files, locate `AGENTS.md` and `CLAUDE.md` at the root of the target codebase (run `git rev-parse --show-toplevel` from any file target in `design.md`). Read whichever exist.

Extract:
- Project goal and decision test ("Does X belong here?")
- Naming conventions and file structure expectations
- Contributor constraints (what must and must not be introduced)

Treat these as hard constraints on the implementation plan: tasks and file targets must not violate them. If neither file exists: proceed without them.

**Check for pre-built context before reading code directly:**

1. Look for a `context/` directory at the target repo root. If absent, skip to direct exploration below.
2. If `context/` exists:
   a. Check for `index.yml` or `index.md` — if found, read the `generated:` or `Last updated:` timestamp.
   b. If the timestamp is within 30 days: read the relevant sections — `codebase/patterns.md`, `codebase/structure.md`, `codebase/architecture.md`, `harness/golden-rules.md`, `standards/` (any files present). Use these as the primary source for the exploration steps below; direct file reads validate and supplement.
   c. If the timestamp is older than 30 days or no timestamp is found: note it as potentially stale, proceed with direct codebase exploration, and treat `context/` files as hints only.
3. Optionally run `gh pr list --repo <org>/<repo> --state merged --limit 10 --json title,mergedAt,files` (if the GitHub MCP or `gh` CLI is available) to surface recent merged changes before reading files.

Using the story description and architecture context as a guide, read the target codebase to identify:

1. Files and components most likely to be created or modified.
2. Existing patterns and best practices in use — error handling conventions, naming patterns, dependency injection approach, logging style, transaction boundaries. These constrain the implementation: new code must follow what is already established.
3. Existing library dependencies and internal utilities that can be reused. Do not plan to introduce new dependencies when the codebase already has a suitable solution.
4. Where tests live and what framework and assertion style is used.
5. Any existing code that partially implements this story (reuse vs replace).

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"explore-codebase","status":"ok","data":{"files_explored":<N>,"patterns_noted":<N>,"reusable_deps":<N>,"agents_md_found":<true|false>,"context_used":<true|false>}}'`

### Step 7 — Determine implementation mode

Load @references/implementation-mode-guide.md.

Decide: `implement-tdd` or `implement-goal`? Record the decision and a one-line rationale in the plan. If the story spans both modes, mark each task individually with its mode.

**Mixed-mode sequencing rule**: when a plan contains both `tdd` and `goal` tasks, TDD tasks (logic/service layer) run before goal tasks (UI/config) unless a goal task is a structural prerequisite for a TDD task. Encode this as `runOrder: [tdd, goal]` in the plan frontmatter. If a goal task is a prerequisite, note the exception in the Scope Flags section.

### Step 8 — Break story into implementation tasks

Load @references/task-sizing-guide.md.

Produce an ordered task list. Each task must specify:
- **Title**: verb + subject ("Add OrderStatus enum", "Implement DealService.cancel()")
- **Files**: exact paths to create or modify
- **Unit test**: what to mock, what assertions to make (or N/A with reason)
- **Integration test**: which real boundary to cross, what to verify (or N/A with reason)
- **AC links**: which acceptance criteria this task satisfies
- **Mode**: tdd or goal
- **blockedBy**: list of task indices (1-based) whose production code output this task's files depend on at compile time. Empty list `[]` means no hard dependency. This field must be populated for any task whose files cannot compile without a prior task's output (e.g. a test stub that references a class created by a prior task).
- **commitMessage**: a conventional commit message draft for this task (e.g. `feat(invoice): add OrderStatus enum`). Pre-populated by refine; confirmed and may be adjusted in `/build-push-to-git`.

The full task list must be completable in a single autonomous session (target 2–6 tasks). If more tasks are needed than fit in one session, flag it before proceeding — ask the user to confirm scope or split the story.

**File target validation**: before writing the plan, verify every `files` entry across all tasks is a relative path that resolves within the repository root. Reject any path that begins with `/` or contains `..` segments. If an invalid path is found — stop and report it:

> "Invalid file target in task <N>: `<path>`. All file targets must be relative paths within the repository root. Please correct the spec's design.md and re-run /build-refine."

### Step 9 — Map acceptance criteria to tasks

Build a coverage table: for each AC, which task(s) satisfy it?

Every AC must be covered by at least one task. If any AC has no task: add a task or split an existing task to make coverage explicit. Do not proceed to Step 10 with uncovered ACs.

### Step 10 — Write the implementation plan

Load @references/plan-schema.md.
Read `templates/plan-template.md` and use it as the base for the output.

Write `plan.md` in the resolved spec folder with all fields populated from the template.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"write-plan","status":"ok","data":{"tasks":<N>,"plan_file":"<resolved-spec-folder>/plan.md"}}'`

### Step 11 — Present plan and iterate

Use the `AskUserQuestion` tool to ask: "The plan is ready. How would you like to review it before implementation starts?" with two options:
- **In chat** — description: "Show the plan as markdown in this conversation. You can reply with feedback or edits."
- **In browser** — description: "Generate an interactive HTML page with per-task feedback fields and open it in your browser. Copy your feedback and paste it back here when done."

**If Terminal**: display `plan.md` content inline. Ask: "Does this plan look accurate? Any tasks missing, wrong files, or scope concerns?"

**If Browser**:
1. Read `@templates/plan-review-template.html`.
2. Populate it with: story title, task list (title, files, tests, AC links, mode), and AC coverage table.
3. Write the result to `plan-review.html` in the spec folder.
4. Open with the platform command (`open` / `xdg-open` / `start`).
5. Tell the user: "Plan review is open in your browser. Add feedback in the textareas and click 'Copy Feedback' when done, then paste it here."
6. Wait for pasted feedback; proceed as terminal mode below.

If the user requests changes: update `plan.md` in the spec folder and ask again. Each revision appends:
```
{"ts":"…","skill":"build-refine","story":"<key>","step":"plan-revision","status":"ok","data":{"revision":<N>}}
```
Repeat until the user approves.

### Step 12 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-refine","story":"<key>","step":"session","status":"ok","data":{"tasks":<N>,"mode":"<tdd|goal|mixed>","plan":"<resolved-spec-folder>/plan.md"}}'
```

Tell the user: "Plan written to `plan.md` in the spec folder. Next: run `/grill-with-docs` to validate terminology against the codebase, or proceed directly with `/implement-tdd` or `/implement-goal`."

**Grill-with-docs recommendation**: run `/build-grill-with-docs` if either condition is met:
- `glossary.md` exists in the spec folder and contains 3 or more terms
- The plan touches domain-specific field names (entity fields, API paths, enum values — not generic names like `service` or `handler`)

Skip `/build-grill-with-docs` for infra/config-only changes (no domain-model files touched). State the recommendation inline.
