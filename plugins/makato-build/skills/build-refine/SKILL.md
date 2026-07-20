---
name: build-refine
description: >-
  Bridge a shaped Jira story, GitHub issue, or any work unit to an
  implementation plan — tasks, file targets, unit/integration test
  strategy, acceptance mapping. Use to start a build session before
  implement-tdd or implement-goal.
version: "1.9.0"
model: opus
argument-hint: "[work-item-key] [--autonomous]"
---

# refine

## When to Use

Use at the start of every build session, after a story has been shaped by makato-plan (or an equivalent process). Spec artifacts must exist in `specs/<key>-*/` before this skill can run.

**Do NOT use when:**
- The story has not been shaped (no spec artifacts exist) — run makato-plan first
- You want to continue an in-progress implementation — read `plan-<ISSUE_NUMBER>.md` in the spec folder directly
- You are implementing changes to existing functionality from updated business requirements — use `makato-change` instead

## Input

When dispatched by the PO-agent on a re-plan cycle (`--autonomous` mode):

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). Plan-file writes target `$REPO_ROOT/specs/<key>-*/plan-<ISSUE_NUMBER>.md` (main checkout — `specs/` is gitignored in worktrees); the worktree path is captured so the falsy-check is symmetric across the pipeline.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`.

Spec-artefact reads + plan writes go to `$REPO_ROOT/specs/<key>-*/`:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

## Workflow

### Step 1 — Ask for the work item key

If an argument was passed when invoking this skill, use it directly. Otherwise, use the `AskUserQuestion` tool to ask for the work item key, with example options: `DCP-1234`, `#123`, or a freeform key. Remind the user they can skip this prompt next time by passing the key directly: `/makato-build:build-refine #123`.

Accept any identifier: Jira key (`DCP-1234`), GitHub issue (`#123` or `gh-123`), or freeform. Sanitize for use as a filesystem path component: replace `#` and spaces with `-`, lowercase.

### Step 1a — Mode detection

Load `@../../AUTONOMOUS-MODE.md` for the activation contract (§ *Activation triggers*) and the per-gate default table.

The skill runs in `--interactive` mode by default; the canonical activation triggers for `--autonomous` mode are listed in `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode, the work-item-key `AskUserQuestion` above is replaced by:
- If an argument was passed: use it.
- If no argument: HALT with `MISSING_INPUT: build-refine in --autonomous mode requires a work-item-key argument`. Write `build.jsonl` entry `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}` and return an R1 `status:"failure"` envelope. The PO-agent's responsibility is to supply the key from workflow-state — this skill does not prompt.

Log the bypass via `shared/log-bypass.sh build-refine "<key>" work-item-key use-arg "<agent_id|cli_flag|task_id_bundle>"` when bypassed.

### Step 1b — Headless-context defensive guard

The three autonomous triggers in Step 1a are opt-in signals from the caller. But a caller can *forget* to set any of them — for example, a headless `claude -p …` invocation whose prompt does not name the po-agent subagent or thread `--autonomous`. In that case Step 1 and Step 11 would fire `AskUserQuestion`, the headless subprocess has no stdin, and the skill would deadlock silently. This is the class of failure originally hit in #160 and defended against here per #163.

**Guard:** if the caller has explicitly declared the invocation is headless via the env var `MAKATO_HEADLESS=1` AND none of the three autonomous triggers fired (no `--autonomous` on the CLI, no `$AGENT_ID` in the env, no `task_id` in the context bundle), the skill MUST HALT before the first `AskUserQuestion`. Do NOT prompt; do NOT auto-fall-back to autonomous mode. The correct upward signal is:

- Write `build.jsonl` entry: `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT", message:"build-refine invoked in a headless context (MAKATO_HEADLESS=1) without any autonomous trigger — Step 1 or Step 11 would deadlock on AskUserQuestion. Set --autonomous on the CLI, export $AGENT_ID, or supply a context bundle with task_id."}}`.
- Return an R1 envelope with `status: "failure"`, `errors: ["MISSING_INPUT: headless-without-autonomous"]`, and `data.halt_code: "MISSING_INPUT"`.
- Do not proceed to Step 2.

