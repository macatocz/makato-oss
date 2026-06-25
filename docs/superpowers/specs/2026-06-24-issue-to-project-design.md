<!-- markdownlint-disable MD013 -->
# `issue-to-project` Skill — Design Spec

**Date:** 2026-06-24
**Author:** brainstorming session
**Status:** approved (ready for writing-plans handoff)
**Target:** new skill `plugins/makato-plan/skills/issue-to-project/` v1.0.0
**Branch:** `feat/issue-to-project-skill` (off `main`, which carries `to-issues` v3.2.0 at commit `6326513`)

## Goal

Ship a new `issue-to-project` skill in the `makato-plan` plugin that flawlessly follows `to-issues`: every issue created by `to-issues` lands on the consumer's GitHub Projects v2 board, with Status set to `Blocked` when the issue carries the `status:blocked` label and left at the project default (`Todo`) otherwise. The skill is the natural workflow successor to `to-issues` (`to-issues` → `issue-to-project` reads as the pipeline of "publish stories → land them on the board"). It does **not** handle PR-merge lifecycle transitions (In Progress, Done) in v1 — those are explicitly deferred to a v2 follow-up.

## Why this skill exists now

`to-issues` v3.2.0 (PR #14, merged) added `status:` as the 5th label dimension and emits `status:blocked` on issue creation when applicable. Without `issue-to-project`, that label is repo-side metadata only — the actual GitHub Project board never reflects the `Blocked` state, and a contributor scanning the board sees every new issue land in `Todo` regardless of upstream dependencies. The new skill closes that loop with a single batched call after each `to-issues` invocation.

## Architecture

Single skill at `plugins/makato-plan/skills/issue-to-project/`. Two execution paths share one config reader and one `gh project` wrapper; they have no other shared state.

```
plugins/makato-plan/skills/issue-to-project/
├── SKILL.md
├── references/
│   ├── config-schema.md
│   ├── init-wizard.md
│   ├── sync-process.md
│   └── project-sync.schema.json
```

### Execution paths

```
                      ┌─────────────────────────────┐
                      │   issue-to-project --init   │
                      └─────────────┬───────────────┘
                                    │
                      ┌─────────────▼───────────────┐
                      │ 1. gh api user → owner login│
                      │ 2. gh project list          │
                      │ 3. prompt: pick or create   │
                      │ 4. gh project field-list    │
                      │ 5. validate 4 Status opts   │
                      │ 6. write .claude/config.json│
                      └─────────────────────────────┘

                      ┌─────────────────────────────┐
                      │   issue-to-project [slug]   │
                      └─────────────┬───────────────┘
                                    │
       ┌────────────────────────────▼────────────────────────────┐
       │ 1. read .claude/config.json → github_project (or abort) │
       │ 2. read specs/{slug}/created-issues.json (or abort)     │
       │ 3. gh project item-list → URL set on board              │
       │ 4. for each issue NOT on board:                         │
       │      gh project item-add  → returns project-item ID     │
       │      if labels contains status:blocked:                 │
       │        gh project item-edit Status=Blocked              │
       │ 5. write specs/{slug}/project-sync.json                 │
       └─────────────────────────────────────────────────────────┘
```

### Components

| Component | Purpose | Interfaces |
|---|---|---|
| `SKILL.md` | Frontmatter + invocation contract + step-by-step process + reference loads. Mirrors `to-issues`'s style. | Reads `.claude/config.json`, `specs/{slug}/created-issues.json`. Writes `specs/{slug}/project-sync.json`. Calls `gh`. |
| `references/init-wizard.md` | The 6-step `--init` flow with exact `gh` invocations, GraphQL field paths, prompt phrasing, and config-write template. Loaded only when `--init` is in argv. | Reads nothing extra. Writes the `github_project` block into `.claude/config.json`. |
| `references/sync-process.md` | The 5-step normal-run flow with exact `gh` invocations, the re-run-guard comparison logic, the status-edit decision rule (`status:blocked` in `labels[]` → `Blocked`, else no-op), and audit-artifact emission rules. Loaded on every normal run. | Same as SKILL.md's interfaces. |
| `references/config-schema.md` | Human-readable doc of the `github_project` block — required keys, examples for user-owned vs org-owned projects, examples of what the IDs look like. Runtime validation lives in SKILL.md's Python parse step; this file is the contract for human readers and other skills. | None at runtime. |
| `references/project-sync.schema.json` | JSON Schema for the audit artifact this skill emits per run. Mirrors the shape of `created-issues.schema.json` from `to-issues`. | Validated against on write. |

### Subagent dispatch

None. The skill runs in-process — no parallel agent fan-out, no MCP. Whole skill is `gh` + `python3` glue. Inherits the session default model tier (no `model: opus` declaration; not a judgment-heavy interview skill).

### Dependencies on other skills

- **Hard dependency:** `to-issues` v3.2.0+ — the `created-issues.json` shape with `status:blocked` in `labels[]` is the input contract. Earlier `to-issues` versions won't emit `status:blocked`, in which case `issue-to-project` adds every issue at the project default (Todo) and writes no `Blocked` edits — degrades gracefully.
- **Soft dependency:** `build-create-pr` — downstream of this skill in the workflow; no direct call.

## Scope

### In scope (v1)

- Two execution modes:
  - `--init` — one-time setup wizard. Discovers the user's GitHub Projects v2 board, prompts to pick or create one, resolves the Status field + four option IDs (Todo / In Progress / Done / Blocked), writes them into `.claude/config.json` → `github_project`. Idempotent — re-running re-prompts and overwrites.
  - Normal invocation (no flag) — reads `specs/{slug}/created-issues.json`, reads cached `github_project` block, snapshots existing board items once, then adds each not-yet-on-board issue and sets `Blocked` only when labeled.
- New `.claude/config.json` key: `github_project` (block, schema in §"Config Schema").
- `github.com` only. Every `gh` invocation prefixed `GH_HOST=github.com` to bypass any enterprise `GH_ENTERPRISE_TOKEN` env var.
- `DRY_RUN=1` env var — performs all reads, prints the writes that would happen, makes no GraphQL mutations. Same idiom `to-issues` uses.

### Out of scope (deferred to v2 or later)

- PR-opened → `In Progress`, PR-merged → `Done`, blocker-closed → `Blocked`→`Todo` lifecycle transitions.
- Webhook listeners, polling daemons, GitHub Actions integration.
- Bulk reconciliation of pre-existing issues that weren't created by `to-issues`.
- Cross-repo project sync (sagibeast project receives only sagibeast-repo issues; if a project later accepts items from multiple repos, that's a v2 problem).
- Milestone, Iteration, Reviewer, or any non-Status field sync.

### Hard guarantees

1. The skill never **removes** an item from the board. Issues only ever get added or status-edited.
2. The skill never overwrites a Status that was changed by a human (or by something else) after the board entry was created. The re-run guard (step 3 of the normal flow) exempts already-on-board items from status writes entirely. If a human moves an issue from `Blocked` → `In Progress`, the next `issue-to-project` run will not flip it back, even if `status:blocked` is still on the issue's labels.
3. The skill is a **strict consumer** of `to-issues`'s contract. `labels[]` on `created-issues.json` is the only signal it reads for status routing. It does not query labels from the GitHub issue directly — that decouples `issue-to-project` from human relabeling that happened between `to-issues` and `issue-to-project`.

## Config Schema (`.claude/config.json` → `github_project`)

Lives alongside the existing `"project": "sagibeast"` key. Additive — does not break other skills.

```json
{
  "project": "sagibeast",
  "github_project": {
    "owner": "zstary",
    "owner_type": "user",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1",
    "project_node_id": "PVT_kwHOA6QjJ84BajMV",
    "status_field_id": "PVTSSF_lAHOA6QjJ84BajMVzhVaBWs",
    "status_field_name": "Status",
    "options": {
      "todo": "f75ad846",
      "in_progress": "47fc9ee4",
      "done": "98236657",
      "blocked": "8b7c5461"
    },
    "init_timestamp": "2026-06-24T16:30:00Z",
    "init_skill_version": "1.0.0"
  }
}
```

| Field | Required | Source | Purpose |
|---|---|---|---|
| `owner` | yes | `gh api user` for user-owned; user choice for org-owned | Project owner login |
| `owner_type` | yes | `"user"` or `"organization"` | Selects the right GraphQL root in `gh project` calls |
| `number` | yes | User picks from `gh project list` | Project number (human-visible, stable across renames) |
| `url` | yes | Computed from owner + number | Human-clickable sanity check in the config |
| `project_node_id` | yes | `gh project view` | Opaque GraphQL ID — needed for `item-add` |
| `status_field_id` | yes | `gh project field-list` | Opaque field ID — needed for `item-edit` |
| `status_field_name` | yes | Literal `"Status"` in v1 (validated, not hardcoded) | Documents which field was wired up; lets re-init detect drift |
| `options.todo` | yes | Single-select option ID for "Todo" | Reserved for v2 lifecycle; not used by v1 writes but cached for completeness |
| `options.in_progress` | yes | Single-select option ID for "In Progress" | Reserved for v2 |
| `options.done` | yes | Single-select option ID for "Done" | Reserved for v2 |
| `options.blocked` | yes | Single-select option ID for "Blocked" | **The only one v1 writes against.** Failure-to-resolve aborts `--init`. |
| `init_timestamp` | yes | UTC ISO-8601 at write time | Audit trail |
| `init_skill_version` | yes | This skill's frontmatter version | Lets a future skill upgrade detect stale config and prompt re-init |

### Validation rules (enforced on every read)

1. **Block existence.** Missing `github_project` → abort: `"issue-to-project: .claude/config.json missing 'github_project' block. Run 'issue-to-project --init' to set up project board sync."`
2. **Required keys.** Any required key missing or empty → abort, name the missing key, suggest re-init.
3. **ID format sanity.** `project_node_id` must start with `PVT_`, `status_field_id` must start with `PVTSSF_`, option IDs must be 8-char hex. Fails fast on copy-paste corruption.
4. **No live GraphQL probe.** The skill does NOT call `gh project view` on every run to validate IDs — that defeats the point of caching. The first sync run after a board structure change fails on the actual `item-add` / `item-edit` call with `gh`'s own error; the user then re-runs `--init`.

### Multi-repo scoping

The `github_project` block lives in `.claude/config.json` of the **consuming repo** (e.g. sagibeast), not the makato repo. Each consuming repo's config points to the project board that repo's `to-issues` invocations should sync to. Matches v3.0.0's existing per-repo `.claude/config.json` model.

### Org-owned projects

The `owner_type` field flips the GraphQL surface. `gh project list --owner <login>` works for both user-owned and org-owned projects; `--init` captures `owner_type` from whichever shape `gh project list` returned. No special-casing in normal-run code.

### Why all four `options.*` despite v1 writing only `blocked`

Caching all four costs one extra prompt at init and zero runtime cost. v2 lifecycle work needs the other three; making `--init` discover them now means v2 won't require a re-init. If `--init` cannot resolve all four, it fails — the project doesn't have the four-status convention the skill assumes.

## Data Flow

### `--init` flow (6 steps)

1. **Resolve owner.** `GH_HOST=github.com gh api user --jq .login` → authenticated GitHub username. Stored as a candidate default for the owner prompt.
2. **List candidate projects.** `GH_HOST=github.com gh project list --owner <login> --format json --limit 50` → user-owned projects. Then ask whether to look at an org instead; if yes, prompt for org login and re-run `gh project list --owner <org>`. List numbered options with title + URL.
3. **Pick or create.**
   - **Pick existing** — user supplies the number from the list.
   - **Create new** — `GH_HOST=github.com gh project create --owner <login> --title "<title>"` → returns a fresh project with Todo/In Progress/Done preconfigured by GitHub. User must add `Blocked` option in the GitHub UI before re-running `--init`; the skill cannot add options to the default Status field through `gh project` (v2 API is read-only for option mutations on built-in fields). Init prints the GitHub URL and a clear "add Blocked, re-run `--init`" instruction.
4. **Discover field + options.** `GH_HOST=github.com gh project field-list <number> --owner <login> --format json` → find field where `name == "Status"` and `dataType == "SINGLE_SELECT"`. Resolve four options by name (`Todo`, `In Progress`, `Done`, `Blocked`) to their IDs.
5. **Validate.** All four option IDs must resolve. Missing any → abort with the field name(s) that didn't match. Name-match is case-insensitive but canonical on-board casing is stored.
6. **Write config.** Read existing `.claude/config.json`, deep-merge the `github_project` block (overwriting any existing block — re-running is idempotent), write with 2-space indent. Print confirmation with resolved owner, number, URL, and the four option IDs.

No `--init` work happens implicitly. Normal-run never calls into init logic — if config is missing, normal run aborts with a clear pointer. Every normal invocation is hermetic.

### Normal sync flow (5 steps)

1. **Read config.** Parse `.claude/config.json`, validate `github_project` per the rules above. Abort with actionable message on any failure.
2. **Read input.** Locate the target slug (argv positional, or default to "most recently modified `specs/*/created-issues.json`" — same convention `to-issues` uses). Parse `created-issues.json`, validate against the schema at `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`.
3. **Snapshot board state.** `GH_HOST=github.com gh project item-list <number> --owner <login> --format json --limit <N>` → currently-linked items. Build a Python `dict` keyed by issue URL → `{ projectItemId, currentStatusOptionId }`. This single query is the re-run guard.
4. **For each issue in `created-issues.json` whose URL is NOT in the board snapshot:**
   - `GH_HOST=github.com gh project item-add <number> --owner <login> --url <issue.url> --format json` → returns `{ id: <projectItemId> }`. Item lands on board, Status defaults to `Todo` per project default.
   - If `"status:blocked" in issue.labels`:
     - `GH_HOST=github.com gh project item-edit --id <projectItemId> --project-id <project_node_id> --field-id <status_field_id> --single-select-option-id <options.blocked>` → flips Status to `Blocked`.
   - Else: no second call. Item stays on the project default.
5. **Write audit artifact.** Append-or-create `specs/{slug}/project-sync.json` (schema below), capturing this run. Validate against schema before write.

**Failure handling in step 4:**

- **Per-issue, not per-batch.** If `item-add` fails on issue 7 of 20, log the failure, skip the status-edit for issue 7, continue to issue 8. Artifact records `outcome: "add_failed"` for issue 7 with the error string. Exit code remains 0 if at least one issue synced; nonzero only if every single issue failed.
- The `item-add` → `item-edit` pair is **not atomic**. If `item-add` succeeds but `item-edit` fails, the artifact records `outcome: "added_blocked_edit_failed"` — the item is on the board at Todo instead of Blocked, and a human follow-up moves it. Same "soft-warning, don't halt" philosophy `to-issues` v3.2.0 uses for dangling `blockedBy` references.
- **`DRY_RUN=1`** short-circuits steps 4 and 5: prints the calls that would happen, writes a `project-sync.json` with every entry's `outcome: "dry_run"` and the `cli_command` field populated, exits 0.

## Audit Artifact (`specs/{slug}/project-sync.json`)

Mirrors `created-issues.json`'s flat-list shape. Schema at `references/project-sync.schema.json`.

```json
{
  "schema_version": "1",
  "slug": "<feature-slug>",
  "run_timestamp": "2026-06-24T17:00:00Z",
  "skill_version": "1.0.0",
  "project": {
    "owner": "zstary",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1"
  },
  "summary": {
    "issues_in_input": 12,
    "already_on_board": 3,
    "added": 9,
    "set_blocked": 2,
    "left_default": 7,
    "add_failed": 0,
    "edit_failed": 0,
    "dry_run": 0
  },
  "results": [
    {
      "issue_number": 47,
      "url": "https://github.com/zstary/sagibeast/issues/47",
      "labels": ["type:feat", "tier:foundation", "tech:python", "module:body-api"],
      "outcome": "added_default",
      "project_item_id": "PVTI_lAHOA6Q…",
      "final_status": "Todo",
      "cli_command": null,
      "error": null
    },
    {
      "issue_number": 48,
      "url": "https://github.com/zstary/sagibeast/issues/48",
      "labels": ["type:future-enhancement", "status:blocked", "tech:python"],
      "outcome": "added_blocked",
      "project_item_id": "PVTI_lAHOA6Q…",
      "final_status": "Blocked",
      "cli_command": null,
      "error": null
    }
  ]
}
```

### `outcome` enum

| Value | When | Final board state |
|---|---|---|
| `already_on_board` | URL was in the snapshot from step 3 — skipped entirely | unchanged |
| `added_default` | `item-add` ok; no `status:blocked` label → no edit | `Todo` (project default) |
| `added_blocked` | `item-add` ok; `status:blocked` in labels → `item-edit` ok | `Blocked` |
| `added_blocked_edit_failed` | `item-add` ok; `item-edit` failed | `Todo`, soft-warning logged |
| `add_failed` | `item-add` itself failed | not on board |
| `dry_run` | `DRY_RUN=1` was set | not on board; `cli_command` shows what would run |

### Why the audit artifact exists

- Lets `build-create-pr` or other downstream skills see whether each issue actually made it onto the board without re-querying GraphQL.
- Gives humans a checkable trail when "did this issue land on the board?" comes up days later — `project-sync.json` shows the exact outcome with a project-item ID linking back.
- Lets a v2 reconciler skill diff the cached snapshot against current board state to detect human edits.

## Error Handling

Policy: **soft-warn, log, continue when possible; abort with actionable message when continuation would mask data loss or silently mis-target the wrong board.**

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| `.claude/config.json` missing | Step 1 | **Abort** | Exit 1: `"issue-to-project: .claude/config.json not found. Run 'issue-to-project --init' from the repo root."` |
| `.claude/config.json` invalid JSON | Step 1 | **Abort** | Exit 1, print JSON parse error verbatim with line number. |
| `github_project` block missing | Step 1 | **Abort** | Exit 1: `"issue-to-project: 'github_project' block missing in .claude/config.json. Run 'issue-to-project --init' to set up project board sync."` |
| Required key missing in `github_project` | Step 1 | **Abort** | Exit 1, name the missing key, suggest re-init. |
| ID format failure (e.g. `project_node_id` doesn't start `PVT_`) | Step 1 | **Abort** | Exit 1, name the corrupt key, suggest re-init. |
| `specs/{slug}/created-issues.json` missing | Step 2 | **Abort** | Exit 1: `"issue-to-project: no created-issues.json found at specs/{slug}/. Run 'to-issues {slug}' first."` |
| `created-issues.json` schema-invalid | Step 2 | **Abort** | Exit 1, print schema validator's exact error, point at the field. |
| `gh project item-list` fails (auth, rate limit, network) | Step 3 | **Abort** | Exit 1, print `gh`'s error verbatim. Refuse to sync without the re-run guard — without the snapshot, partial-info sync risks duplicate adds. |
| `gh project item-add` fails for an individual issue | Step 4, per-issue | **Soft-warn** | Log `[issue-to-project:warn] issue #N: item-add failed: <error>`. Record `outcome: "add_failed"`. Continue. |
| `gh project item-edit` fails after a successful `item-add` | Step 4, per-issue | **Soft-warn** | Log `[issue-to-project:warn] issue #N: status edit to 'Blocked' failed after add: <error>. Item is on board at default Status — human follow-up required.` Record `outcome: "added_blocked_edit_failed"`. Continue. |
| Every `item-add` failed (batch-wide) | End of step 4 | **Exit 1** | If `summary.added == 0 && summary.already_on_board < summary.issues_in_input`, the run accomplished nothing — exit nonzero so callers can detect total failure. |
| `project-sync.json` write fails (disk full, perms) | Step 5 | **Exit 1, with warning** | Print: `"issue-to-project: project-sync.json write failed. Board sync DID happen — see GitHub Project board for actual state."` Exit 1 so the caller knows audit artifact is missing. |
| `project-sync.json` fails schema validation on write | Step 5 | **Abort write** | Exit 1, print schema error, don't write the file. This is a bug, not user error — fail loud. |

### Cross-cutting

- **Exit codes** — `0` = success or partial success with ≥1 item synced; `1` = abort or zero items synced; `2` = `--init` user-cancelled. No other codes.
- **Logging** — warnings prefixed `[issue-to-project:warn]`, info prefixed `[issue-to-project:info]`. Mirrors `to-issues`'s `[to-issues:auto]` convention. Output goes to stdout (so `tee` captures it). `gh`'s own stderr surfaces directly.
- **Idempotency contract** — re-running the same command produces the same final board state. Re-running after `add_failed` retries the failed item naturally (it isn't in the next snapshot). Re-running after `added_blocked_edit_failed` does NOT retry the edit (the item IS in the snapshot, so step 4 skips it). Intentional per the Section 1 hard guarantee — we never overwrite a Status, including our own from a prior run. Users who want to retry the edit re-run `--init`, delete the item from the board, re-run sync. Documented as known limitation.

## Testing Strategy

Same testing posture as `to-issues`: **static + dry-run + one live smoke test per major path.**

| Test | What it covers | How |
|---|---|---|
| Frontmatter parse | YAML valid, version is semver, required keys present | `bash scripts/check-skill-frontmatter.sh plugins/makato-plan/skills/issue-to-project` |
| Schema files valid | `project-sync.schema.json` parses as JSON Schema draft-07 | `python3 -c "import json, jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(...)))"` |
| Reference files load | `references/` files exist and aren't empty | grep-based, embedded in SKILL.md verification block |
| `--init` smoke | Init flow against a throwaway project; verify written config | Manual |
| Sync dry-run on synthetic input | Hand-crafted `created-issues.json` with mixed labels; run with `DRY_RUN=1`; verify `project-sync.json` | Manual; documented in SKILL.md |
| Live smoke test | Run actual `to-issues` then `issue-to-project` against a real spec on the sagibeast project; verify board state matches `project-sync.json` | Manual, one-time per release |
| Re-run guard | Run twice in a row; second run records every issue as `already_on_board`; board state unchanged | Manual, part of smoke test |

**Not in v1 testing:**

- No integration test harness with a fake GitHub. Cost exceeds value for a skill running ~weekly per consumer.
- No unit tests for bash/python glue. Same posture as every other makato skill — the skill IS the test artifact.
- No coverage measurement.

## File-by-File Changes

| Status | Path | Responsibility |
|---|---|---|
| **New** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Frontmatter (`name: issue-to-project`, `version: 1.0.0`, hooks), Tools table, Reference Files block, Process steps for both `--init` and normal modes, exit-code contract, examples |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Full 6-step `--init` flow with exact `gh` invocations, prompt phrasing, error messages, config-write template |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Full 5-step normal-run flow with exact `gh` invocations, re-run-guard logic, status-edit decision rule, per-issue outcome routing |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Human-readable doc of the `github_project` block — required keys table, examples for user-owned and org-owned projects, ID-format-validation rules |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | JSON Schema draft-07 for the audit artifact; mirrors `created-issues.schema.json` style |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New top-level section `## \`issue-to-project\` skill` with a `**1.0.0**` block listing v1 scope |
| **Modify** | `plugins/makato-plan/README.md` | Add `issue-to-project` to the Workflow section per AGENTS.md PR checklist; note its position in the pipeline (after `to-issues`) |
| **Keep** | `plugins/makato-plan/skills/to-issues/**` | **No change.** `issue-to-project` is a pure consumer of `to-issues`'s existing `created-issues.json` contract. |
| **Keep** | Root `.claude/config.json` | **No change.** The makato repo doesn't need a `github_project` block for itself. Consumers (sagibeast) add the block to their own repo's config when they run `issue-to-project --init`. |

## Versioning

| Item | Value |
|---|---|
| Skill version | `1.0.0` — first release |
| Plugin version | Not bumped at this layer — `release-please` handles plugin-level versioning from the conventional-commit subject |
| Hard dependency | `to-issues` v3.2.0+ |
| Branch | `feat/issue-to-project-skill` (off `main`) |
| Conventional-commit title | `feat(makato-plan): add issue-to-project skill for GitHub Projects v2 board sync (v1.0.0)` |

## Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Post-`to-issues` batch only; lifecycle (PR-open, PR-merge, blocker-close) deferred to v2 | Smallest skill that delivers "flawlessly follow `to-issues`" literally. Avoids the two-skills-worth-of-design trap we hit on v3.2.0. v2 has its own design cycle. |
| D2 | Config-declared, fully resolved up front via `issue-to-project --init`; cached IDs in `.claude/config.json` | Pays discovery cost once; every other run is offline-readable and fast. Cached IDs are stable artifacts humans can review. Name-based resolution every run would silently mis-route when an option gets renamed. |
| D3 | Sparse writes — add every new issue, set `Blocked` only when `status:blocked` in `labels[]`, leave `Todo` to the project default | Matches `to-issues` v3.2.0's emission contract one-to-one. Minimum API surface (typically 1 call per non-blocked issue, 2 per blocked issue). |
| D4 | Skill lives in `plugins/makato-plan/skills/issue-to-project/`, named `issue-to-project` to mirror `to-issues` | Co-located with `to-issues` because the artifact pipeline is `to-issues` → `issue-to-project`. `makato-plan/AGENTS.md` already covers "create or update Jira epics and stories from shaped output" — project-board sync is the GitHub-Projects analog. v2 lifecycle work can later split or extract as needed. |
| D5 | Skill cache all four Status option IDs even though v1 only writes `Blocked` | One extra prompt at init time, zero runtime cost. Saves users from re-running `--init` when v2 lifecycle work ships. |
| D6 | `status_field_name` stored as data (`"Status"` in v1), not hardcoded | Lets v2 point to a renamed field by editing config, no code change. Ships convention-over-config default while keeping the door open. |
| D7 | Re-run guard via single `gh project item-list` query at run start, cached in memory | Eliminates duplicate adds; respects the "never overwrite human-edited Status" hard guarantee; one GraphQL call serves the whole batch. |
| D8 | Per-issue failure soft-warns, never halts | Matches the v3.2.0 P7 philosophy — partial success is more useful than full halt. Batch-total failure (zero items synced) escalates to exit 1 so callers detect it. |
| D9 | `add` → `edit` pair is non-atomic; failure mode `added_blocked_edit_failed` is logged and the human resolves manually | Atomicity in v2 Projects isn't free (no transaction primitive). The audit artifact makes recovery cheap — humans can grep for the outcome and fix specific items. |
| D10 | `--init` cannot create the `Blocked` option on a fresh GitHub-default project; user creates it in the UI then re-runs `--init` | GitHub's v2 API is read-only for option mutations on the built-in Status field. Documented in `--init` output with the exact URL to click. |
| D11 | Audit artifact emitted as `specs/{slug}/project-sync.json`, mirroring `created-issues.json`'s shape | Downstream skills can consume it without re-querying GraphQL. Humans get a grep-able trail. |

## Out of Scope (explicit anti-decisions)

| ID | Out-of-scope item | Why deferred |
|---|---|---|
| O1 | PR-opened → `In Progress` / PR-merged → `Done` / blocker-closed → `Blocked`→`Todo` lifecycle transitions | Doubles the surface area: needs webhook receiver or polling, PR↔issue linkage rules, idempotency under retries. Own design cycle. |
| O2 | Webhook listeners, polling daemons, GitHub Actions integration | Same as O1 — lifecycle infrastructure belongs to v2. |
| O3 | Bulk reconciliation of pre-existing issues not created by `to-issues` | v1 is a strict `to-issues` consumer; broader reconciliation is its own skill (`reconcile-project-board` or similar). |
| O4 | Cross-repo project sync | sagibeast project receives sagibeast-repo issues only. Multi-repo boards are a multi-tenant problem with multiple right answers. |
| O5 | Milestone, Iteration, Reviewer, or other non-Status field sync | Status field alone covers the goal-state ("flawlessly follow `to-issues`"). Adding more fields without a clear demand grows the schema risk. |
| O6 | Automatic re-init on detected config drift | Re-init is destructive (overwrites cached IDs). Always user-triggered. Better to fail loud on stale IDs than to silently re-resolve and possibly point at a different project. |
| O7 | Project board column ordering, swim-lane management, group-by configuration | Pure UI concerns; the board's structure is the user's, not the skill's. |

## Migration Notes

None for the makato repo. The makato repo is itself not a sagibeast-project consumer; `.claude/config.json` in this repo stays at `{"project": "sagibeast"}` with no `github_project` block.

For sagibeast (the primary consumer): once this skill lands, run `issue-to-project --init` from the sagibeast repo root once. This writes the `github_project` block into sagibeast's `.claude/config.json`. Subsequent `to-issues` runs in sagibeast will be followed by `issue-to-project` runs that sync the new issues to the project board.

For other future consumers: same flow. `--init` is a per-repo one-time setup.

## References

- `to-issues` v3.2.0 spec — `docs/superpowers/specs/2026-06-24-slice-patterns-and-status-labels-design.md` (commit `6ef87e6`)
- `to-issues` v3.2.0 schema — `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` (input contract for this skill)
- `to-issues` v3.2.0 label taxonomy — `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` (defines `status:blocked` semantics)
- GitHub Projects v2 GraphQL reference — `gh project --help` and `gh api graphql` (the underlying surface this skill calls)
- GitHub Project for sagibeast — `https://github.com/users/zstary/projects/1` (the v1 reference target)
- `makato-plan` AGENTS.md — `plugins/makato-plan/AGENTS.md` (skill-authoring contract)
- PR #14 — `https://github.com/zstary/makato/pull/14` (the v3.2.0 PR this skill follows)
