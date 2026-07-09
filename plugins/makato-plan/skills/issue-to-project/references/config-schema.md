<!-- markdownlint-disable MD013 -->
# `.claude/config.json` → `github_project` block

The `issue-to-project` skill reads a `github_project` block alongside the existing `project` key in `.claude/config.json`. The block is written by `issue-to-project --init` and read on every normal-run sync. Validation rules below are enforced on every read; any failure aborts with HALT `MISSING_CONFIG` or `MALFORMED_CONFIG`.

## Shape

```json
{
  "project": "sagibeast",
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
    "init_skill_version": "2.1.0",
    "include_draft_prs": true,
    "webhook_audit_dir": ".issue-to-project/lifecycle",
    "webhook_pr_link_patterns": ["Closes", "Fixes", "Resolves"]
  }
}
```

## Multi-repo shape (v2.3.0+)

When a board is fed by issues from N source repositories (org-wide roadmap pattern), add `known_repos` and `reconcile_scope` to the `github_project` block. All v1 keys remain unchanged.

```json
{
  "project": "repo-a",
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
    "init_skill_version": "2.3.0",
    "known_repos": ["zstary/repo-a", "zstary/repo-b"],
    "reconcile_scope": "all-known-repos"
  }
}
```

## Required keys

| Field | Source | Purpose |
|---|---|---|
| `owner` | `gh api user --jq .login` (user-owned) or operator choice (org-owned) | Project owner login |
| `owner_type` | `"user"` or `"organization"` | Selects the GraphQL root in `gh project` calls |
| `number` | Operator picks from `gh project list` | Project number (human-visible, stable across renames) |
| `url` | Computed | Human-clickable sanity check |
| `project_node_id` | `gh project view` | Opaque GraphQL ID — needed for `item-add` and `item-edit` |
| `status_field_id` | `gh project field-list` | Opaque field ID — needed for `item-edit` |
| `status_field_name` | Literal `"Status"` in v1 (validated, not hardcoded) | Documents which field was wired up; lets re-init detect drift |
| `options.todo` | Single-select option ID | Read by v1.2 only when an issue carries an explicit `status:todo` label; no `item-edit` is issued (Todo is the project default) — the ID is cached for future use and audit. |
| `options.in_progress` | Single-select option ID | **Write target for `status:in-progress` since v1.2.** |
| `options.done` | Single-select option ID | **Write target for `status:done` since v1.2.** |
| `options.blocked` | Single-select option ID | **Write target for `status:blocked` since v1.0.** Failure-to-resolve aborts `--init`. |
| `init_timestamp` | UTC ISO-8601 at write time | Audit trail |
| `init_skill_version` | Skill version | Lets a future migration detect stale config |
| `title` | _(required as of v2.5.0)_ — human-readable project title (e.g. `"sagibeast"`) | Disambiguation anchor for auto-re-init matching. Added by `--init` v2.5+ and by silent one-time migration on first v2.5 run. Absent in v1 configs; auto-reinit is unavailable until migrated (migration failure degrades gracefully — normal sync continues). |
| `reinit_timestamp` | _(optional — present only after auto-re-init fires)_ | Audit trail: UTC ISO-8601 timestamp of last auto-re-init run. Written by auto-re-init sub-path only; never by `--init`. |
| `reinit_skill_version` | _(optional — present only after auto-re-init fires)_ | Skill version that performed the auto-re-init. |
| `reinit_reason` | _(optional — present only after auto-re-init fires)_ | Human-readable trigger description, e.g. `"stale_project_node_id: PVT_old rejected by item-add"`. |
| `include_draft_prs` | _(optional — added by `--init` v2.0.0)_ | When `true` (default), a draft PR counts as `In Progress` during `sync-lifecycle`. Set to `false` to ignore draft PRs. Absent key behaves as `true` (backward-compatible). **Not required** — validation MUST NOT treat its absence as a `MALFORMED_CONFIG`. |
| `webhook_audit_dir` | _(optional — added by `--init` v2.1.0, default `.issue-to-project/lifecycle`)_ | Root directory (relative to repo root) where per-delivery webhook audit artifacts are written. Each delivery creates `<webhook_audit_dir>/<YYYY-MM-DD>/<delivery-id>.json`. Absent key defaults to `.issue-to-project/lifecycle` — validation MUST NOT treat its absence as a `MALFORMED_CONFIG`. |
| `webhook_pr_link_patterns` | _(optional — added by `--init` v2.1.0, default `["Closes", "Fixes", "Resolves"]`)_ | Case-insensitive keyword prefixes scanned in PR body to find linked issue numbers (e.g. `"Closes #47"`). Operators may extend (e.g. `"Relates to"`) but the skill emits a `WARN` if the list exceeds 10 entries. Absent key defaults to `["Closes", "Fixes", "Resolves"]` — validation MUST NOT treat its absence as a `MALFORMED_CONFIG`. |
| `known_repos` | _(optional — added by `--init` v2.3.0, default `[]`)_ | Allowlist of `"owner/repo"` strings whose items are expected on this board (org-wide roadmap pattern). Empty list / absent key means no reconcile-scope filtering — behaves exactly as v1. Used by the `reconcile` subcommand to avoid flagging foreign-repo items as orphans. Each entry must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. |
| `reconcile_scope` | _(optional — added by `--init` v2.3.0, default `"this-repo-only"`)_ | Controls whether `reconcile` treats foreign-repo items as orphans. `"this-repo-only"` = v1 behaviour (foreign items are treated as orphans). `"all-known-repos"` = items from any `known_repos` entry are not flagged as orphans. |
| `host` | _(optional — added by `--init` v2.6.0, default `"github.com"`)_ | Bare hostname of the GitHub instance this config targets. No `https://` scheme prefix. No path component. Examples: `"github.com"` (cloud default), `"github.example.com"` (GHES). Missing key defaults to `"github.com"` on read — no config migration required for v1 configs. |
| `host_type` | _(optional — added by `--init` v2.6.0, default `"cloud"`)_ | Enum: `"cloud"` or `"enterprise"`. `"enterprise"` enables pre-flight Check 6 (GHES version gate). Missing key defaults to `"cloud"`. |
| `min_ghes_version` | _(optional — added by `--init` v2.6.0, default `"3.10"`)_ | Minimum required GHES installed version as a `"MAJOR.MINOR"` string. Read only when `host_type == "enterprise"`. Stored in config so operators can raise the floor without a re-init. Comparison must use integer-tuple semantics (see validation rule 11 below). Missing key defaults to `"3.10"`. |
| `options.ready` | _(optional — added by `--init` v2.7.0, default absent)_ | Single-select option ID — write target for `status:ready`. When absent, a `status:ready` label routes to `Todo` with a loud WARN; the skill does not HALT. |
| `options.in_review` | _(optional — added by `--init` v2.7.0, default absent)_ | Single-select option ID — write target for `status:in-review` AND for the `pull_request.opened` lifecycle event. When absent: `status:in-review` labels route to `Todo` with WARN; the lifecycle event falls back to `In Progress` with WARN (v2.0 backward-compat). |
| `pr_label_name` | _(optional — added by `--init` v2.7.0, default `"PR"`)_ | Repo label name stamped once on an issue when a linked open PR is first detected by `sync-lifecycle` / `--from-webhook`. Permanent historical marker — never removed by the skill. Empty string `""` explicitly disables all label calls (D9 sentinel). |
| `ready_queue_mode` | _(optional — added by `--init` v2.7.0, default `"manual"`)_ | One of `"manual"` or `"autonomous"`. In `"manual"` mode the skill never auto-promotes Todo → Ready. In `"autonomous"` mode the skill auto-promotes Todo → Ready for items that pass the `auto_promote_to_ready()` gate (no `status:*` label **other than** `status:ready-for-dev` — v2.8.0+ exempts the orchestrator-handoff marker, no `needs-human-review` label, no `blocked-by:*` label, no `hold-in-todo` label, current board status `Todo` or absent). |
| `ready_label_name` | _(optional — added by `--init` v2.8.0, default `"status:ready-for-dev"`)_ | Repo label name stamped on an issue when the skill auto-promotes it to `Ready` in autonomous mode (D11). Permanent historical marker — never removed by the skill. Empty string `""` explicitly disables the stamp (same D9 sentinel pattern as `pr_label_name`). Only relevant when `ready_queue_mode == "autonomous"`; in manual mode the per-row `ready_label_action` is always `null`. |