**Why an explicit env var and not tty auto-detection:** inside a Claude Code Bash tool `stdin`/`stdout` are always pipes, even in a fully interactive human-driven session. A `[[ ! -t 0 ]]` auto-detector would false-positive and kill legitimate interactive runs. `MAKATO_HEADLESS=1` is a caller-side assertion: "I am `claude -p`, no human is at the prompt, refuse to hang."

**Interaction with the three autonomous triggers:** the guard is a strict AND with "no autonomous trigger fired." `MAKATO_HEADLESS=1` + `--autonomous` proceeds under autonomous mode (autonomous wins). `MAKATO_HEADLESS=1` + `$AGENT_ID` proceeds under autonomous mode. `MAKATO_HEADLESS` unset lets the interactive path run as before. The guard fires only when the caller says "I'm headless" AND provides no autonomous signal — a contract violation, not a normal path.

**Callers responsible for exporting `MAKATO_HEADLESS=1`:** `plugins/makato-orchestrate/scripts/loop.sh` (`cmd_dispatch`) and `plugins/makato-orchestrate/scripts/context-handoff.sh` (`_emit_resume`). Any new headless caller of `build-refine` (or any other `build-*` skill inheriting this contract) must export the variable on their side of the boundary.

### Step 2 — Log session start and prepare workspace

Check that a spec folder exists using the following two-step resolution order:

```
Resolution order:
1. `ls specs/<key>-*/ 2>/dev/null | head -1`   (prefix-match, canonical)
2. `[[ -d specs/<key>/ ]]`                       (exact-match fallback)
```

Step 1 matches the canonical `specs/<N>-<slug>/` naming used by `to-issues`. Step 2 matches bare `specs/<slug>/` folders from makato-plan and `specs/<issue-key>/` folders from makato-change. Use whichever resolves first; the resolved path becomes the spec folder for all subsequent reads and writes.

If neither matches, stop immediately and tell the user:

> "No spec found for `<key>`. This story has not been shaped yet — run `/makato-plan:decompose` (or the full makato-plan pipeline) first, then return to `/refine`."

Do not proceed past this step until the directory exists.

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-refine","story":"<key>","step":"session","status":"start","data":{}}'
```

### Step 3 — Load spec artifacts

Load @references/spec-artifacts-schema.md to know what fields to extract from each file.

Read from the resolved spec folder (`specs/<key>-*/`):
- `seed-manifest.json` — optional; carries the `spec_tier` routing flag (see below)
- `stories.json` — required for ticket-based work; absent for lightweight work (see below)
- `prd.md` — required for ticket-based work; optional for lightweight work
- `design.md` — required for `local-` prefix work; optional otherwise
- `plan-<ISSUE_NUMBER>.md` — required for `spec_tier:plan-only` work (sole acceptance source); optional otherwise. When `ISSUE_NUMBER` is not yet known at discovery time, match `plan-*.md` and use the first match.
- `decisions.md` — optional
- `prototype.html` — optional; if present, flag the story as having a UI reference

**Detect the lightweight tier first.** Read `seed-manifest.json` if it exists and parse
its optional `spec_tier` field. This is a NEW read for build-refine — earlier versions of
this skill read no manifest. Treat an absent file, an absent field, or an unparseable
manifest as "no tier" (legacy behavior — never HALT on manifest read):

```bash
MANIFEST="$(ls specs/<key>-*/seed-manifest.json 2>/dev/null | head -1)"
SPEC_TIER="$(jq -r '.spec_tier // ""' "$MANIFEST" 2>/dev/null || echo "")"
```

A work item enters the **lightweight path** when EITHER of these is true:
- the KEY starts with `local-` (legacy local-work trigger), OR
- `spec_tier == "plan-only"` (numeric-slug KEYs like `123-add-feature` that never match
  `local-*` — this is exactly why the manifest read is required).

On the `spec_tier:plan-only` path, the plan file is `plan-<ISSUE_NUMBER>.md` (per-issue name).
Resolve `ISSUE_NUMBER` from the work-item KEY (the leading numeric segment) and look for
`specs/<key>-*/plan-<ISSUE_NUMBER>.md`. Legacy fallback: if the per-issue file is absent but
`plan.md` exists in the folder, accept it and log
`[build-refine] legacy-pass: found plan.md; per-issue file plan-<N>.md absent`.

Both triggers resolve to the **same single lightweight branch** — a manifest carrying both
a `local-` prefix and `spec_tier:plan-only` is not a conflict; it takes the lightweight
path once. `stories.json` and `prd.md` are NOT required on this path; do not read or
reference them.

**Lightweight path — acceptance-source sub-rules:**

- **`spec_tier:plan-only`** (the new trigger): `plan.md` is the sole acceptance source.
  Read its `## Acceptance criteria` section (see Step 4). This path **bypasses the
  `design.md`-missing guard below** — `design.md` is optional and its absence is never a
  stop condition. If `plan-<ISSUE_NUMBER>.md` is missing entirely, HALT with `MISSING_PLAN` (guide the
  caller to run the light-planner / seed-issue that materializes the plan).

