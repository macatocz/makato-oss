<!-- markdownlint-disable MD013 -->
# Spec: Cross-Repo Project Sync, v2.3.0

> **Status:** Design. Targets `issue-to-project` v2.3.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Enable one GitHub Projects v2 board to be fed by issues from N source repositories (org-wide roadmap pattern), while closing three concrete gaps that make the v1 per-repo model fragile at board scope:

1. **Audit fragmentation** — each repo emits its own `specs/<slug>/project-sync.json`; no single view of the board across all contributors exists. Ship a `--board-audit` helper that re-derives a board-wide snapshot on demand.
2. **Reconcile collision** — when O3 reconciliation lands, `reconcile` from repo A sees repo B's items as orphans and would spuriously flag or remove them. Introduce a `known_repos` allowlist so reconcile can skip foreign items safely.
3. **Config drift** — operators across N repos can independently mistype the same `status_field_id`. Add a cheap verify-on-first-call probe (Pre-flight check 5) that confirms cached board IDs are still valid before any mutations run.

Nothing in v1's sync logic changes. This spec is purely additive.

## Non-Goals

- Cross-org boards (multiple GitHub orgs feeding one board). All N repos must share the same org or be under the same owner login.
- Per-repo Status routing overrides. One board has one Status field shared by all items; routing rules are board-wide.
- Automatic migration of pre-existing board items not created by `to-issues` (covered by O3 reconciliation spec).
- Webhook-driven or poll-driven sync (O1/O2).
- Lifecycle transitions (`In Progress`, `Done`) — remain O1.

## Architecture

### High-level

```
repo-A/.claude/config.json          repo-B/.claude/config.json
  github_project:                     github_project:
    owner: zstary                       owner: zstary
    number: 1                           number: 1
    known_repos:                        known_repos:
      - zstary/repo-a                     - zstary/repo-a
      - zstary/repo-b                     - zstary/repo-b
    reconcile_scope: all-known-repos    reconcile_scope: all-known-repos
         │                                       │
         └──────────────┬────────────────────────┘
                        │
              ┌─────────▼──────────────┐
              │  GitHub Projects v2    │
              │  Board  (owner: zstary,│
              │  number: 1)            │
              │  items from repo-A ✔   │
              │  items from repo-B ✔   │
              └────────────────────────┘
                        │
              ┌─────────▼──────────────────────────────┐
              │  issue-to-project --board-audit         │
              │  re-derives board-wide snapshot via     │
              │  gh project item-list; groups by repo;  │
              │  writes board-audit.json (no mutations) │
              └─────────────────────────────────────────┘
```

Each repo continues to run `issue-to-project` independently. The board-audit helper is stateless and read-only; it can be run from any repo that has the `github_project` block pointing at the shared board.

### Why this approach (alternatives considered)

**Alternative A — per-repo audit, status quo, add nothing.**
Rejected: reconcile can't distinguish foreign items from orphans without `known_repos`. Two consecutive reconcile runs from different repos would fight each other.

**Alternative B — aggregate audit in a meta/governance repo.**
Rejected: introduces a third repo that all operators must know about; adds a write dependency that isn't scoped to any single feature. Harder to bootstrap for single-owner setups like `zstary/sagibeast`.

**Alternative C — re-derive board-wide state on demand from `gh project item-list`.**
Chosen (D1). The board is the authoritative source; no duplication. `--board-audit` is a cheap read-only call. No shared write surface between repos.

**Alternative D — symlink one central config, repos point at it.**
Rejected (D2). Too much indirection; breaks v1's ergonomics where each repo is self-contained. Cross-repo edits require filesystem access to the symlink target, which is not always available in agent workflows.

## Data Flow