## Validation rules

1. **Block existence.** Missing `github_project` → abort with HALT `MISSING_CONFIG`: `"issue-to-project: .claude/config.json missing 'github_project' block. Run 'issue-to-project --init' to set up project board sync."`
2. **Required keys.** Any required key missing or empty → abort with HALT `MALFORMED_CONFIG`, name the missing key, suggest re-init.
3. **ID format sanity.** `project_node_id` must start with `PVT_`; `status_field_id` must start with `PVTSSF_`. Option IDs must be non-empty strings — the legacy "8-char hex" check is over-strict and is intentionally omitted. Strict prefix validation catches the common copy-paste corruption pattern (truncation, surrounding quotes) without over-asserting on the GitHub schema. The two new optional option keys `options.ready` and `options.in_review` (v2.7.0+) follow the same non-empty-string check when present.
4. **No live GraphQL probe.** The skill does NOT call `gh project view` on every run to validate IDs — that defeats the caching point. The first sync run after a board structure change fails on the actual `item-add` / `item-edit` call; the user then re-runs `--init`. A 2-strikes-on-`PVT_` heuristic in step 4 abort-escalates this to HALT `STALE_CONFIG` so the user gets an actionable message after 2 failed items instead of 20. Exception: Pre-flight check 5 (verify-on-first-call, v2.3.0+) adds one deliberate `gh project view` probe per normal-sync run; it is a designed exception to the no-probe rule and is skippable via `ITP_SKIP_VERIFY=1`.
5. **`known_repos` format (v2.3.0+).** Each entry must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. An invalid entry → abort with HALT `MALFORMED_CONFIG`, naming the offending entry.
6. **`reconcile_scope` enum (v2.3.0+).** Value must be `"this-repo-only"` or `"all-known-repos"`. Any other value → abort with HALT `MALFORMED_CONFIG`, listing valid values.
7. **Cross-field consistency (v2.3.0+, soft-warn).** If `reconcile_scope == "all-known-repos"` and `known_repos` is empty or absent, emit: `[issue-to-project] WARN: reconcile_scope is 'all-known-repos' but known_repos is empty — all foreign items will be treated as orphans. Add known_repos entries or switch to 'this-repo-only'.` Continue (soft-warn; harms reconcile accuracy but does not block sync).
8. **`title` required for auto-re-init (v2.5.0+).** `title` must be present and non-empty when `--auto-reinit` is active. If absent, the one-time migration runs automatically (see Migration section below). If migration fails, auto-re-init is unavailable for this run only — normal sync continues; `STALE_CONFIG` fires if stale detection triggers. `title` is NOT validated as MALFORMED_CONFIG on normal runs without `--auto-reinit`.
9. **`reinit_*` keys are optional** and not validated on normal-run config read (they are for audit trail only, not runtime). Missing `reinit_*` keys never cause MALFORMED_CONFIG.
10. **`init_*` keys are immutable after `--init`.** Auto-re-init MUST NOT overwrite `init_timestamp` or `init_skill_version`. These keys record the first-ever human-triggered setup and are the provenance record for operator intent.
11. **`host` validation (v2.6.0+).** When `host` is present it must be a non-empty string, must not contain `://` (no scheme prefix), and must not contain a `/` path component. Invalid → HALT `MALFORMED_CONFIG`: `"issue-to-project: github_project.host must not include a scheme (https://). Set it to the bare hostname, e.g. 'github.example.com'."` Missing `host` defaults to `"github.com"` on read (backward-compatible).
12. **`host_type` validation (v2.6.0+).** When `host_type` is present it must be `"cloud"` or `"enterprise"`. Any other value → HALT `MALFORMED_CONFIG`: `"issue-to-project: github_project.host_type must be 'cloud' or 'enterprise', got '<value>'."` Missing `host_type` defaults to `"cloud"`.
13. **`min_ghes_version` comparison must use integer-tuple semantics.** String comparison produces wrong results: `"3.9" > "3.10"` as strings (lexicographic). Always compare as `tuple(int(x) for x in version.split("."))`. Example: `tuple(int(x) for x in "3.9".split(".")) < tuple(int(x) for x in "3.10".split("."))` evaluates to `True` (correct).
14. **`host` must not contain multi-host syntax.** One `github_project` block = one host. Multi-host configs (source on GHES A, board on GHES B) are architecture-level rejected (D12). A config attempting multi-host is not a supported pattern.
15. **`pr_label_name` validation (v2.7.0+).** When present, the value must be either the empty string `""` (a documented sentinel that explicitly disables all label calls — D9) **or** a non-empty string of 1–50 characters matching `^[A-Za-z0-9_:.-]+$` (GitHub label-name rules — no spaces, no slashes). The regex/length check applies only to non-empty values. Whitespace-only values (e.g. a single space) → HALT `MALFORMED_CONFIG`: `"issue-to-project: pr_label_name must not be whitespace-only; use \"\" to disable or a valid label name matching ^[A-Za-z0-9_:.-]+$."` Missing key defaults to `"PR"`.
16. **`ready_queue_mode` validation (v2.7.0+).** When present, must be exactly `"manual"` or `"autonomous"`. Any other value → HALT `MALFORMED_CONFIG`: `"issue-to-project: ready_queue_mode must be 'manual' or 'autonomous', got '<value>'."` Missing key defaults to `"manual"`.
17. **`ready_label_name` validation (v2.8.0+).** When present, the value must be either the empty string `""` (a documented sentinel that explicitly disables the ready-for-dev stamp — same semantics as `pr_label_name`, rule 15) **or** a non-empty string of 1–50 characters matching `^[A-Za-z0-9_:.-]+$` (the colon is explicitly allowed so the default value `status:ready-for-dev` is valid). The regex/length check applies only to non-empty values. Whitespace-only values → HALT `MALFORMED_CONFIG`: `"issue-to-project: ready_label_name must not be whitespace-only; use \"\" to disable or a valid label name matching ^[A-Za-z0-9_:.-]+$."` Missing key defaults to `"status:ready-for-dev"`.

