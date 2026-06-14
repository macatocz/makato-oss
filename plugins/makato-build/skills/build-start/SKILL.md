---
name: build-start
description: >-
  Entry point for a full build session — validates git state, validates spec
  prerequisites, captures implementation mode, initializes the build log, and
  kicks off /build-refine. Use when starting a new story build, beginning the
  daff-build workflow, running build-start on a work item, or starting local
  work without a ticket.
version: "1.3.1"
argument-hint: "[work-item-key]"
---

# build-start

## When to Use

Use at the beginning of every daff-build session, before `/build-refine`.

For ticket-based work: spec artifacts must have been produced by daff-shape
(or equivalent) before this skill can run.

For local work without a ticket: this skill creates a minimal `design.md` via
a short interview, then hands off to `/build-refine`.

**Do NOT use when:**
- Resuming mid-session — each skill in the pipeline is invocable directly

## Workflow

### Step 1 — Identify the work item

Ask: *"Which work item are we building? (Jira key, GitHub issue, or press Enter
for local work without a ticket)"* — or use the argument passed directly.

- If a key is given: normalize to uppercase (e.g. `dcp-1234` → `DCP-1234`).
  Set `key = <normalized-key>`. Set `local_work = false`.
- If no key (user pressed Enter or passed nothing): ask for a short kebab-case
  slug describing the work (e.g. `fix-auth-bug`, `refactor-invoice-mapper`).
  Set `key = "local-<slug>"`. Set `local_work = true`.

### Step 2 — Git pre-flight

Run these checks before touching any spec files:

**2a — Clean working tree**

Run `git status --porcelain`. If output is non-empty → stop. Tell the user:

> "Working tree is dirty. Commit, stash, or discard your changes before
> starting a build session. Run `git status` to see what's modified."

**2b — Fetch and check branch state**

Run `git fetch origin` (silent — update remote refs only).

Get the current branch: `git branch --show-current`.

Compare local vs remote:
- `git rev-parse HEAD` vs `git rev-parse origin/<branch>` (if the remote
  ref exists — skip if the branch has no upstream yet).
- If local is **behind** origin: ask *"Your branch is behind origin/<branch>.
  Pull latest before starting? [Y/n]"*. If yes, run `git pull --ff-only`. If no,
  warn and continue.
- If local is **ahead** of origin: warn *"Branch has local commits not yet
  pushed to origin. You are starting from existing work, not a fresh session."*
  Continue (do not stop).

**Upstream sync check** (fork workflows): run `git remote` to list remotes. If an `upstream` remote exists:
1. Run `git fetch upstream` (silent).
2. Find the merge base: `git merge-base HEAD upstream/main` (or `upstream/master` — use whichever exists).
3. Compare the merge base to `upstream/main`: `git rev-list --count <merge-base>..upstream/main`.
4. If the count is > 0: warn *"Your branch base is `<N>` commit(s) behind `upstream/main`. Consider rebasing before starting work to avoid merge conflicts at PR time: `git rebase upstream/main`. Continue anyway? [Y/n]"*. If no: stop. If yes: continue.
5. If no `upstream` remote: skip this check silently.

**2c — Branch check**

If current branch is `main` or `master`: ask *"You're on main. Create a new
branch for this work? [Y/n]"*. If yes, prompt for a branch name (default:
`<key>` lowercased, e.g. `dcp-1234` or `local-fix-auth-bug`). Run:

```
git checkout -b <branch-name>
```

### Step 3 — Validate or create spec

**Ticket path** (`local_work = false`):

Locate the spec folder by prefix-matching: find `specs/<key>-*/` (e.g. `specs/DCP-1234-feature-name/`). Use the first match. This aligns with daff-shape's naming convention of `specs/{KEY}-{slug}/`.

- If no `specs/<key>-*/` folder exists → stop: *"No spec folder found for `<key>`.
  Run daff-shape first to produce shaped artifacts in `specs/<key>-<slug>/`."*