```
Normal sync run (unchanged from v1):

  specs/{slug}/created-issues.json
      │
      ▼
  [Pre-flight checks 1–5]  ← NEW: check 5 = verify-on-first-call
      │
      ▼
  Step 1: read + validate github_project (+ known_repos, reconcile_scope)
      │
      ▼
  Step 2: read created-issues.json
      │
      ▼
  Step 3: gh project item-list → snapshot (unchanged)
      │
      ▼
  Step 4: add + status-edit per issue (unchanged)
      │
      ▼
  Step 5: write specs/{slug}/project-sync.json (schema_version bumped to "2")

Board-audit run (new):

  github_project config (owner, number)
      │
      ▼
  gh project item-list --limit 9999
      │
      ▼
  group items by item['content']['repository']['nameWithOwner']
      │
      ├── known repos  → summarize per-repo counts
      └── unknown repos → flag if reconcile_scope == all-known-repos
      │
      ▼
  write board-audit.json (read-only; no mutations)
```

## Config Schema (diff vs v1)

Two new optional keys inside the existing `github_project` block. All v1 keys remain unchanged and required.

```json
{
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
    "init_skill_version": "1.0.0",

    "known_repos": ["zstary/repo-a", "zstary/repo-b"],
    "reconcile_scope": "all-known-repos"
  }
}
```

### New fields

| Field | Required | Default | Values | Purpose |
|---|---|---|---|---|
| `known_repos` | no | `[]` | Array of `"owner/repo"` strings | Allowlist of repos whose items are expected on this board. Empty list = no reconcile-scope filtering (behaves like v1). |
| `reconcile_scope` | no | `"this-repo-only"` | `"this-repo-only"` \| `"all-known-repos"` | Controls whether reconcile (O3) treats foreign-repo items as orphans. `"this-repo-only"` = v1 behaviour. `"all-known-repos"` = items from any `known_repos` entry are not flagged as orphans. |

### Validation rules (additive)

5. **`known_repos` format.** Each entry must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. Invalid entry → abort with `MALFORMED_CONFIG`, name the offending entry.
6. **`reconcile_scope` enum.** Value must be `"this-repo-only"` or `"all-known-repos"`. Anything else → abort with `MALFORMED_CONFIG`.
7. **Cross-field consistency.** If `reconcile_scope == "all-known-repos"` and `known_repos` is empty or absent, emit `[issue-to-project] WARN: reconcile_scope is 'all-known-repos' but known_repos is empty — all foreign items will be treated as orphans. Add known_repos entries or switch to 'this-repo-only'.` Continue (soft-warn; this is a misconfiguration that harms reconcile, not sync).

## Audit Artifact (diff vs v1)

### Per-repo artifact (`specs/{slug}/project-sync.json`) — schema_version `"2"`

Two additive keys in the top-level object. All v1 keys unchanged.

```json
{
  "schema_version": "2",
  "slug": "my-feature",
  "run_timestamp": "2026-06-26T10:00:00Z",
  "skill_version": "2.3.0",
  "project": {
    "owner": "zstary",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1"
  },
  "cross_repo": {
    "known_repos": ["zstary/repo-a", "zstary/repo-b"],
    "reconcile_scope": "all-known-repos",
    "verify_on_first_call": {
      "ran": true,
      "passed": true,
      "cached_project_node_id_valid": true,
      "cached_status_field_id_valid": true
    }
  },
  "summary": { },
  "results": [ ]
}
```

The `cross_repo` block is omitted (null) when `known_repos` is absent from config — so v1 consumers reading a v2 artifact see no unexpected keys if the feature isn't used.

### Board-wide audit artifact (`board-audit.json`)

Written to the repo root (same directory as `.claude/config.json`) by `--board-audit`. Read-only derivation from the live board; no mutations.

```json
{
  "schema_version": "1",
  "generated_at": "2026-06-26T10:05:00Z",
  "skill_version": "2.3.0",
  "project": {
    "owner": "zstary",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1",
    "total_items": 47
  },
  "known_repos": ["zstary/repo-a", "zstary/repo-b"],
  "by_repo": {
    "zstary/repo-a": { "count": 30, "blocked": 4, "todo": 22, "in_progress": 3, "done": 1 },
    "zstary/repo-b": { "count": 15, "blocked": 1, "todo": 12, "in_progress": 1, "done": 1 }
  },
  "unknown_repos": {
    "zstary/repo-c": { "count": 2 }
  },
  "draft_items_skipped": 3
}
```

`unknown_repos` is populated only when board items carry a `repository.nameWithOwner` value not in `known_repos`. Its presence is informational; no HALT is emitted from `--board-audit` alone (see HALT `UNKNOWN_REPO` which applies to reconcile path only).

