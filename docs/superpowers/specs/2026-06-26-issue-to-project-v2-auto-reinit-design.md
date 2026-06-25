<!-- markdownlint-disable MD013 -->
# Spec: Auto Re-init on Stale-Config Drift, v2.5.0

> **Status:** Design. Targets `issue-to-project` v2.5.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

When the v1 stale-config heuristic fires (two consecutive `item-add` failures whose error contains `PVT_` / `not found` / `was deleted`), v2.5 **attempts to re-discover the same project automatically and rewrite the cache in-place**, rather than immediately halting with `STALE_CONFIG` and requiring the operator to manually re-run `--init`. The result is a fully unattended recovery path for the most common cause of stale configs: project archived-then-recreated at the same number on the same owner. Ambiguous cases still halt loudly. Manual `--init` remains the authoritative path; auto-re-init is a convenience wrapper around it, not a replacement.

## Non-Goals

- Auto-create a new board if the cached board is gone. Out of scope — explicit human intent required.
- Multi-board failover or cross-repo project sync.
- Recovery from owner changes (user → org or vice versa). This signals intentional structural change; halt and require manual re-init.
- Recovery from `status_field_name` or Status option-set changes. Treat as ambiguous; halt.
- Backing up the previous `github_project` block to a side-file (marginal value).
- `--retry-blocked-edits` mode (tracked separately, O8 in v1).
- Lifecycle transitions (PR-open → In Progress, etc.) — already deferred to a different v2 track.

## Architecture

### High-level

Auto-re-init is a **new internal sub-path** inserted between the stale-config detection point in step 4 and the existing `STALE_CONFIG` halt. It shares the v1 code paths for project listing (`gh project list`) and field/option discovery (`gh project field-list`) with the interactive `--init` wizard, but the matching logic is strict and non-interactive.

```
Normal sync — step 4 (item-add loop)
  │
  └─ 2 consecutive failures matching stale-id pattern?
        │
        ├─ --no-auto-reinit flag? ──► HALT STALE_CONFIG (v1 behavior)
        │
        └─ auto-reinit enabled (default OFF in v2.5, ON in v2.6)?
              │
              ├─ Title migration needed?  →  read title, update config (idempotent)
              │
              ├─ gh project list --owner <owner>
              │     find entry where number == cached_number
              │     AND title == cached_title (case-insensitive)
              │
              ├─ Ambiguous? (title mismatch / owner mismatch / 0 or 2+ matches)
              │     └─► HALT AMBIGUOUS_REINIT
              │
              ├─ gh project field-list  →  validate Status field + options unchanged
              │     mismatch? ──► HALT AMBIGUOUS_REINIT
              │
              ├─ new project_node_id  ≡  old project_node_id?
              │     → already fixed; log and continue (idempotency guard)
              │
              ├─ write updated github_project block to .claude/config.json
              │     → append reinit_* audit keys; preserve init_* keys unchanged
              │
              └─ resume item-add loop with new IDs
                    │
                    └─ new IDs also stale? ──► HALT STALE_CONFIG_PERSISTENT (no loop)
```

No subagent fan-out. No interactive prompts. The entire auto-re-init sub-path is `gh` + `python3` glue, same as v1.

### Why this approach (alternatives considered)

**Inline recovery vs separate `--auto-reinit` command.** Inline recovery (this spec) delivers the "unattended" posture — operators running `to-issues → issue-to-project` in a script get recovery without changing their invocation. A separate command would require the operator to detect the stale condition and re-invoke, which adds friction and breaks automation.

**Eager validation on every run vs lazy trigger.** Running `gh project view` on every normal run to check ID validity contradicts D2/D13 from v1 (no-live-probe rule, cache defeats purpose). The lazy trigger on 2 consecutive failures is already in v1; v2.5 intercepts exactly that signal.

**Default ON vs default OFF in v2.5.** Default OFF in v2.5 and default ON in v2.6 after burn-in is preferred (see D6). The v1 behavior (`STALE_CONFIG` halt) remains the out-of-the-box experience in v2.5, so existing operators see no behavior change unless they opt in.