- If `stories.json` is missing → check whether `prd.md` and `design.md`
  both exist in the spec folder. If they do — stop:

  > "No `stories.json` found for `<key>`, but `prd.md` and `design.md` are present.
  > Run `/daff-shape:decompose <key>` to generate `stories.json`, then return to
  > `/build-start`."

  If `prd.md`/`design.md` are also absent — stop:

  > "Folder `specs/<key>-*/` exists but is missing `stories.json`. Run the daff-shape
  > pipeline first to complete the spec."
- If `plan.md` already exists in the spec folder → do NOT stop. Show the plan's title
  and task count, then offer:

  > "A plan already exists for `<key>`:
  > — `<plan-title>` · `<N>` tasks · mode: `<mode>`
  >
  > **(A) Continue existing session** — skip to `/build-refine` (reads the current plan)
  > **(B) Start fresh** — archive `plan.md` to `plan.md.bak` and re-run `/build-refine`
  > **(C) Implement now** — proceed directly to `/build-implement-tdd` or `/build-implement-goal`"
  >
  > Wait for the user's choice before continuing. If (B): rename `plan.md` to `plan.md.bak`
  > in the spec folder, then proceed to Step 4 as normal and invoke `/build-refine`. If (A)
  > or (C): skip to Step 5 (initialize build log) and invoke the appropriate implement skill.
- Warn (do not stop) if optional artifacts are absent: `prd.md`, `design.md`,
  `decisions.md`. State that `/build-refine` will run with reduced context.

**Local-work path** (`local_work = true`):

If `specs/local-<slug>/plan.md` already exists → apply the same recovery offer as the ticket-path (show summary, offer Continue / Start fresh / Implement now). If the user chooses (A) or (C): skip to Step 5 — do NOT run the interview below.

Create `specs/local-<slug>/` if it does not exist.

Run a short interview and write `specs/local-<slug>/design.md` **only if this is a new session** (no existing plan):

> Ask the following three questions, then write the file:
>
> 1. *"What are you trying to accomplish? (1–3 sentences)"*
> 2. *"Which files or components will this touch? (freeform, best guess)"*
> 3. *"Any constraints or things to avoid?"*

Write `specs/local-<slug>/design.md`:

```markdown
# Design: <slug>

## Goal

<answer to question 1>

## Scope

<answer to question 2>

## Constraints

<answer to question 3, or "None stated." if blank>
```

Tell the user: *"No stories.json will be created. `/build-refine` will read
`design.md` and derive a goal and acceptance criteria from it."*

### Step 4 — Select implementation mode

Load @references/pipeline-map.md for mode guidance.

Ask the user to choose the implementation mode for this story:

- **TDD** (default) — RED → GREEN → INTEGRATE → VERIFY per task. For backend
  logic, APIs, services, data processing — any work where behavior can be
  encoded as tests before the implementation exists.
- **Goal** — BUILD → VERIFY RUNTIME → TEST → VERIFY. For UI components,
  configuration changes, database migrations — work where the implementation
  must exist before meaningful tests can be written.

If the user is unsure, ask what the story primarily involves. Default to TDD
when in doubt — `/build-refine` will confirm and may produce a mixed-mode plan.

### Step 5 — Initialize build log

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"session-start","status":"start","data":{"mode":"<tdd|goal>","local_work":<true|false>,"spec_artifacts":[...]}}'
```

List every artifact file found in the resolved `specs/<key>-*/` folder in the `spec_artifacts` array.

### Step 6 — Hand off to build-refine

Tell the user what to expect from `/build-refine`: it will read spec artifacts,
inspect the codebase, and produce `plan.md` in the spec folder — a task list with file
targets, test strategy, and acceptance mapping. It is interactive and will ask
questions before finalizing the plan.

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"session-end","status":"ok","data":{"next":"build-refine"}}'
```

Invoke `/build-refine <key>`.