## Argv & flag contract

Additive to v1. All v1 flags unchanged.

- `issue-to-project --board-audit` — read-only board-wide snapshot. Mutually exclusive with `--init` and positional slug. Exits `0` on success; `1` on HALT.
- `--board-audit` with `DRY_RUN=1` — no-op (audit is already read-only; `DRY_RUN` has no effect on `--board-audit` but is accepted silently).
- `--init` now discovers `known_repos` automatically from existing board items (see §"Init-wizard adaptation") and prompts for confirmation before writing.

New env vars:
- `ITP_UNKNOWN_REPO_BEHAVIOR` — `"warn"` (default) or `"error"`. Controls whether `UNKNOWN_REPO` is a soft-warn or a hard abort during `all-known-repos` reconcile. Does not affect `--board-audit`.

## Error Handling

All v1 error handling rows unchanged. Additions:

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| Pre-flight check 5: `gh project view` probe returns mismatched `project_node_id` or `status_field_id` | Step 0 (new check 5) | **Abort** | Exit 1, HALT `CROSS_REPO_VERIFY_FAILED`: `"issue-to-project: cached project_node_id or status_field_id does not match live board. Re-run 'issue-to-project --init'."` |
| Pre-flight check 5: `gh project view` probe itself fails (network, auth) | Step 0 | **Abort** | Exit 1, HALT `CROSS_REPO_VERIFY_FAILED`: `"issue-to-project: board ID verify probe failed: <gh error>. Check network/auth and retry, or re-run '--init'."` |
| `known_repos` entry malformed (not `owner/repo`) | Step 1 config validation | **Abort** | Exit 1, HALT `MALFORMED_CONFIG`, name the offending entry. |
| `reconcile_scope` value unknown | Step 1 config validation | **Abort** | Exit 1, HALT `MALFORMED_CONFIG`, list valid values. |
| `reconcile_scope == all-known-repos` + empty `known_repos` | Step 1 config validation | **Soft-warn** | Log `[issue-to-project] WARN: ...` (see §"Config Schema validation rule 7"). Continue. |
| Board item's repo not in `known_repos` during reconcile with `reconcile_scope == all-known-repos` | O3 reconcile step (future) | **Per-config** | `ITP_UNKNOWN_REPO_BEHAVIOR=warn` → log `[issue-to-project] WARN: item from unknown repo <owner/repo> — not in known_repos`; continue. `=error` → exit 1, HALT `UNKNOWN_REPO`. |
| `--board-audit` snapshot exceeds 9999 items | `--board-audit` run | **Soft-warn** | Log `[issue-to-project] WARN: board-audit hit the 9999 ceiling — counts may be incomplete`. Continue (same as v1 snapshot warn). |
| `board-audit.json` write fails | `--board-audit` step 2 | **Exit 1** | HALT `AUDIT_WRITE_FAILED`: same message pattern as v1. |

## Cross-cutting

### Exit codes

Unchanged from v1: `0` = success, `1` = abort or zero items synced, `2` = `--init` user-cancelled.

### HALT codes (new + inherited)

All v1 HALT codes inherited unchanged. New codes:

| HALT code | Meaning | Exit |
|---|---|---|
| `UNKNOWN_REPO` | Board item from a repo not in `known_repos` encountered during `all-known-repos` reconcile AND `ITP_UNKNOWN_REPO_BEHAVIOR=error` | 1 |
| `CROSS_REPO_VERIFY_FAILED` | Pre-flight check 5 probe returned mismatched IDs or itself failed | 1 |

Inherited (unchanged):
`PREFLIGHT_FAILED`, `MISSING_CONFIG`, `MALFORMED_CONFIG`, `MISSING_INPUT`, `MALFORMED_INPUT`, `EMPTY_INPUT`, `AMBIGUOUS_SLUG`, `SNAPSHOT_FAILED`, `STALE_CONFIG`, `TOTAL_SYNC_FAILED`, `AUDIT_WRITE_FAILED`, `AUDIT_SCHEMA_FAILED`, `INIT_FAILED`, `USER_CANCELLED`.