## Data Flow

```
Input:  .claude/config.json → github_project block (cached IDs + new title field)
        specs/{slug}/created-issues.json

Trigger: 2 consecutive item-add failures matching stale-id pattern in step 4

Auto-reinit sub-path:
  1. Read github_project.{owner, owner_type, number, title}
  2. gh project list --owner <owner> --format json --limit 50
     → filter: entry.number == cached.number AND entry.title ~= cached.title
  3. gh project field-list <number> --owner <owner> --format json
     → validate: Status field exists, same type, same 4 option names (case-insensitive)
  4. Extract new project_node_id, status_field_id, options.*
  5. Write updated github_project block (additive: reinit_* keys appended, init_* preserved)
  6. Append entry to auto_reinit_log in project-sync.json (written in step 5 of normal sync)
  7. Resume item-add loop from the first-failed issue with new IDs

Output: updated .claude/config.json
        specs/{slug}/project-sync.json (new auto_reinit_log key; recovered rows get outcome tag)
```

## Config Schema (diff vs v1)

### New required field: `title`

v1 does not cache the project title. v2.5 adds it as a required cache field for disambiguation.

```json
{
  "github_project": {
    "owner": "zstary",
    "owner_type": "user",
    "number": 1,
    "title": "sagibeast",
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
    "init_skill_version": "1.0.0",
    "reinit_timestamp": "2026-06-26T09:15:00Z",
    "reinit_skill_version": "2.5.0",
    "reinit_reason": "stale_project_node_id: PVT_old rejected by item-add"
  }
}
```

### New config keys

| Key | Required | Added by | Purpose |
|---|---|---|---|
| `title` | **yes (v2.5+)** | `--init` (new) or one-time migration on first v2.5 run | Disambiguation anchor for auto-re-init matching |
| `reinit_timestamp` | no (present only after auto-re-init fires) | auto-re-init sub-path | Audit trail: when last auto-re-init ran |
| `reinit_skill_version` | no | auto-re-init sub-path | Skill version that performed the re-init |
| `reinit_reason` | no | auto-re-init sub-path | Human-readable trigger description |

**Rule: `init_*` keys are immutable after `--init`.** Auto-re-init writes only `reinit_*` keys and updates `project_node_id`, `status_field_id`, `options.*`, `url`. `init_timestamp` and `init_skill_version` are never overwritten — they record the first-ever human-triggered setup.

### One-time title migration

On the first v2.5 run against a v1-format config (config present, `title` key absent):

1. Run `GH_HOST=github.com gh project view <number> --owner <owner> --format json` → extract `title`.
2. Write `title` into the `github_project` block. Update `init_skill_version` to `"2.5.0"`.
3. Log `[issue-to-project] INFO: migrated v1 config — cached title "<title>" for project #<number>`.

Migration is idempotent: if `title` is already present, skip silently. Migration failure (e.g. `gh project view` times out) does not abort the run; it logs a warning and continues without the title key. Auto-re-init will be unavailable on this run only — if stale detection fires, it halts with `STALE_CONFIG` and notes `"auto-reinit skipped: title not cached; run --init to upgrade config"`.

### Validation rules (additive to v1)

5. **`title` required in v2.5 for auto-re-init.** If absent and migration fails, auto-re-init path is skipped; `STALE_CONFIG` halt fires as in v1. Normal sync continues unaffected.
6. **`reinit_*` keys are optional** and not validated on normal-run config read (they are for audit, not runtime).

## Audit Artifact (diff vs v1)

### New top-level key: `auto_reinit_log`

Present only when auto-re-init fired during this run. Callers can detect recovery by checking `auto_reinit_log != null`.