## v1 → v2.5 Title Migration

On the first v2.5 run against a v1-format config (`title` key absent):

1. Run `GH_HOST=github.com gh project view <number> --owner <owner> --format json` → extract `title`.
2. Write `title` into the `github_project` block. Update `init_skill_version` to `"2.5.0"`.
3. Log `[issue-to-project] INFO: migrated v1 config — cached title "<title>" for project #<number>`.

Migration is idempotent: if `title` is already present, skip silently.

Migration failure (e.g. `gh project view` times out) does not abort the run; it logs a warning and continues without the title key. Auto-re-init will be unavailable on this run only — if stale detection fires, it halts with `STALE_CONFIG` with an additional note: `"auto-reinit skipped: title not cached; run --init to upgrade config"`.

## v2.5 Full Config Shape (with `title` and optional `reinit_*` keys)

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

**Key immutability rule:** `init_timestamp` and `init_skill_version` are set once by `--init` and NEVER changed by auto-re-init. Auto-re-init updates only: `project_node_id`, `status_field_id`, `options.*`, `url`, and appends the three `reinit_*` keys.

## v2.6 Full Config Shape (with `host`, `host_type`, `min_ghes_version`)

The three new keys are optional and additive. v1 configs (no `host` key) resolve to `host: "github.com"` and `host_type: "cloud"` on read — no re-init required.