### Logging

Unchanged prefixes: `[issue-to-project]` and `[issue-to-project:auto]`. No new prefixes introduced.

### Idempotency contract

Unchanged from v1 for the normal sync path. `--board-audit` is read-only and always idempotent. Verify-on-first-call (check 5) adds one `gh project view` call before mutations; a second back-to-back run hits the same probe with the same result.

## Return Format (R1)

Additive to v1. Existing keys unchanged. New optional keys in the JSON object:

```
RESULT: {"status":"ok","slug":"my-feature","artifact_path":"specs/my-feature/project-sync.json","issues_in_input":12,"already_on_board":3,"added":9,"set_blocked":2,"left_default":7,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"cross_repo":{"verify_passed":true,"known_repos_count":2}}
```

`--board-audit` emits its own sentinel (no `slug`):

```
RESULT: {"status":"ok","artifact_path":"board-audit.json","total_items":47,"known_repos_count":2,"unknown_repos_count":1}
```

`cross_repo` key is omitted from the RESULT JSON when `known_repos` is absent from config.

## Decisions

**D1 — Re-derive board-wide audit on demand via `gh project item-list`; do not persist an aggregate log.**

_Decision:_ `--board-audit` calls `gh project item-list` live and writes `board-audit.json` as a fresh snapshot each time.

_Rationale:_ (1) The board is already the authoritative source; a separate persistent aggregate would be a second source of truth that can drift. (2) `gh project item-list` is a single paginable call — cheap at any board size the skill already supports. (3) No cross-repo write coordination is needed; any repo with the right config can run it.

_Alternatives rejected:_ (a) Append-log in a governance/meta-repo — adds a third repo with write permissions, overcomplicates single-owner setups. (b) Status-quo, no board-wide audit — leaves reconcile with no reliable way to distinguish foreign items from orphans.

_Implications:_ `board-audit.json` is a point-in-time snapshot, not a history. Callers needing history should version-control the file.

---

**D2 — Config remains per-repo; no symlink or central config.**

_Decision:_ Each repo carries its own `github_project` block. Operators copy-paste or template the block when onboarding a new repo.

_Rationale:_ (1) Matches the v1 ergonomics operators already know. (2) No filesystem dependency between repos at runtime — each `issue-to-project` run is hermetic. (3) Symlinks break in many CI environments and are invisible to `git status` without extra flags.

_Alternatives rejected:_ (a) Symlink to a shared config in a governance repo — too much indirection; silently breaks when the target repo is not cloned adjacent. (b) Central config fetched from GitHub raw URL — network dependency in a skill that currently needs no network beyond `gh auth status`.

_Implications:_ Operators must keep `known_repos`, `project_node_id`, and `status_field_id` consistent across all N repos' configs. The `--init` wizard auto-populates `known_repos` from the live board to reduce copy-paste error (D3).

---

**D3 — `--init` auto-discovers `known_repos` from existing board items; prompts for user confirmation before writing.**

_Decision:_ During `--init`, after resolving the Status field (existing step 4), call `gh project item-list` once to collect all `item['content']['repository']['nameWithOwner']` values. Present the unique set as a suggested `known_repos` list. Prompt: `"Detected these repos on the board: [list]. Add all as known_repos? [Y/n/edit]"`. On confirm, write the list; on `n`, write empty `[]`; on `edit`, open a text prompt for manual entry.

_Rationale:_ (1) Eliminates the main copy-paste error vector (wrong repo slug). (2) Auto-discovery is a single read call that reuses the `item-list` shape already understood by the skill. (3) Prompting for confirmation keeps the operator in control — they may intentionally exclude a repo.

_Alternatives rejected:_ (a) Purely manual entry — valid but error-prone for boards with 5+ repos. (b) Silently write discovered repos without confirmation — violates the "never prompt-less write to config" principle from v1 D2.

_Implications:_ `--init` gains one extra `gh project item-list` call. On a brand-new empty board, auto-discovery returns `[]` and the prompt is skipped; the user sets `known_repos` later.

---

**D4 — Verify-on-first-call is Pre-flight check 5 using `gh project view --format json`.**