```json
{
  "schema_version": "2",
  "slug": "my-feature",
  "run_timestamp": "2026-06-26T09:15:00Z",
  "skill_version": "2.5.0",
  "project": { "owner": "zstary", "number": 1, "url": "..." },
  "auto_reinit_log": [
    {
      "timestamp": "2026-06-26T09:15:00Z",
      "old_project_node_id": "PVT_old",
      "new_project_node_id": "PVT_new",
      "trigger_reason": "item-add failure: project not found (PVT_old)"
    }
  ],
  "summary": { "...": "same as v1 plus recovered: 2" },
  "results": [ "..." ]
}
```

`auto_reinit_log` is an array (not a scalar) to handle the theoretical case where a future schema version might log multiple phases; in v2.5 it contains at most one entry per run.

### New per-row outcome value

| Value | When | Final board state |
|---|---|---|
| `recovered_via_auto_reinit` | Issue was in the failed-before-reinit batch; re-attempted after new IDs resolved; `item-add` succeeded | `Todo` or `Blocked` per label routing |

The per-row `outcome` for issues that succeed after auto-re-init is `recovered_via_auto_reinit` (not `added_default` or `added_blocked`). This lets downstream consumers distinguish organic adds from recovered adds.

Issues whose `item-add` fails even after the new IDs are used get `add_failed` (unchanged).

### `schema_version` bump

v1 artifact `schema_version` is `"1"`. v2.5 bumps to `"2"` to signal the new `auto_reinit_log` key. Consumers can distinguish v1 and v2 artifacts by this field. Old consumers that don't read `auto_reinit_log` continue to work correctly (additive key).

## Argv & Flag Contract

All v1 flags are unchanged. New flag:

| Flag | Default in v2.5 | Default in v2.6 | Effect |
|---|---|---|---|
| `--no-auto-reinit` | OFF (auto-reinit defaults OFF; flag is a no-op) | Meaningful (auto-reinit defaults ON; flag reverts to v1 STALE_CONFIG halt) | Disable auto-re-init; emit STALE_CONFIG instead |
| `--auto-reinit` | Opt-in for v2.5 burn-in | Removed or deprecated | Enable auto-reinit in v2.5 before default flips |

In v2.5, operators must explicitly pass `--auto-reinit` to activate the feature. `--no-auto-reinit` is parsed but is a no-op (logs `[issue-to-project] INFO: --no-auto-reinit has no effect in v2.5; auto-reinit defaults OFF`). In v2.6, the default flips: `--auto-reinit` is the default and `--no-auto-reinit` suppresses it.

`DRY_RUN=1` interaction: auto-re-init reads (`gh project list`, `gh project field-list`) run in dry-run mode; the config write is suppressed. The artifact records `auto_reinit_log` with `new_project_node_id: "dry_run_not_written"`.

## Error Handling

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| `gh project list` returns 0 entries for `number == cached.number` | Auto-re-init step 2 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit could not find project #<n> under owner <owner>. Project may have been deleted or transferred. Re-run 'issue-to-project --init'."` |
| `gh project list` returns entry where `title != cached.title` (case-insensitive) | Auto-re-init step 2 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit found project #<n> but title mismatch (cached: '<old>', found: '<new>'). Re-run 'issue-to-project --init' to confirm the correct project."` |
| `gh project list` returns 2+ entries with same number (should not happen; API invariant) | Auto-re-init step 2 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit found multiple projects at #<n>. Re-run 'issue-to-project --init'."` |
| Owner type changed (user project vs org project at the same number) | Auto-re-init step 2 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit detected owner-type change for project #<n>. Re-run 'issue-to-project --init'."` |
| Status field missing or renamed in `gh project field-list` | Auto-re-init step 3 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit found project #<n> but Status field structure has changed (field '<name>' not found or renamed). Re-run 'issue-to-project --init'."` |
| Status option set changed (option added/removed/renamed) | Auto-re-init step 3 | **Abort** | HALT `AMBIGUOUS_REINIT`: `"issue-to-project: auto-reinit found project #<n> but Status options changed (expected: Todo/In Progress/Done/Blocked). Re-run 'issue-to-project --init'."` |
| Auto-re-init succeeds but new IDs are ALSO stale | After resuming item-add loop | **Abort** | HALT `STALE_CONFIG_PERSISTENT`: `"issue-to-project: auto-reinit updated project IDs but new IDs are also stale. Re-run 'issue-to-project --init' to manually resolve."` No retry loop. |
| Config write fails after auto-re-init resolved new IDs | Auto-re-init step 5 | **Abort** | HALT `INIT_FAILED`: `"issue-to-project: auto-reinit resolved new IDs but could not write .claude/config.json (<errno>). Re-run 'issue-to-project --init'."` |
| `gh project view` times out during title migration | Migration step | **Soft-warn** | Log `[issue-to-project] WARN: title migration failed (timeout) — auto-reinit unavailable this run`. Continue normal sync. |
| `--no-auto-reinit` passed + stale detected | Step 4 | **Abort** | HALT `STALE_CONFIG` (v1 behavior unchanged): `"issue-to-project: cached project_node_id appears stale. Re-run 'issue-to-project --init'."` |