- **`local-` prefix without `spec_tier:plan-only`** (legacy): if `design.md` is present,
  read it as the sole input artifact. Derive the goal from the `## Goal` section and treat
  each sentence in `## Constraints` as a fixed decision. Acceptance handling is unchanged
  (synthetic AC — see Step 4). Continue without stopping. If `design.md` is also missing →
  stop: tell the user to run `/build-start` first to create the design document.

**Ticket path** (not lightweight): if `stories.json`, `prd.md`, or
`design.md` is missing, report which files are absent and stop. Tell the user to run
makato-plan first or confirm the correct spec path. Append an `"status":"error"` entry to
`build.jsonl` before stopping.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"load-artifacts","status":"ok","data":{"path":"<ticket|lightweight>","spec_tier":"<plan-only|none>","trigger":"<local-prefix|plan-only|both|none>"}}'` — the `data.path` and `data.spec_tier` fields make the plan-only branch entry auditable in `build.jsonl` (design.md Observability § *build-refine plan-only entries*).

### Step 4 — Extract story details

**Ticket path**: find the entry in `stories.json` whose key matches `<key>`. Extract:
- Title and functional description
- Acceptance criteria — from `description.successScenarios[]`, numbered AC-1, AC-2, … by index. These are the PO/decompose-authored scenarios that drive task decomposition and the AC coverage table.
- **Acceptance Test Oracle** — from `description.acceptanceTestCases[]` when that array is non-empty. These are the QA-refined scenarios from the `create-acceptance-tests` skill; they do NOT create new AC numbers — they are copied into the plan's `## Acceptance Test Oracle` section (Step 10) so the coder implements them as exact RED tests. When `acceptanceTestCases[]` is absent or empty, no oracle section is written — byte-for-byte legacy behavior.
- Phase assignment and story type
- Dependencies (work item keys that must be merged before this one)

If the key is not found in stories.json: report it and ask the user to confirm the key.

`stories.json` is the authoritative source for story content. If the content diverges from the Jira ticket, prefer `stories.json` — it captures the shaped and refined version of the story.

**Local-work path** (`local-` prefix, no `spec_tier:plan-only`): no stories.json. The goal
from `design.md` serves as the story description. Generate one synthetic acceptance
criterion: *"AC-1: <goal statement> is implemented and all tests pass."* Note in the plan
that this story has no formal ACs and the done-condition is self-evident from the goal.

