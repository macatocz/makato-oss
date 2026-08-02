---
name: build-start
description: >-
  Entry point for a full build session — validates git state, validates spec
  prerequisites, captures implementation mode, initializes the build log, and
  kicks off /build-refine. Use when starting a new story build, beginning the
  makato-build workflow, running build-start on a work item, or starting local
  work without a ticket.
version: "1.5.0"
argument-hint: "[work-item-key]"
---

# build-start

## When to Use

Use at the beginning of every makato-build session, before `/build-refine`.

For ticket-based work: spec artifacts must have been produced by makato-plan
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

### Step 2.5 — Mark In Progress on project board

Only when `local_work = false`. This is the earliest safe moment to claim the issue — git state is clean and work is about to start. Marking now prevents the autonomous loop from picking up the same issue concurrently.

**Determine the GitHub issue number:**

1. If `key` is a plain integer (e.g., `450`): use it directly as `ISSUE_NUMBER`.
2. Otherwise: look for `specs/<key>-*/seed-manifest.json` or `specs/<key>/seed-manifest.json` and read `.issue_number` from it:
   ```bash
   ISSUE_NUMBER="$(jq -r '.issue_number // empty' specs/${key}-*/seed-manifest.json 2>/dev/null | head -1)"
   # fallback: exact-match folder
   [[ -z "$ISSUE_NUMBER" ]] && ISSUE_NUMBER="$(jq -r '.issue_number // empty' specs/${key}/seed-manifest.json 2>/dev/null || true)"
   ```
3. If `ISSUE_NUMBER` remains empty: skip this step silently (Jira-only key with no manifest — cannot resolve to a board item).

**Read project config** from `.claude/config.json`. If the `github_project` block is absent, or any of `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number` are missing, skip with:
> `build-start: WARN — .claude/config.json has no github_project config — board status not updated`

**Otherwise:**

1. Find the board item and its current status:
   ```bash
   ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
     --owner "$OWNER" --format json --limit 9999 \
     --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
     | head -1)"
   ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
   CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
   ```
   If `ITEM_ID` is empty: log `build-start: WARN — issue #$ISSUE_NUMBER not found on board; skipping In Progress update` and continue.

2. Set Status = In Progress (only if not already set):
   If `CUR_STATUS` is already `"In progress"`: log `build-start: #$ISSUE_NUMBER is already In Progress — skipping` and continue.
   Otherwise:
   ```bash
   GH_HOST="$HOST" gh project item-edit \
     --id "$ITEM_ID" \
     --project-id "$PROJECT_NODE_ID" \
     --field-id "$STATUS_FIELD_ID" \
     --single-select-option-id "$IN_PROGRESS_OPTION_ID"
   ```
   On success: log `build-start: marked #$ISSUE_NUMBER as In Progress on project board`.
   On failure: log `build-start: WARN — could not set In Progress on board; continuing` (best-effort — never block the build session).

### Step 3 — Validate or create spec

**Ticket path** (`local_work = false`):

Locate the spec folder using a two-step resolution:

1. **Prefix-match**: find `specs/<key>-*/` (e.g. `specs/DCP-1234-feature-name/`). Use the first match. This aligns with makato-plan's naming convention of `specs/{KEY}-{slug}/`.
2. **Exact-match fallback**: if no prefix-match exists, check for `specs/<key>/` (exact folder name). This covers issues seeded directly without a slug suffix.

Resolution order: (1) `specs/<key>-*/` prefix-match; (2) `specs/<key>/` exact-match fallback.

- If no `specs/<key>-*/` folder exists → stop: *"No spec folder found for `<key>`.
  Run makato-plan first to produce shaped artifacts in `specs/<key>-<slug>/`."*
- If `stories.json` is missing → check whether `prd.md` and `design.md`
  both exist in the spec folder. If they do — stop:

  > "No `stories.json` found for `<key>`, but `prd.md` and `design.md` are present.
  > Run `/makato-plan:decompose <key>` to generate `stories.json`, then return to
  > `/build-start`."

  If `prd.md`/`design.md` are also absent — stop:

  > "Folder `specs/<key>-*/` exists but is missing `stories.json`. Run the makato-plan
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

### Step 4.5 — Resolve workflow schema

Before initialising the build log, resolve the workflow schema for this session.
The schema determines which skill artifacts are assembled into the pipeline.

Run `workflow-schema-loader.sh` passing the repository root as the first argument:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
ARTIFACT_LIST="$(bash scripts/workflow-schema-loader.sh "$REPO_ROOT" 2>/tmp/schema-loader-err)"
SCHEMA_EXIT=$?
```

**On exit 0:** `ARTIFACT_LIST` contains one JSON object per line, each with fields
`id`, `skill`, `required`, `description`. Use this list to assemble the pipeline
order for Step 6. Log the resolved schema source:

```bash
SCHEMA_SOURCE="custom"   # or "default" — readable from first loader stderr line or infer:
# if .claude/workflow-schema.yml is absent → "default"
if [[ ! -f "$REPO_ROOT/.claude/workflow-schema.yml" ]]; then
  SCHEMA_SOURCE="default"
fi
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"schema-resolved","status":"ok","data":{"source":"<default|custom>","artifact_count":<N>}}'
```

**On exit 1 or 2:** The schema is invalid (parse error, cycle detected, or missing
arg). Do NOT continue — stop and report:

> "Workflow schema error: `<contents of /tmp/schema-loader-err>`
>
> Fix `.claude/workflow-schema.yml` before starting the build session. See
> `docs/workflow-schema.md` for format documentation."

Log the error:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"schema-resolved","status":"error","error":"<loader stderr>"}'
```

### Step 5 — Initialize build log

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"session-start","status":"start","data":{"mode":"<tdd|goal>","local_work":<true|false>,"spec_artifacts":[...],"schema_source":"<default|custom>"}}'
```

List every artifact file found in the resolved `specs/<key>-*/` folder in the `spec_artifacts` array.
Include `schema_source` from Step 4.5.

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