## Cross-cutting

### Exit codes

Unchanged from v1. `AMBIGUOUS_REINIT` and `STALE_CONFIG_PERSISTENT` exit `1`.

### HALT codes (new + inherited)

All v1 HALT codes are immutable. New codes added in v2.5:

| HALT code | Meaning | Exit | New in |
|---|---|---|---|
| `PREFLIGHT_FAILED` | (inherited) | 1 | v1 |
| `MISSING_CONFIG` | (inherited) | 1 | v1 |
| `MALFORMED_CONFIG` | (inherited) | 1 | v1 |
| `MISSING_INPUT` | (inherited) | 1 | v1 |
| `MALFORMED_INPUT` | (inherited) | 1 | v1 |
| `EMPTY_INPUT` | (inherited) | 1 | v1 |
| `AMBIGUOUS_SLUG` | (inherited) | 1 | v1 |
| `SNAPSHOT_FAILED` | (inherited) | 1 | v1 |
| `STALE_CONFIG` | (inherited) cached IDs stale and auto-reinit disabled/skipped | 1 | v1 |
| `TOTAL_SYNC_FAILED` | (inherited) | 1 | v1 |
| `AUDIT_WRITE_FAILED` | (inherited) | 1 | v1 |
| `AUDIT_SCHEMA_FAILED` | (inherited) | 1 | v1 |
| `INIT_FAILED` | (inherited, extended) includes auto-reinit config-write failure | 1 | v1 |
| `USER_CANCELLED` | (inherited) | 2 | v1 |
| **`AMBIGUOUS_REINIT`** | Auto-re-init could not safely identify the same project (title mismatch, owner-type change, field structure drift, zero or multiple matches) | 1 | **v2.5** |
| **`STALE_CONFIG_PERSISTENT`** | Auto-re-init succeeded but new IDs are also stale; loop guard fired | 1 | **v2.5** |

### Logging

Log prefix rules from v1 are unchanged. Auto-re-init progress uses the existing `[issue-to-project]` prefix (it is not an autonomous inference decision; `[issue-to-project:auto]` remains reserved for future inference-path decisions):

```
[issue-to-project] INFO: stale-config trigger fired after 2 consecutive item-add failures
[issue-to-project] INFO: auto-reinit: searching for project #1 under owner zstary
[issue-to-project] INFO: auto-reinit: matched project #1 "sagibeast" — new node_id PVT_new
[issue-to-project] INFO: auto-reinit: Status field and options unchanged — proceeding
[issue-to-project] INFO: auto-reinit: config updated; resuming item-add from issue #47
```

On `AMBIGUOUS_REINIT`, log the mismatch detail at WARN level before the HALT line.

### Idempotency contract

Re-running after a successful auto-re-init is fully idempotent: the updated config has the new IDs; the re-run guard snapshots the board; issues added in the auto-reinit run are already on the board. The `recovered_via_auto_reinit` outcome is not emitted on the second run — those items appear as `already_on_board`.