```json
{
  "github_project": {
    "host": "github.example.com",
    "host_type": "enterprise",
    "min_ghes_version": "3.10",
    "owner": "myorg",
    "owner_type": "organization",
    "number": 3,
    "title": "my-roadmap",
    "url": "https://github.example.com/orgs/myorg/projects/3",
    "project_node_id": "PVT_kwHOA6QjJ84BajMV",
    "status_field_id": "PVTSSF_lAHOA6QjJ84BajMVzhVaBWs",
    "status_field_name": "Status",
    "options": {
      "todo": "f75ad846",
      "in_progress": "47fc9ee4",
      "done": "98236657",
      "blocked": "8b7c5461"
    },
    "init_timestamp": "2026-06-26T10:00:00Z",
    "init_skill_version": "2.6.0"
  }
}
```

**URL synthesis (v2.6.0+):** `--init` computes `url` as `https://<host>/<owner_type_path>/<owner>/projects/<number>` where `owner_type_path` is `"users"` (user) or `"orgs"` (organization). With a non-github.com host, the computed URL uses that host verbatim.

**Backward compatibility.** A config written by v1 has none of the new keys. On read, missing `host` resolves to `"github.com"`, missing `host_type` resolves to `"cloud"`, missing `min_ghes_version` defaults to `"3.10"`. No config migration or re-init required for existing v1 consumers.

