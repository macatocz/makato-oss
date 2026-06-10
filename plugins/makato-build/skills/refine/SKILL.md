---
name: refine
description: >-
  Bridge a pland GitHub issue, or any work unit to an
  implementation plan — tasks, file targets, unit/integration test
  strategy, acceptance mapping. Use to start a build session before
  implement-tdd or implement-goal.
version: "1.3.0"
argument-hint: "[work-item-key]"
---
# refine

## When to Use

Use at the start of every build session, after a story has been pland by makato-plan (or an equivalent process). Spec artifacts must exist in `spec/<key>/` before this skill can run.

**Do NOT use when:**

- The story has not been pland (no spec artifacts exist) — run makato-plan first
- You want to continue an in-progress implementation — read `spec/<key>/plan.md` directly
- You are fixing a hotfix or ad-hoc defect — use makato-fix instead

## Workflow

### Step 1 — Ask for the work item key

If an argument was passed when invoking this skill, use it directly. Otherwise, use the `AskUserQuestion` tool to ask for the work item key, with example options: `DCP-1234`, `#123`, or a freeform key.

GitHub issue (`#123` or `gh-123`), or freeform. Sanitize for use as a filesystem path component: replace `#` and spaces with `-`, lowercase.

### Step 2 — Log session start and prepare workspace

Check that `spec/<key>/` exists. If it does not, stop immediately and tell the user:

> "No spec found for `<key>`. This story has not been pland yet — run `/makato-plan:decompose` (or the full makato-plan pipeline) first, then return to `/refine`."

Do not proceed past this step until the directory exists.

Append to `spec/<key>/build.jsonl`:

```
{"ts":"<ISO-8601-ms>","skill":"refine","story":"<key>","step":"session","status":"start","data":{}}
```

### Step 3 — Load spec artifacts

Load @references/spec-artifacts-schema.md to know what fields to extract from each file.

Read from `spec/<key>/`:

- `stories.json` — **required**
- `prd.md` — **required**
- `design.md` — **required**
- `decisions.md` — optional
- `prototype.html` — optional; if present, flag the story as having a UI reference

If `stories.json`, `prd.md`, or `design.md` is missing: report which files are absent and stop. Tell the user to run makato-plan first or confirm the correct spec path. Append an `"status":"error"` entry to `build.jsonl` before stopping.

### Step 4 — Extract story details from stories.json

Find the entry in `stories.json` whose key matches `<key>`. Extract:

- Title and functional description
- Acceptance criteria — full list, numbered AC-1, AC-2, … by index
- Phase assignment and story type
- Dependencies (work item keys that must be merged before this one)

If the key is not found in stories.json: report it and ask the user to confirm the key.

`stories.json` is the authoritative source for story content.  it captures the pland and refined version of the story.

Log: `{"ts":"…","skill":"refine","story":"<key>","step":"extract-story","status":"ok","data":{"ac_count":<N>}}`

### Step 5 — Read domain and architecture context

From `prd.md`: understand the user-facing goal, non-functional requirements, success metrics, and explicitly out-of-scope items.

From `design.md`: identify which components are involved, API contracts, data model, and the prescribed technical approach.

From `decisions.md` (if present): note constraints from prior decisions that bound the implementation. Treat every decision record as a fixed constraint — do not re-open decisions here.

Log: `{"ts":"…","skill":"refine","story":"<key>","step":"load-artifacts","status":"ok","data":{"files_read":[…]}}`

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

Log: `{"ts":"…","skill":"refine","story":"<key>","step":"explore-codebase","status":"ok","data":{"files_explored":<N>,"patterns_noted":<N>,"reusable_deps":<N>,"agents_md_found":<true|false>,"context_used":<true|false>}}`

### Step 7 — Determine implementation mode

Load @references/implementation-mode-guide.md.

Decide: `implement-tdd` or `implement-goal`? Record the decision and a one-line rationale in the plan. If the story spans both modes, mark each task individually with its mode.

### Step 8 — Break story into implementation tasks

Load @references/task-sizing-guide.md.

Produce an ordered task list. Each task must specify:

- **Title**: verb + subject ("Add OrderStatus enum", "Implement DealService.cancel()")
- **Files**: exact paths to create or modify
- **Unit test**: what to mock, what assertions to make (or N/A with reason)
- **Integration test**: which real boundary to cross, what to verify (or N/A with reason)
- **AC links**: which acceptance criteria this task satisfies
- **Mode**: tdd or goal

The full task list must be completable in a single autonomous session (target 2–6 tasks). If more tasks are needed than fit in one session, flag it before proceeding — ask the user to confirm scope or split the story.

### Step 9 — Map acceptance criteria to tasks

Build a coverage table: for each AC, which task(s) satisfy it?

Every AC must be covered by at least one task. If any AC has no task: add a task or split an existing task to make coverage explicit. Do not proceed to Step 10 with uncovered ACs.

### Step 10 — Write the implementation plan

Load @references/plan-schema.md.
Read `templates/plan-template.md` and use it as the base for the output.

Write `spec/<key>/plan.md` with all fields populated from the template.

Log: `{"ts":"…","skill":"refine","story":"<key>","step":"write-plan","status":"ok","data":{"tasks":<N>,"plan_file":"spec/<key>/plan.md"}}`

### Step 11 — Present plan and iterate

Use the `AskUserQuestion` tool to ask: "How would you like to review the plan?" with two options:

- **Terminal** — display plan content as markdown in the conversation
- **Browser** — generate an HTML review page and open it in the browser

**If Terminal**: display `spec/<key>/plan.md` content inline. Ask: "Does this plan look accurate? Any tasks missing, wrong files, or scope concerns?"

**If Browser**:

1. Read `@templates/plan-review-template.html`.
2. Populate it with: story title, task list (title, files, tests, AC links, mode), and AC coverage table.
3. Write the result to `spec/<key>/plan-review.html`.
4. Open with the platform command (`open` / `xdg-open` / `start`).
5. Tell the user: "Plan review is open in your browser. Add feedback in the textareas and click 'Copy Feedback' when done, then paste it here."
6. Wait for pasted feedback; proceed as terminal mode below.

If the user requests changes: update `spec/<key>/plan.md` and ask again. Each revision appends:

```
{"ts":"…","skill":"refine","story":"<key>","step":"plan-revision","status":"ok","data":{"revision":<N>}}
```

Repeat until the user approves.

### Step 12 — Log session end and hand off

Append to `spec/<key>/build.jsonl`:

```
{"ts":"<ISO-8601-ms>","skill":"refine","story":"<key>","step":"session","status":"ok","data":{"tasks":<N>,"mode":"<tdd|goal|mixed>","plan":"spec/<key>/plan.md"}}
```

Tell the user: "Plan written to `spec/<key>/plan.md`. Next: run `/grill-with-docs` to validate terminology against the codebase, or proceed directly with `/implement-tdd` or `/implement-goal`."