Re-running when `AMBIGUOUS_REINIT` fired leaves the config unchanged. The operator must run `--init` manually, which is interactive and therefore always safe.

## Return Format (R1)

The R1 sentinel second-to-last line is extended additively. All v1 keys are preserved unchanged. New optional key `auto_reinit` present only when auto-re-init fired:

```
RESULT: {"status":"ok","slug":"my-feature","artifact_path":"specs/my-feature/project-sync.json","issues_in_input":12,"already_on_board":3,"added":7,"set_blocked":2,"left_default":5,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"auto_reinit":{"fired":true,"old_node_id":"PVT_old","new_node_id":"PVT_new","recovered":2}}
```

When auto-re-init did not fire, `auto_reinit` is absent (not `null`) to keep the sentinel compact for callers that don't need it. Callers testing for recovery use `"auto_reinit" in result`.

`status` can be `"ok"`, `"partial"`, or `"failed"` (unchanged). A run that auto-reinited and then succeeded fully is `"ok"`.

## Decisions

**D1 — Default OFF in v2.5, default ON in v2.6.**
Auto-re-init rewrites `.claude/config.json` without a human prompt. Shipping it opt-in in v2.5 gives a burn-in window to validate the matching algorithm on real consumer repos before making it the default. v1 consumers see no behavior change on upgrade. Alternatives rejected: (a) default ON from day one — too aggressive for a destructive-of-cache operation; (b) never default ON, always explicit flag — adds friction for operators who just want robust unattended sync. Implications: operators who want recovery in v2.5 must pass `--auto-reinit`; v2.6 spec must document the flag-semantics inversion.

**D2 — Match by (number + title + owner), abort on any mismatch.**
Number alone is insufficient: a project can be archived and a new project created at the same number. Title is the human-intent anchor. Owner is cached and must match exactly (owner changes are structural, not recoverable automatically). Alternatives rejected: (a) match by number only — risks silently pointing at the wrong board if a new project reuses the number; (b) match by title substring — too loose, two projects can share a keyword. Implications: a project rename between runs triggers `AMBIGUOUS_REINIT`; operator must run `--init`. This is intentional — a rename may signal a board reorganization.

**D3 — Preserve `init_*` keys; write only `reinit_*` and update mutable IDs.**
The original `--init` timestamp and skill version are the provenance record for when a human last deliberately configured the board. Overwriting them would lose that audit trail. Alternatives rejected: (a) overwrite `init_*` with auto-re-init values — loses the human-intent provenance; (b) archive old block to a side-file — marginal value, added I/O complexity. Implications: config format now has two timestamp/version pairs; documentation must explain both clearly.

**D4 — Validate Status field name and all four option names (case-insensitive) before writing new IDs.**
If the board operator renamed `Blocked` to `Backlogged` between runs, writing the new `project_node_id` but keeping stale option IDs would cause silent routing failures. Aborting on option-set drift is safer. Alternatives rejected: (a) validate only `project_node_id` format — insufficient; IDs can change while names stay stable; (b) skip field validation, let item-edit fail later — reverts to the per-issue soft-warn failure mode that auto-re-init is trying to avoid. Implications: any Status option rename triggers `AMBIGUOUS_REINIT`. Operators should run `--init` after intentional board restructuring.

**D5 — One attempt; halt `STALE_CONFIG_PERSISTENT` if new IDs are also stale.**
Looping auto-re-init is dangerous: a corrupted state could cause infinite retries. One attempt bounds the worst case. Alternatives rejected: (a) two attempts — doubles the `gh project list` calls with near-zero additional value; (b) no loop guard — risks spinning on a pathological board state. Implications: `STALE_CONFIG_PERSISTENT` is a signal that something is genuinely wrong beyond a simple archive-recreate cycle; manual intervention is always the right next step.