**Plan-only path** (`spec_tier:plan-only`): `plan-<ISSUE_NUMBER>.md` is the authoritative source. Do NOT
generate a synthetic AC-1 — real acceptance criteria exist in the plan. Read the
`## Acceptance criteria` section of `plan-<ISSUE_NUMBER>.md` and extract each non-empty list item (or line)
as AC-1, AC-2, … by order. The plan-only path and the "AC from plan-<N>.md, not synthetic"
behavior land together — one without the other is incorrect.

**Empty-or-missing guard (plan-only only):** if `plan-<ISSUE_NUMBER>.md` has no `## Acceptance criteria`
heading, OR the section exists but contains no non-empty acceptance items (whitespace,
placeholder stub text such as the seed-issue `_To be filled in…_` line, or only comments),
treat both cases **identically** and HALT with `MISSING_ACCEPTANCE`:

> "HALT MISSING_ACCEPTANCE: `plan-<ISSUE_NUMBER>.md` for `<key>` is `spec_tier:plan-only` but its
> `## Acceptance criteria` section is absent or empty. A plan-only work item must carry at
> least one concrete acceptance criterion. Add criteria to
> `specs/<key>-*/plan-<N>.md` under `## Acceptance criteria` (one bullet per testable outcome)
> and re-dispatch `/makato-build:build-refine <key> --autonomous`."

Append `{"ts":"…","skill":"build-refine","story":"<key>","step":"extract-story","status":"error","data":{"halt_code":"MISSING_ACCEPTANCE"}}`
to `build.jsonl` and return an R1 `status:"failure"` envelope with
`data.halt_code:"MISSING_ACCEPTANCE"`. Never proceed to Step 5 with zero ACs on the
plan-only path — a silent zero-AC plan is the failure this guard prevents.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"extract-story","status":"ok","data":{"ac_count":<N>,"oracle_scenarios":<M>}}'`

### Step 5 — Read domain and architecture context

From `prd.md`: understand the user-facing goal, non-functional requirements, success metrics, and explicitly out-of-scope items.

From `design.md`: identify which components are involved, API contracts, data model, and the prescribed technical approach.

From `decisions.md` (if present): note constraints from prior decisions that bound the implementation. Treat every decision record as a fixed constraint — do not re-open decisions here.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"load-artifacts","status":"ok","data":{"files_read":[…]}}'`

### Step 5.5 — Load knowledge graph (conditional)

Before exploring the local `context/` directory, attempt to load knowledge from the project specs repository:

Derive REPO_NAME from the last path segment of the target repo root. Extract 5–10 key terms from the story title and description (from `stories.json`) as KEYWORDS.

Dispatch the `knowledge-scout` agent with REPO_ROOT, REPO_NAME, and KEYWORDS. The agent handles project specs discovery internally (makato.config.json → in-repo `specs/` → skip).

Receive the Knowledge Scout Findings and:
- Apply every item in `## Hard Constraints` as a mandatory rule in the implementation plan — note these in the plan header so the user sees them
- Apply `## Standards` as naming and pattern conventions for all tasks, file targets, and interfaces
- Use `## Architecture Context` to inform layer structure and file placement decisions

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"load-knowledge-graph","status":"ok","data":{"loaded":<true|false>,"source":"<local|none>","constraints":<N>}}'`

If the agent returns `loaded: false`: log and continue to Step 6 without change.