_Decision:_ After the existing four pre-flight checks, run:

```bash
GH_HOST=github.com gh project view <number> --owner <owner> --format json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['id'] == '<project_node_id>', 'project_node_id mismatch'
fields = {f['id'] for f in d.get('fields',{}).get('nodes',[])}
assert '<status_field_id>' in fields, 'status_field_id not found'
"
```

Exit `CROSS_REPO_VERIFY_FAILED` on any assertion failure or `gh` error.

_Rationale:_ (1) Catches the `status_field_id` typo-drift scenario before any mutations run, giving a clear actionable error. (2) `gh project view` is the lightest read call available; it does not paginate items. (3) Verify-on-first-call is idempotent and adds ~200 ms per run — acceptable for a skill run ~weekly per consumer.

_Alternatives rejected:_ (a) Verify only on `--init` — doesn't catch drift that happens after init (field was recreated, project was cloned). (b) No verify, rely on the existing STALE_CONFIG heuristic — that fires after 2 failed `item-add` calls; verify-on-first-call catches the error before any write attempt.

_Implications:_ Every normal sync run now makes one additional `gh project view` call. `DRY_RUN=1` still runs check 5 (it's a read). If the probe itself fails due to transient network error, the run aborts — operators with flaky connectivity can set `ITP_SKIP_VERIFY=1` (new env var) to bypass check 5 at their own risk.

---

**D5 — `UNKNOWN_REPO` is warn-by-default, error on opt-in (`ITP_UNKNOWN_REPO_BEHAVIOR=error`).**

_Decision:_ When reconcile (O3) encounters an item from a repo not in `known_repos`, the default is a soft-warn log line. Operators who want a hard failure set `ITP_UNKNOWN_REPO_BEHAVIOR=error`.

_Rationale:_ (1) A new repo's items appearing on a shared board before its config is updated is a common bootstrapping state; aborting by default blocks legitimate work. (2) Operators with strict governance can opt in to the hard failure.

_Alternatives rejected:_ (a) Error by default — breaks the upgrade path: any board that already has items from a repo before that repo sets `known_repos` would instantly fail. (b) Silently ignore — hides the misconfiguration entirely; `known_repos` would never get populated.

_Implications:_ Operators must document `ITP_UNKNOWN_REPO_BEHAVIOR=error` in their CI setup if they want strict enforcement.

---

**D6 — `board-audit.json` is written to the repo root alongside `.claude/config.json`, not under `specs/`.**

_Decision:_ `--board-audit` writes `board-audit.json` to `$(git rev-parse --show-toplevel)/board-audit.json`.

_Rationale:_ (1) The board-audit spans all repos; placing it under `specs/{slug}/` would imply it belongs to a specific feature slug, which it doesn't. (2) Matches the location of `.claude/config.json` — same operator, same context. (3) Easy to `.gitignore` if desired.

_Alternatives rejected:_ (a) Under `specs/` with a sentinel slug (e.g. `specs/_board/`) — magic slug creates confusion with the slug-autodiscovery logic in step 2. (b) Configurable path via env var — premature generality for a read-only helper artifact.

_Implications:_ `board-audit.json` should be added to `.gitignore` in consumer repos that don't want ephemeral snapshots committed (documented in Migration Notes).

---

**D7 — `schema_version` in `project-sync.json` is bumped from `"1"` to `"2"` for artifacts written by v2.3.0+.**

_Decision:_ The `schema_version` field increments to `"2"`. The new `cross_repo` top-level key is omitted (absent, not `null`) when `known_repos` is not configured, so v1 consumers reading a v2 artifact with no cross-repo config see no unexpected required keys.

_Rationale:_ (1) Lets downstream tools detect which schema generation they're reading. (2) Omitting `cross_repo` when unused keeps the artifact backward-compatible without requiring a schema union type. (3) Bumping `schema_version` is the documented evolution path for `project-sync.schema.json` (mirrors `created-issues.schema.json` versioning).

_Alternatives rejected:_ (a) Keep `schema_version: "1"`, rely on key presence — ambiguous for consumers that need to validate strictly. (b) New file name (`project-sync-v2.json`) — breaks all consumers that grep for the fixed path.

_Implications:_ `project-sync.schema.json` gains a `oneOf` by `schema_version`. v1 artifacts (schema_version `"1"`) remain valid against the v1 schema draft stored at `references/project-sync.schema.json`.

---

**D8 — De-init is manual: operator edits `known_repos` in `.claude/config.json` directly.**

_Decision:_ No `--deinit-repo` flag. When repo X should no longer feed the board, the operator removes it from `known_repos` in every consuming repo's config.

_Rationale:_ (1) De-init is infrequent; a CLI verb adds cognitive load for a one-time operation. (2) Editing a JSON file is auditable via git history. (3) A `--deinit-repo` flag would need to locate and update configs in other repos, which is outside the scope of a skill run from a single repo.

_Alternatives rejected:_ (a) `--deinit-repo <slug>` flag — requires cross-repo config write access not currently in scope. (b) Auto-removal when a repo has zero items on the board — too aggressive; a repo may be temporarily empty.

_Implications:_ Documented in Migration Notes. Operators must update `known_repos` in all N repos' configs when removing a repo from the board feed.

---

**D9 — `--board-audit` is mutually exclusive with `--init` and with a positional slug.**

_Decision:_ Passing `--board-audit` with `--init` or with a slug exits `1` with `"issue-to-project: --board-audit takes no positional slug and cannot be combined with --init."` Implemented with `argparse.add_mutually_exclusive_group`.

_Rationale:_ (1) `--board-audit` is a read-only helper; combining it with a mutating flag creates an ambiguous operation order. (2) Consistent with the existing `--init` / slug mutual exclusion in v1.

_Alternatives rejected:_ (a) Allow `--board-audit --init` as "init then audit" — ordering semantics are unclear; two-step invocations are easier to reason about. (b) Silently ignore conflicting flags — hides operator mistakes.

_Implications:_ Scripts that want both must call them separately.

---

**D10 — The verify-on-first-call probe (check 5) is skippable via `ITP_SKIP_VERIFY=1`.**

_Decision:_ Setting `ITP_SKIP_VERIFY=1` bypasses Pre-flight check 5. A `[issue-to-project] WARN: ITP_SKIP_VERIFY=1 — skipping board ID verification` line is logged.

_Rationale:_ (1) Flaky corporate proxies or rate-limited tokens could make check 5 a reliability hazard in CI. (2) Operators with strict network policies need an escape hatch. (3) The original v1 STALE_CONFIG heuristic remains as a backstop even when check 5 is skipped.

_Alternatives rejected:_ (a) No skip mechanism — too inflexible for CI environments. (b) Retry with backoff instead of skip — adds latency without removing the failure mode.

_Implications:_ `ITP_SKIP_VERIFY=1` should be treated as a short-term workaround; operators who set it in CI should schedule a periodic re-init to catch genuine drift.

## Out of Scope

| ID | Item | Why deferred |
|---|---|---|
| O1 | PR lifecycle transitions (`In Progress`, `Done`) | Own design cycle; see v1 O1. |
| O2 | Webhook/polling/GitHub Actions integration | See v1 O2. |
| O3 | Reconcile skill implementation | Referenced here as a consumer of `known_repos`; the reconcile skill itself is a separate spec. |
| O4 | Cross-org boards (different GitHub orgs) | GraphQL root differs; auth model differs; own design cycle. |
| O5 | Per-repo Status routing overrides | One board, one Status field; routing is board-wide. |
| O6 | Automatic re-init on detected config drift | Re-init is always user-triggered (v1 D6). |
| O7 | `--retry-blocked-edits` mode | Deferred from v1 O8; still deferred. |
| O8 | `known_repos` auto-sync across repos (push config to other repos) | Cross-repo write access is outside a single skill's scope. |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Modify** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version: "2.3.0"`. Add check 5 to Pre-flight table. Add `--board-audit` to Argv & flag contract. Add `ITP_SKIP_VERIFY`, `ITP_UNKNOWN_REPO_BEHAVIOR` to env vars table. Add two new HALT codes to table. Update R1 examples. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Add step 4b: auto-discover `known_repos` from `item-list` after field resolution. Add prompt phrasing for Y/n/edit confirmation. Add `known_repos` and `reconcile_scope` to config-write template. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Add verify-on-first-call (check 5) detail with exact `gh project view` command and Python assertion snippet. Add `cross_repo` block to artifact-write step. Document `ITP_SKIP_VERIFY=1` escape hatch. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Add `known_repos` and `reconcile_scope` rows to required-keys table. Add validation rules 5–7. Add multi-repo example block. |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/board-audit.md` | Full `--board-audit` flow: `item-list` call, `repository.nameWithOwner` extraction, grouping logic, `board-audit.json` write, schema. |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/board-audit.schema.json` | JSON Schema draft-07 for `board-audit.json`. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | Add `schema_version: "2"` branch via `oneOf`. Add optional `cross_repo` object definition. |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New `**2.3.0**` block under `## issue-to-project skill`. |

## Testing Strategy

Mirrors v1 testing posture: static + dry-run + manual smoke.

| Test | What it covers | How |
|---|---|---|
| Schema files valid | `board-audit.schema.json` and updated `project-sync.schema.json` parse as JSON Schema draft-07 | `python3 -c "import json, jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(...)))"` |
| `known_repos` validation | Malformed entry → `MALFORMED_CONFIG` | Dry-run with injected bad config |
| `reconcile_scope` validation | Unknown value → `MALFORMED_CONFIG` | Dry-run with injected bad config |
| Verify-on-first-call passes | Check 5 probe confirms cached IDs | Live smoke test (manual) |
| Verify-on-first-call fails | Check 5 probe detects a mismatched `project_node_id` → `CROSS_REPO_VERIFY_FAILED` | Manual: temporarily corrupt `project_node_id` in config |
| `ITP_SKIP_VERIFY=1` bypass | Check 5 skipped; WARN logged | `DRY_RUN=1 ITP_SKIP_VERIFY=1 issue-to-project <slug>` |
| `--board-audit` output shape | `board-audit.json` validates against `board-audit.schema.json`; `by_repo` counts match `item-list` | Manual against sagibeast board |
| `--init` `known_repos` discovery | Auto-populated from live board; prompt accepted; config written with correct `known_repos` | Manual `--init` on sagibeast board |
| Multi-repo audit run | Two repos each run `issue-to-project`; `--board-audit` from either shows combined counts | Manual, two-repo smoke test |
| R1 sentinel includes `cross_repo` key | RESULT JSON parseable with new keys | `grep '^RESULT: '` after dry-run |

## Migration Notes

**For existing single-repo consumers (sagibeast):**

No action required to keep v1 behavior. `known_repos` and `reconcile_scope` are optional; omitting them preserves exact v1 semantics.

**To opt into cross-repo sync:**

1. Decide the set of repos that feed the board. For each repo, run `issue-to-project --init` (v2.3.0+). The wizard auto-discovers `known_repos` from existing board items and prompts for confirmation. Accept or edit the list.
2. Set `reconcile_scope: "all-known-repos"` in each repo's config (the `--init` wizard prompts for this).
3. Verify consistency: `known_repos` should be identical across all N repos' configs. Inconsistency means one repo's reconcile may still flag foreign items as orphans.

**To remove a repo from the board feed (de-init):**

1. Edit `known_repos` in every remaining repo's `.claude/config.json` — remove the departing repo's `"owner/repo"` entry.
2. Commit the config change in each repo.
3. The departing repo's existing items stay on the board; `issue-to-project` from that repo will no longer add new items if its config no longer points at the shared board number. If it does still point at the board, its items are simply not added to other repos' `known_repos` and therefore not flagged during reconcile.

**`board-audit.json` and `.gitignore`:**

`board-audit.json` is a point-in-time snapshot. Add it to `.gitignore` in consumer repos that do not want it committed:

```
# issue-to-project board-wide audit snapshot
board-audit.json
```

**`project-sync.json` schema_version bump:**

Artifacts written by v2.3.0+ carry `schema_version: "2"`. Downstream tools that strictly assert `"schema_version": "1"` must be updated. Tools that only read `summary` and `results` are unaffected — those keys are unchanged.