**D6 — `auto_reinit_log` is an array in the artifact, not a scalar.**
Future schema versions may need to log multiple re-init events (e.g., if the feature is extended to handle field-ID refreshes separately from project-node-ID refreshes). Array at v2.5 costs nothing and avoids a breaking schema change later. Alternatives rejected: scalar object — would require a schema bump to extend. Implications: consumers reading `auto_reinit_log[0]` must guard against empty array (never fires → key absent; fires → one-element array in v2.5).

**D7 — `recovered_via_auto_reinit` is a distinct `outcome` value, not `added_default` / `added_blocked`.**
Downstream consumers (e.g., a CI script checking the artifact) may want to distinguish organic adds from recovery adds to decide whether to alert. Sharing the same outcome name would obscure this. Alternatives rejected: (a) reuse `added_default` / `added_blocked` with a separate boolean flag — more fields, same signal; (b) emit `auto_reinit: true` at the run level only — loses per-row granularity if some issues fail after re-init. Implications: `project-sync.schema.json` must add `recovered_via_auto_reinit` to the outcome enum; v1-schema consumers will see an unexpected enum value and must be updated.

**D8 — Title migration is a silent one-time read, never an abort.**
Forcing operators to re-run `--init` just to get the title cached would create an unnecessary friction barrier on first v2.5 upgrade. A silent `gh project view` call is cheap and already within the skill's read-only permission set. Alternatives rejected: (a) abort with a migration prompt — unnecessary disruption for a one-key addition; (b) defer title caching to the first `--init` re-run — means auto-reinit is unavailable until then, defeating the upgrade experience. Implications: `gh project view` adds one network call on the first v2.5 run; timeout degrades gracefully to "auto-reinit unavailable this run only".

**D9 — Auto-re-init runs `gh project list` (not `gh project view` by node-ID).**
`gh project view` by node-ID would fail if the node-ID is stale, which is exactly the condition we're recovering from. `gh project list` by number+owner is a lookup that succeeds even if the old node-ID is invalid. Alternatives rejected: (a) `gh project view --id <number>` — relies on number-based lookup which v1 already uses elsewhere and is fine; actually this is feasible. However, `gh project list` provides the title for disambiguation in one call, while `gh project view` would require a separate call. Single-call approach wins on simplicity. Implications: `gh project list` returns up to 50 entries by default; if the owner has many projects, the number may not appear in the first page. Use `PROJECT_LIST_LIMIT` env var (v1 already defines this) to widen the search before aborting.

**D10 — `DRY_RUN=1` suppresses the config write but still runs the discovery reads.**
Operators testing auto-re-init behavior before enabling it in production need to see what would change without risking the config. All `gh project list` / `gh project field-list` calls run normally; the config write and artifact `auto_reinit_log` record `new_project_node_id: "dry_run_not_written"`. Alternatives rejected: (a) skip discovery entirely in dry-run — provides no signal about whether re-init would succeed; (b) write config in dry-run — defeats the purpose. Implications: dry-run + `--auto-reinit` is a safe way to audit the recovery path on a live repo without committing changes.

## Out of Scope