**New GHES consumers:** run `issue-to-project --init` after authenticating:

```sh
gh auth login --hostname github.example.com --scopes project,read:project
issue-to-project --init
# When prompted for host, enter: github.example.com
```

This writes `host`, `host_type: "enterprise"`, and `min_ghes_version: "3.10"` into the `github_project` block.

## Multi-repo scoping

The `github_project` block lives in `.claude/config.json` of the **consuming repo** (e.g. sagibeast), not the makato repo. Each consuming repo's config points to the project board that repo's `to-issues` invocations should sync to. Matches the existing per-repo `.claude/config.json` model from `to-issues` v3.

## Org-owned projects

`owner_type` flips the GraphQL surface. `gh project list --owner <login>` works for both user-owned and org-owned projects; `--init` captures `owner_type` from whichever shape `gh project list` returned. No special-casing in normal-run code.

## Caveat: `final_status: "Todo"` under project automation

If the consumer has configured a Project workflow that changes Status at item-add time, the actual board Status may differ from the artifact's `final_status: "Todo"`. The skill does not read back item-list after `item-add` to verify — `final_status` is the **intended end-state**, not a confirmed read.

---

## `fields` dict shape (v2.4.0+)

v2.4.0 introduces a nested `fields` dict inside `github_project`. This replaces the flat top-level `status_field_id` / `status_field_name` / `options.*` keys for new installs. Existing v1 configs continue to work during v2.4 (see V1 Read-Compat below).

### Canonical v2.4 config shape (written by `--init` v2.4.0)

```json
{
  "github_project": {
    "owner": "zstary",
    "owner_type": "user",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1",
    "project_node_id": "PVT_kwHOA6QjJ84BajMV",
    "fields": {
      "status": {
        "id": "PVTSSF_lAHOA6QjJ84BajMVzhVaBWs",
        "name": "Status",
        "type": "single-select",
        "options": {
          "todo":        "f75ad846",
          "in_progress": "47fc9ee4",
          "done":        "98236657",
          "blocked":     "8b7c5461"
        }
      },
      "priority": {
        "id": "PVTSSF_lAHOA6QjJ84BajMVzABCdef",
        "name": "Priority",
        "type": "single-select",
        "options": {
          "p0": "aabbcc01",
          "p1": "aabbcc02",
          "p2": "aabbcc03",
          "p3": "aabbcc04"
        }
      },
      "iteration": {
        "id": "PVTIF_lAHOA6QjJ84BajMVzITER001",
        "name": "Iteration",
        "type": "iteration",
        "current_only": true
      },
      "estimate": {
        "id": "PVTNF_lAHOA6QjJ84BajMVzNUM001",
        "name": "Estimate",
        "type": "number"
      },
      "date_target": {
        "id": "PVTDF_lAHOA6QjJ84BajMVzDATE01",
        "name": "Target Date",
        "type": "date"
      }
    },
    "init_timestamp": "2026-06-26T10:00:00Z",
    "init_skill_version": "2.4.0"
  }
}
```

### Per-field required keys

| Field key | Required keys | Optional keys | Notes |
|---|---|---|---|
| `status` | `id`, `name`, `type`, `options` (with `todo`, `in_progress`, `done`, `blocked`) | — | Type must be `"single-select"` |
| `priority` | `id`, `name`, `type`, `options` | `signal_prefix` | Type must be `"single-select"`. Options keys must be non-empty strings. |
| `iteration` | `id`, `name`, `type` | `current_only` (default `true`) | Type must be `"iteration"` |
| `estimate` | `id`, `name`, `type` | `size_map` (custom size-to-points override) | Type must be `"number"` |
| `date_target` | `id`, `name`, `type` | — | Type must be `"date"` |
| _(custom)_ | `id`, `name`, `type`, `signal_prefix` | `options` | `signal_prefix` declares the label prefix for value resolution |

### Supported field types (v2.4.0 write matrix)