When constraints are found, include a summary line in the plan header presented to the user:
> "Knowledge graph: {N} hard constraints loaded from project specs ({source}). Applied to all tasks."

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
- **recommended_skills** *(optional)*: array of `"plugin:skill-id"` strings inherited from `stories.json` sub-task `recommended_skills[]` when present (agent-skill-routing #146). When this field appears in `plan-<N>.md`, downstream implementation skills (`build-implement-tdd`, `build-implement-goal`) MUST include it as `RECOMMENDED_SKILLS` in the coder dispatch bundle. Omit this field entirely when the stories.json sub-task carries no `recommended_skills`.

**RECOMMENDED_SKILLS pass-through rule**: when building the plan from a `stories.json` that was produced by the `decompose` skill (v1.2.0+), check each sub-task for a `recommended_skills` field. If present and non-empty, copy it verbatim into the corresponding plan task under `recommended_skills`. The downstream coder then prepends skill consultation instructions before implementing the task. If absent — do NOT add an empty array; omit the field.

The full task list must be completable in a single autonomous session (target 2–6 tasks). If more tasks are needed than fit in one session, flag it before proceeding — ask the user to confirm scope or split the story.

**File target validation**: before writing the plan, verify every `files` entry across all tasks is a relative path that resolves within the repository root. Reject any path that begins with `/` or contains `..` segments. If an invalid path is found — stop and report it:

> "Invalid file target in task <N>: `<path>`. All file targets must be relative paths within the repository root. Please correct the spec's design.md and re-run /build-refine."

### Step 9 — Map acceptance criteria to tasks

Build a coverage table: for each AC, which task(s) satisfy it?

Every AC must be covered by at least one task. If any AC has no task: add a task or split an existing task to make coverage explicit. Do not proceed to Step 10 with uncovered ACs.

### Step 10 — Write the implementation plan

Load @references/plan-schema.md.
Read `templates/plan-template.md` and use it as the base for the output.

Derive `ISSUE_NUMBER` from the numeric leading segment of the work-item key (e.g. key `510-foo` → `plan-510.md`).

**Pre-write guard:** Before writing `plan-<ISSUE_NUMBER>.md`, check whether the file already exists in the resolved spec folder. If the file exists:
- Read its content and check whether the `## Tasks` section is substantive: it is considered substantive if it is non-empty AND does not contain only stub placeholder text (patterns: `_To be filled in`, `_To be enriched by build-refine`, `<!-- to-issues:auto`-only with no real task items).
- If substantive: use **enrichment mode** — treat the existing file's `## Tasks` and `## Acceptance criteria` content as the starting point. Merge by rewriting the file with the refined output from Steps 7-9, keeping the existing structure but replacing or extending individual sections with the refined analysis. Do not overwrite the `## Story` metadata block. Log the decision:
  ```bash
  shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"write-plan","status":"ok","data":{"tasks":<N>,"oracle_scenarios":<M>,"plan_file":"<path>","enriched_existing":true}}'
  ```
- If the file does not exist, or is a stub (empty `## Tasks`, or placeholder-only content): proceed with the normal write (existing behavior). `enriched_existing` is `false` in the JSONL.

The enrichment approach ensures that a `to-issues`-emitted `plan-<N>.md` (which already has real `## Tasks` derived from `description.scope` and real `## Acceptance criteria` derived from `successScenarios[]`) is treated as a first-pass that build-refine extends and sharpens — not discards.

Write `plan-<ISSUE_NUMBER>.md` in the resolved spec folder with all fields populated from the template.

**Acceptance Test Oracle pass-through rule**: when the story from `stories.json` carries a non-empty `description.acceptanceTestCases[]` (Step 4), write a `## Acceptance Test Oracle` section into `plan-<ISSUE_NUMBER>.md` per `@references/plan-schema.md` § *Acceptance Test Oracle Schema*. Copy each scenario verbatim (Gherkin `given`/`when`/`then`/`and` shape) and annotate it `(maps to AC-N)` by aligning it to the AC coverage table from Step 9 — match on the scenario's outcome, or use `AC-*` when it applies story-wide. When `acceptanceTestCases[]` is absent or empty, do NOT emit the section — omit it entirely (legacy default). The oracle never introduces new AC numbers; it only supplies exact RED-test scenarios the coder implements downstream.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-refine","story":"<key>","step":"write-plan","status":"ok","data":{"tasks":<N>,"oracle_scenarios":<M>,"plan_file":"<resolved-spec-folder>/plan-<ISSUE_NUMBER>.md","enriched_existing":<bool>}}'`

### Step 11 — Present plan and iterate

In **autonomous mode**, skip this step entirely: write `plan-<ISSUE_NUMBER>.md` (already done in Step 10), log the bypass via `shared/log-bypass.sh build-refine "<key>" plan-review approve "<agent_id|cli_flag|task_id_bundle>"`, and proceed to Step 12.

In **interactive mode**, use the `AskUserQuestion` tool to ask: "The plan is ready. How would you like to review it before implementation starts?" with two options:
- **In chat** — description: "Show the plan as markdown in this conversation. You can reply with feedback or edits."
- **In browser** — description: "Generate an interactive HTML page with per-task feedback fields and open it in your browser. Copy your feedback and paste it back here when done."

**If Terminal**: display `plan-<ISSUE_NUMBER>.md` content inline. Ask: "Does this plan look accurate? Any tasks missing, wrong files, or scope concerns?"

**If Browser**:
1. Read `@templates/plan-review-template.html`.
2. Populate it with: story title, task list (title, files, tests, AC links, mode), and AC coverage table.
3. Write the result to `plan-review.html` in the spec folder.
4. Open with the platform command (`open` / `xdg-open` / `start`).
5. Tell the user: "Plan review is open in your browser. Add feedback in the textareas and click 'Copy Feedback' when done, then paste it here."
6. Wait for pasted feedback; proceed as terminal mode below.

If the user requests changes: update `plan-<ISSUE_NUMBER>.md` in the spec folder and ask again. Each revision appends:
```
{"ts":"…","skill":"build-refine","story":"<key>","step":"plan-revision","status":"ok","data":{"revision":<N>}}
```
Repeat until the user approves.

### Step 12 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-refine","story":"<key>","step":"session","status":"ok","data":{"tasks":<N>,"mode":"<tdd|goal|mixed>","plan":"<resolved-spec-folder>/plan-<ISSUE_NUMBER>.md"}}'
```

Tell the user: "Plan written to `plan-<ISSUE_NUMBER>.md` in the spec folder. Next: run `/grill-with-docs` to validate terminology against the codebase, or proceed directly with `/implement-tdd` or `/implement-goal`."

**Grill-with-docs recommendation**: run `/build-grill-with-docs` if either condition is met:
- `glossary.md` exists in the spec folder and contains 3 or more terms
- The plan touches domain-specific field names (entity fields, API paths, enum values — not generic names like `service` or `handler`)

Skip `/build-grill-with-docs` for infra/config-only changes (no domain-model files touched). State the recommendation inline.

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — the Step 1 work-item-key gate and the Step 11 plan-review gate are bypassed per the rules above.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md`.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output (schema: `plugins/makato-build/agents/RETURN-CONTRACT.md`).

**Defensive-headless guard (#163):** if `MAKATO_HEADLESS=1` is set AND no autonomous trigger fired, the skill HALTs before Step 2 per Step 1b rather than proceeding interactively — the headless subprocess would otherwise deadlock on `AskUserQuestion`. See Step 1b for the full contract.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "data": {
    "plan_path": "specs/<key>-<slug>/plan-<ISSUE_NUMBER>.md",
    "tasks": <N>,
    "mode": "tdd" | "goal" | "mixed",
    "knowledge_graph_loaded": <true|false>,
    "hard_constraints": <N>,
    "ac_coverage_complete": <true|false>
  }
}
```

`agent` is `"build-refine"`. `summary` is `"Refined plan with N tasks (mode: tdd|goal|mixed)"`. `files_changed` is `["specs/<key>-<slug>/plan-<ISSUE_NUMBER>.md"]` on success.

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `SPEC_NOT_FOUND`, `MISSING_ARTIFACTS`, `MISSING_PLAN`, `MISSING_ACCEPTANCE`, `INVALID_FILE_TARGET`, `UNCOVERED_AC`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.