| ID | Out-of-scope item | Why deferred |
|---|---|---|
| O1–O9 | All v1 out-of-scope items | Unchanged; see v1 spec |
| O10 | Auto-create a new board if the cached board is gone entirely | Requires explicit human intent to name and configure a new project. Auto-creation without a prompt risks silently targeting the wrong org/user slot. |
| O11 | Multi-board failover | Adds state machine complexity (ordered fallback list, per-board health tracking). Own design cycle. |
| O12 | Backup the previous `github_project` block to a side-file | Marginal value — `git history` of `.claude/config.json` already provides this. Side-file adds I/O surface and requires cleanup. |
| O13 | Auto-reinit for owner-type changes (user → org) | Owner changes imply deliberate structural change; cannot safely disambiguate without a human in the loop. |
| O14 | `--retry-blocked-edits` leveraging auto-reinit | Tracked separately as O8 from v1. Auto-re-init and blocked-edit retry are orthogonal recovery paths. |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Modify** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version: "2.5.0"`. Add `--auto-reinit` / `--no-auto-reinit` to Argv section. Add `AMBIGUOUS_REINIT` and `STALE_CONFIG_PERSISTENT` to HALT codes table. Add `[issue-to-project:auto]` usage note. Update NEVER block: add `NEVER loop auto-reinit more than once per run`. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Add step 4a: auto-re-init sub-path (triggered between stale detection and HALT). Document the title migration logic. Document loop-guard (`STALE_CONFIG_PERSISTENT`). Document `DRY_RUN=1` interaction. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Add `title` to required fields table. Add `reinit_*` keys to optional keys table. Add migration note for v1 → v2.5. Update example JSON block to include `title` and `reinit_*` fields. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | Bump `schema_version` to `"2"`. Add `auto_reinit_log` array (optional, nullable). Add `recovered_via_auto_reinit` to `outcome` enum. Add `recovered` to `summary` object (optional integer). |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | Add `**2.5.0**` block under `## issue-to-project skill` section with: auto-reinit sub-path, new HALT codes, title migration, artifact schema v2. |

## Testing Strategy

Same posture as v1: static + dry-run + manual smoke.

| Test | What it covers | How |
|---|---|---|
| Frontmatter parse | version bumped to 2.5.0, required keys present | `bash scripts/check-skill-frontmatter.sh` |
| Schema files valid | updated `project-sync.schema.json` parses as JSON Schema draft-07 | `python3 -c "import json, jsonschema; jsonschema.Draft7Validator.check_schema(...)"` |
| Matching algorithm — happy path | cached (number=1, title="sagibeast") matches live project list entry; new IDs written | Manual with `DRY_RUN=1 --auto-reinit` against sagibeast project |
| Matching algorithm — title mismatch | cached title "sagibeast", found "sagibeast-archive"; expect HALT `AMBIGUOUS_REINIT` | Manual with synthetic config |
| Matching algorithm — number not found | project #99 not in list; expect HALT `AMBIGUOUS_REINIT` | Manual with synthetic config |
| Field drift detection | Status option "Blocked" renamed; expect HALT `AMBIGUOUS_REINIT` | Manual with `gh project field-list` output patched |
| Loop guard | new IDs also stale (force by using a synthetic stale node-ID after re-init); expect HALT `STALE_CONFIG_PERSISTENT` | Manual with synthetic config |
| Title migration | v1-format config (no `title`); expect silent title write and normal sync | Manual against sagibeast project on first v2.5 run |
| `--no-auto-reinit` in v2.5 | stale trigger fires with flag; expect HALT `STALE_CONFIG` (v1 behavior) | Manual |
| DRY_RUN + auto-reinit | config write suppressed; artifact records `"dry_run_not_written"` | Manual with `DRY_RUN=1 --auto-reinit` |
| Artifact schema v2 | `schema_version: "2"`, `auto_reinit_log` present when re-init fires | Validated in dry-run smoke |

## Migration Notes

**For existing consumers on v1.0.0:**

1. v2.5 is backward-compatible. On the first v2.5 run, the skill reads the existing v1 config, silently adds `title`, and updates `init_skill_version` to `"2.5.0"`. No manual action required.
2. Auto-re-init is **off by default** in v2.5. Operators who want early access pass `--auto-reinit`. No breaking change to unattended pipelines.
3. Operators running `--init` fresh on a new repo get `title` in the config automatically (the `--init` wizard is updated to capture and cache the project title).
4. v2.6 will flip the default: `--auto-reinit` becomes implicit. Operators wanting the v1 `STALE_CONFIG` halt behavior must add `--no-auto-reinit` to their invocation before upgrading to v2.6.

**For the sagibeast reference project:**
Run `issue-to-project` once after upgrading to v2.5. The title migration fires silently. Inspect `.claude/config.json` to confirm `title` was written. No `--init` re-run required unless you want to test the interactive path.