| Type string | `gh project item-edit` flag | Notes |
|---|---|---|
| `"single-select"` | `--single-select-option-id <id>` | Requires `options` dict in config |
| `"iteration"` | `--iteration-id <id>` | Iteration ID resolved at runtime from live project; not cached in config |
| `"number"` | `--number <N>` | Integer or float accepted; sourced from `points:N` label |
| `"date"` | `--date <YYYY-MM-DD>` | Sourced from milestone `due_on` |
| `"text"` | — | **NOT supported in v2.4** → HALT `FIELD_TYPE_UNSUPPORTED` |
| `"multi-select"` | — | **NOT supported in v2.4** → HALT `FIELD_TYPE_UNSUPPORTED` |

If a field entry in `fields` has a `type` not in this table, config validation aborts with HALT `FIELD_TYPE_UNSUPPORTED`:
`"issue-to-project: field '<name>' has type '<type>' which is not supported in v2.4. Remove it from config or upgrade to v3.0+ for text/multi-select support."`

### V1 Read-Compat — flat config detection (v2.4)

v2.4 detects a v1-shaped config by checking for the presence of the top-level `status_field_id` key inside `github_project`. When detected, the skill translates the flat shape in-memory to the v2 `fields` dict before processing:

```python
def _detect_v1_config(gp: dict) -> bool:
    """Returns True if gp uses the v1 flat status_field_id / options.* shape."""
    return "status_field_id" in gp and "fields" not in gp

def _translate_v1_to_v2(gp: dict) -> dict:
    """In-memory translation of v1 flat config to v2 fields dict shape.
    Does NOT write to disk — the operator must re-run --init to persist the migration.
    """
    fields = {
        "status": {
            "id":      gp["status_field_id"],
            "name":    gp.get("status_field_name", "Status"),
            "type":    "single-select",
            "options": dict(gp.get("options", {})),
        }
    }
    gp = dict(gp)
    gp["fields"] = fields
    return gp
```

When a v1 config is detected and translated, emit exactly:
```
[issue-to-project] WARN: v1 config shape detected — please re-run '--init' to migrate to v2.4 schema
```

**Deprecation timeline:**
- v2.4: read-compat translation active; deprecation warning printed on every run.
- v2.5: translation is removed; running with a v1 config will fail with HALT `MALFORMED_CONFIG` with a message directing the operator to re-run `--init`.
- v3.0: hard removal (no migration path); v3 hard-errors on any config missing `fields.status`.

### Field discovery order during `--init` (v2.4.0)

After the operator picks a project, `--init` calls `gh project field-list` and attempts to wire fields in this priority order:

1. **Status** — required; `--init` aborts with HALT `INIT_FAILED` if not found. Same v1 behavior.
2. **Priority** — wired if a single-select field named "Priority" (case-insensitive) exists and has options matching `p0/p1/p2/p3` (case-insensitive, any casing). If found but option names don't match exactly, `--init` prints a mapping prompt and lets the operator confirm or skip.
3. **Iteration** — wired if an iteration field exists. `current_only` defaults to `true`.
4. **Estimate** — wired if a number field exists named "Estimate", "Story Points", or "Points" (case-insensitive).
5. **Date Target** — wired if a date field exists named "Target Date", "Due Date", or "Target" (case-insensitive).

Fields not found on the project are silently omitted from the config (not an error). The operator sees the planned wiring before `--init` writes and can uncheck individual fields during the confirmation prompt.

Custom single-select fields can be added manually to `fields` after `--init` runs; the skill processes any entry with `type: "single-select"` as long as a `"signal_prefix"` key is declared.

### Additional validation rules (v2.4.0+)

8. **`fields.status` required.** When a v2 config is detected (i.e. `fields` key present), `fields.status` must exist and be valid. Missing → HALT `MALFORMED_CONFIG`.
9. **Unsupported field type.** Any entry in `fields` with a `type` not in the v2.4 write matrix → HALT `FIELD_TYPE_UNSUPPORTED` at config-validation time (step 1, before any mutations).
10. **Field id not found on project.** During step 3 (snapshot), if a field `id` from config is absent from the live board's field list → HALT `FIELD_NOT_FOUND`: `"issue-to-project: cached field id for '<name>' not found on project #<N>. Re-run 'issue-to-project --init' to refresh field IDs."`
