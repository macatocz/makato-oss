<!-- markdownlint-disable MD013 -->
# Spec: Non-Status Field Sync (Priority, Iteration, Estimate, custom), v2.4.0

> **Status:** Design. Targets `issue-to-project` v2.4.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Generalize `issue-to-project` beyond the single Status single-select field. v2.4 writes Priority, Iteration, Estimate (Number), and Date Target fields from issue labels and milestone metadata, and exposes a config-extensible hook for arbitrary single-select custom fields. Each field has a declared source signal, a routing rule, and a per-field outcome in the audit artifact. The idempotency model from v1 carries forward unchanged.

## Non-Goals

- Text field writes. Out of scope; deferred to v3.
- Multi-select field writes. Out of scope; deferred to v3.
- Custom field formulas or computed fields (rollup, average, etc.). Out of scope.
- Field-value rollups from linked PRs into issue cards.
- Lifecycle transitions (In Progress → Done on PR merge) — those are O1 from v1, still deferred.

## Architecture

### High-level

```
plugins/makato-plan/skills/issue-to-project/
├── SKILL.md                          (bump version: 2.4.0)
├── references/
│   ├── config-schema.md              (updated: fields dict)
│   ├── init-wizard.md                (updated: field discovery + wiring)
│   ├── sync-process.md               (updated: multi-field write loop)
│   ├── project-sync.schema.json      (updated: schema_version 2, fields[])
│   └── field-type-routing.md         (new: per-type source signal + write call)
```

The sync loop in v1 performed at most two `gh project item-edit` calls per issue (one for add, one for Blocked). v2.4 adds a **field-write loop** after item-add that iterates `github_project.fields` and emits one `item-edit` per field with a resolved value. The re-run guard snapshot is extended to capture current values of all configured fields so re-runs can skip writes for fields already at target.

### Why this approach (alternatives considered)

Single sync loop with per-field dispatch is the natural extension of v1's two-call model. A separate "field sync" pass (run fields after all adds complete) was considered but rejected: it complicates error attribution and makes the per-issue outcome tuple harder to populate atomically. The loop-per-issue approach means one failed field write does not block other fields for the same issue — it is still per-field-per-issue soft-warn.

## Data Flow

```
created-issues.json  ──────────────────────────────────────────┐
                                                                 │
.claude/config.json  ──►  field routing table  ──►  item-add  ──►  field-write loop  ──►  project-sync.json
                                │                     │                │
                      (resolved field IDs +       snapshot          per-field
                       value mappings)           re-run guard        outcomes[]
```

**Signal extraction at sync time (step 2.5, new):** after reading `created-issues.json`, extract field signals from each issue entry once and cache them as a per-issue `signals` dict:

```python
signals = {
    "priority":  next((l.split(":")[1] for l in issue["labels"] if l.startswith("priority:")), None),
    "iteration": next((l.split(":")[1] for l in issue["labels"] if l.startswith("iter:")), None)
                  or (issue.get("milestone") or {}).get("title"),
    "estimate":  next((int(l.split(":")[1]) for l in issue["labels"] if l.startswith("points:")), None)
                  or SIZE_MAP.get(next((l.split(":")[1] for l in issue["labels"] if l.startswith("size:")), None)),
    "date_target": (issue.get("milestone") or {}).get("due_on"),
}
```

`SIZE_MAP = {"S": 1, "M": 3, "L": 8, "XL": 13}` — see D8 for why `size:*` is deprecated but still supported here as a fallback.

## Config Schema (diff vs v1)

The v1 flat keys (`status_field_id`, `status_field_name`, `options.*`) are **read as-is for one minor release (v2.4)**. Starting v2.5 a deprecation warning is printed on every run when the flat v1 shape is detected; full removal in v3.0. This gives consumers one release cycle to re-run `--init`.

New canonical shape (written by `--init` in v2.4):

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

**Why nested dict (Option A) over flat list (Option B)?**

Option A gives O(1) lookup by field key (`config["fields"]["priority"]`) in both Python and shell. Option B (list of objects) requires iterating every write to find the matching entry. With 5–10 fields this is negligible at runtime, but the skill code references specific fields by key at multiple points (`status`, `priority`, `iteration`); a keyed dict makes those references explicit and crash-loud when missing. Option B would also make conditional logic ("if priority field exists, write it") more verbose. Option A is chosen.

**Field discovery during `--init`:** after the user picks the project, `gh project field-list` returns all fields. `--init` attempts to wire up fields in this priority order:

1. **Status** — required; `--init` aborts if not found. Same v1 behavior.
2. **Priority** — wired if a single-select field named "Priority" (case-insensitive) exists and has options matching `p0/p1/p2/p3` (case-insensitive, any casing). If found but option names don't match exactly, `--init` prints a mapping prompt and lets the operator confirm or skip.
3. **Iteration** — wired if an iteration field exists. `current_only` defaults to `true`.
4. **Estimate** — wired if a number field exists named "Estimate", "Story Points", or "Points" (case-insensitive).
5. **Date Target** — wired if a date field exists named "Target Date", "Due Date", or "Target" (case-insensitive).

Custom single-select fields can be added manually to the config after `--init` runs; the skill processes any entry in `fields` with `type: "single-select"` as long as a source signal prefix is declared under an optional `"signal_prefix"` key.

## Audit Artifact (diff vs v1)

`schema_version` advances from `"1"` to `"2"`. The top-level `final_status` key is **kept for one minor release** (v2.4) as `fields["status"].current_value` alias. Removed in v2.5.

Each result row gains a `fields[]` array:

```json
{
  "issue_number": 47,
  "url": "https://github.com/zstary/sagibeast/issues/47",
  "labels": ["type:feat", "priority:p1", "points:3"],
  "outcome": "added_default",
  "project_item_id": "PVTI_lAHOA6Q…",
  "final_status": "Todo",
  "needs_status_retry": false,
  "fields": [
    {
      "name": "Status",
      "intended_value": "Todo",
      "current_value":  "Todo",
      "outcome": "set",
      "error": null
    },
    {
      "name": "Priority",
      "intended_value": "p1",
      "current_value":  "p1",
      "outcome": "set",
      "error": null
    },
    {
      "name": "Estimate",
      "intended_value": 3,
      "current_value":  3,
      "outcome": "set",
      "error": null
    },
    {
      "name": "Iteration",
      "intended_value": null,
      "current_value":  null,
      "outcome": "no_signal",
      "error": null
    }
  ],
  "cli_command": null,
  "error": null
}
```

**Per-field `outcome` enum:**

| Value | When |
|---|---|
| `set` | Write call succeeded; `current_value` confirmed from snapshot or write-response |
| `skipped_already_set` | Snapshot showed field already at target value; no write issued |
| `no_signal` | No source signal found for this field in this issue; field left at project default |
| `write_failed` | `item-edit` for this field failed; `error` non-null |
| `unsupported_type` | Field `type` not in v2.4's write matrix (e.g. `text`); logged, skipped |
| `dry_run` | `DRY_RUN=1` was set; write not issued |

**`summary` additions:**

```json
"summary": {
  "issues_in_input": 12,
  "already_on_board": 3,
  "added": 9,
  "set_blocked": 2,
  "left_default": 7,
  "add_failed": 0,
  "edit_failed": 0,
  "skipped_after_total_failure": 0,
  "dry_run": 0,
  "field_writes_attempted": 18,
  "field_writes_succeeded": 17,
  "field_writes_failed": 1
}
```

## Argv & flag contract

All v1 flags are unchanged. New additions:

- `issue-to-project --fields-only <slug>` — skips item-add entirely; only runs the field-write loop for issues already on the board. Useful for backfilling fields after config is extended. Mutually exclusive with `--init`.
- `ITP_SKIP_FIELDS=priority,iteration` env var — comma-separated list of field keys to skip in this run. Useful for partial rollouts or debugging.
- `--init` discovers and wires all available fields by default. The operator can opt out of individual fields during the `--init` prompt flow.

## Error Handling

All v1 error modes are inherited unchanged. New modes:

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| Config references a field `type` not in v2.4's write matrix (e.g. `"text"`) | Step 2 config validation | **Abort** | Exit 1, HALT `FIELD_TYPE_UNSUPPORTED`: `"issue-to-project: field '<name>' has type '<type>' which is not supported in v2.4. Remove it from config or upgrade to v3.0+ for text/multi-select support."` |
| Cached `field id` missing from live project (snapshot returns no such field) | Step 3 snapshot enrichment | **Abort** | Exit 1, HALT `FIELD_NOT_FOUND`: `"issue-to-project: cached field id for '<name>' not found on project #<N>. Re-run 'issue-to-project --init' to refresh field IDs."` |
| `item-edit` for a non-Status field fails | Step 4, per-field | **Soft-warn** | Log `[issue-to-project] WARN: issue #N field '<name>': write failed: <error>`. Record `fields[name].outcome: "write_failed"`. Continue to next field. Never halts the batch. |
| Iteration field: no current iteration exists on the project | Step 4, per-issue | **Soft-warn** | Log `[issue-to-project] WARN: iteration field has no active iteration — skipping`. Record `outcome: "no_signal"`. Continue. |
| `points:N` value is not a valid integer | Step 2.5 signal extraction | **Soft-warn** | Log `[issue-to-project] WARN: issue #N: label 'points:<N>' is not a valid integer — estimate skipped`. `signals["estimate"] = null`. Continue. |
| Multiple `priority:*` labels on one issue | Step 2.5 | **Soft-warn** | Log `[issue-to-project] WARN: issue #N: multiple priority:* labels — first occurrence wins`. |

## Cross-cutting

### Exit codes

Identical to v1: `0` = success or partial success with ≥1 item synced; `1` = abort or zero items synced; `2` = `--init` user-cancelled.

A run is considered exit-0 partial success (`status: "partial"`) if field writes fail but the add step succeeded for at least one issue. Total field-write failure alone does not escalate to exit 1.

### HALT codes (new + inherited)

All v1 HALT codes are immutable. New codes:

| HALT code | Meaning | Exit |
|---|---|---|
| `FIELD_TYPE_UNSUPPORTED` | Config references a field type v2.4 cannot write | 1 |
| `FIELD_NOT_FOUND` | Cached field id is absent from current project | 1 |

Inherited: `PREFLIGHT_FAILED`, `MISSING_CONFIG`, `MALFORMED_CONFIG`, `MISSING_INPUT`, `MALFORMED_INPUT`, `EMPTY_INPUT`, `AMBIGUOUS_SLUG`, `SNAPSHOT_FAILED`, `STALE_CONFIG`, `TOTAL_SYNC_FAILED`, `AUDIT_WRITE_FAILED`, `AUDIT_SCHEMA_FAILED`, `INIT_FAILED`, `USER_CANCELLED`.

### Logging

Log prefix `[issue-to-project]` for all progress, warnings, and per-field outcome lines. `[issue-to-project:auto]` remains reserved for autonomous inference (not used in v2.4). No new prefixes introduced.

Per-field success example:
```
[issue-to-project] issue #47: Priority → p1 (set)
[issue-to-project] issue #47: Estimate → 3 (set)
[issue-to-project] issue #47: Iteration → no_signal (skipped)
```

### Idempotency contract

Re-runs are safe. The snapshot in step 3 is extended to capture current values for all configured fields, not just Status. If a field is already at its target value (`intended_value == current_value`), no write is issued and the outcome is `skipped_already_set`.

The v1 hard guarantee "never overwrite a Status that was changed by a human" extends to all configured fields: `already_on_board` items are fully skipped (no field writes). `--fields-only` mode bypasses the add-guard; field writes still respect `skipped_already_set`.

## Return Format (R1)

The `RESULT:` sentinel adds three keys; existing keys are unchanged:

```
RESULT: {"status":"ok","slug":"<slug>","artifact_path":"specs/<slug>/project-sync.json","issues_in_input":12,"already_on_board":3,"added":9,"set_blocked":2,"left_default":7,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"field_writes_attempted":18,"field_writes_succeeded":17,"field_writes_failed":1}
```

`status` values and parsing contract unchanged from v1.

## Decisions

**D1 — Nested dict (Option A) for `fields` config block**

Decided: use `fields: { <key>: { id, name, type, options? } }` keyed by a stable lowercase identifier.

Rationale: (1) O(1) lookup by field key in Python and shell without iteration; (2) explicit crash-loud KeyError when expected fields are missing vs. silent miss with list search; (3) extensible by adding new keys without schema migration.

Alternatives rejected: flat list (Option B) — requires iteration to find fields by name; more verbose conditional logic in the sync loop. Parallel flat top-level keys (e.g. `priority_field_id`, `priority_options`) — doesn't scale to N fields; untidy to add custom fields.

Implications: v1 consumers must re-run `--init` by v2.5 to migrate from flat `status_field_id` / `options.*` to the new `fields.status` shape. The v1 flat shape is read-compat in v2.4 with a deprecation warning.

**D2 — Read-compat with v1 flat config shape for one minor release**

Decided: v2.4 detects v1-shaped config (presence of top-level `status_field_id` key) and translates it in-memory to the v2 `fields` dict before processing. Prints `[issue-to-project] WARN: v1 config shape detected — please re-run '--init' to migrate to v2.4 schema`. v2.5 removes the translation; v3.0 hard-errors.

Rationale: (1) one-release grace period matches the v1 migration note convention; (2) consumers running automated pipelines can upgrade the skill without breaking existing runs; (3) schema version makes drift detectable.

Alternatives rejected: hard cut at v2.4 (no read-compat) — breaks consumers on the day they upgrade the skill; inconsistent with the additive-keys principle in v1's config design. Silent non-warning read-compat — masks drift; ops teams don't learn to re-init.

Implications: v2.4 ships a `_detect_v1_config()` helper. The helper is removed in v2.5.

**D3 — `--init` wires default fields by presence, not by explicit opt-in**

Decided: `--init` discovers and wires Status (mandatory), plus Priority, Iteration, Estimate, Date Target if those fields exist on the project. The operator is shown the planned wiring before writing and can uncheck individual fields. Fields not found are silently omitted from the config (not an error).

Rationale: (1) zero-config goal — consumers shouldn't need to know field IDs to get a working setup; (2) silent omission is correct behavior for "this project doesn't have a Priority field"; (3) interactive confirmation before write preserves operator control.

Alternatives rejected: explicit opt-in per field (flag per field in `--init`) — over-engineered for typical single-project setup. Wiring all fields unconditionally without confirmation — risks writing unexpected field IDs that weren't intended.

Implications: `references/init-wizard.md` must document the discovery + confirmation UX and the field-existence check logic.

**D4 — Iteration: label wins over milestone title; `current_only: true` default**

Decided: if an `iter:YYYY-Qn` label is present, resolve it to the iteration with a matching title (case-insensitive substring match). If no label, fall back to the project's current active iteration when `current_only: true`. If `current_only: false`, the signal is treated as `no_signal` when no label is present — no write.

Rationale: (1) explicit label intent (`iter:2026-Q3`) should not be silently overridden by "current" logic; (2) `current_only: true` is the 90% case: operators want new issues to land in the active iteration; (3) label-wins preserves the established routing-from-labels principle from v1.

Alternatives rejected: milestone-only routing — milestones are often used for releases, not iterations; coupling them creates false matches. Always-write-current — ignores explicit `iter:*` labels; violates label-wins principle.

Implications: iteration field resolution requires one additional `gh project iteration-list` call (or `field-list` with full options payload) at run start to build the iteration title → ID map. Cached in memory for the batch; not written to config (iteration IDs change as sprints roll).

**D5 — Estimate: `points:N` is canonical; `size:*` is a deprecated fallback**

Decided: `points:N` (integer label) is the v2.4 canonical estimate signal. `size:S/M/L/XL` maps via `SIZE_MAP = {S:1, M:3, L:8, XL:13}` as a fallback if `points:N` is absent. If both are present, `points:N` wins. `size:*` emits a deprecation log line.

Rationale: (1) `points:N` is explicit and numeric — no ambiguity about point values; (2) `size:*` is an existing `to-issues` label dimension; graceful support avoids breaking existing flows; (3) deprecation log nudges operators to migrate without hard failure.

Alternatives rejected: size-only mapping — doesn't support teams with non-standard point scales. Drop size support entirely — would silently skip estimate writes for all existing `to-issues` consumers who use `size:*`.

Implications: `SIZE_MAP` is a const in `references/field-type-routing.md`. Operators with non-standard size-to-point mappings can override `SIZE_MAP` via an optional `estimate.size_map` subkey in the config field entry.

**D6 — Per-field outcomes sub-array (`fields[]`) on every result row**

Decided: every result row in `project-sync.json` carries a `fields[]` array with one entry per configured field, regardless of whether a write occurred.

Rationale: (1) complete outcome visibility per issue — no implicit "it worked unless error is set"; (2) enables diff tooling across runs; (3) `no_signal` outcome explicitly records the absence of a signal, distinguishing "no label" from "field not configured".

Alternatives rejected: sparse array (only fields with writes) — ambiguous whether absence means "no write" or "field not configured"; harder to parse for downstream consumers. Top-level parallel arrays per field type — doesn't scale to custom fields; breaks the flat R1 sentinel contract.

Implications: `project-sync.schema.json` must define `fields` as an array of objects with `name`, `intended_value`, `current_value`, `outcome`, `error`. `schema_version` advances to `"2"`.

**D7 — Backward-compat: keep `final_status` for one minor release**

Decided: the v1 `final_status` top-level key on each result row is kept in v2.4 as an alias to `fields[name="Status"].current_value`. Removed in v2.5.

Rationale: (1) downstream scripts parsing `final_status` (e.g. `build-create-pr`) must not break on the day of upgrade; (2) one-release grace period is consistent with D2's config migration window.

Alternatives rejected: remove immediately — breaks any downstream that reads `final_status` directly without first migrating. Keep indefinitely — perpetuates a redundant key; the canonical answer lives in `fields[]`.

Implications: `project-sync.schema.json` v2 must keep `final_status` as optional with a deprecation comment. v2.5 schema removes it.

**D8 — Field-write loop: per-field soft-warn, never halt**

Decided: a failed field write (`write_failed` outcome) logs a warning, records the error in `fields[].error`, and continues to the next field and next issue. Only `add_failed` for every issue in the batch escalates to `TOTAL_SYNC_FAILED`.

Rationale: (1) consistent with v1's per-issue soft-warn philosophy; (2) a Priority write failure on issue #7 should not prevent Estimate writes for issues #8–#20; (3) the audit artifact captures every failure for human triage without halting the pipeline.

Alternatives rejected: halt on first field-write failure — over-strict; Priority field edge cases (renamed options) would break the entire batch. Per-issue halt if any field fails — still too strict for a field whose signal may be intentionally absent on some issues.

Implications: the `RESULT` sentinel `status: "partial"` applies when `field_writes_failed > 0` even if `add_failed == 0`.

**D9 — Snapshot enriches current field values for re-run guard**

Decided: step 3 snapshot is extended. After `gh project item-list`, for each item on the board, the snapshot extracts current values for all configured fields (not just Status). A field write is skipped (`skipped_already_set`) when `signals[field_key] == snapshot[url][field_key]`.

Rationale: (1) prevents overwriting human-edited field values on re-run (extends v1 hard guarantee); (2) reduces API calls on repeated runs; (3) snapshot enrichment uses the same single `item-list` call — no extra round-trip.

Alternatives rejected: always write, ignoring current values — would overwrite human edits; contradicts v1's idempotency contract. Per-field probe before write — O(N×F) API calls; defeats the batching benefit.

Implications: `gh project item-list` response must include field values. This is available via `--format json` with field values in the item payload; verify against `gh project item-list` output shape before implementation.

**D10 — `--fields-only` mode for backfilling without re-adding**

Decided: a new `--fields-only` flag skips the add step entirely and runs only the field-write loop for issues already on the board. Items not on the board are recorded as `outcome: "not_on_board_skipped"`.

Rationale: (1) operators who extended their field config after the initial sync need a way to backfill without triggering duplicate-add attempts; (2) separates add-idempotency concerns from field-write-idempotency; (3) low implementation cost — reuses the same field-write loop with add step gated by flag.

Alternatives rejected: re-run normal mode (add step is idempotent anyway) — the `already_on_board` guard in the snapshot means no duplicate adds occur, but the operator intent is clearly "fields only"; a dedicated flag makes that explicit and avoids confusion. A separate `fields-backfill` subcommand — overkill; a flag suffices.

Implications: `--fields-only` and `--init` are mutually exclusive. `--fields-only` is incompatible with a bare slug positional argument; the slug is still resolved via mtime or explicit arg as normal.

## Out of Scope

| ID | Out-of-scope item | Why deferred |
|---|---|---|
| O1 | PR-opened → In Progress / PR-merged → Done lifecycle transitions | Own design cycle; unchanged from v1 O1 |
| O2 | Webhook listeners, polling daemons, GitHub Actions integration | Unchanged from v1 O2 |
| O3 | Bulk reconciliation of pre-existing issues not from `to-issues` | Unchanged from v1 O3 |
| O4 | Cross-repo project sync | Unchanged from v1 O4 |
| O5 | Text field writes | Complex escaping, no label-based signal; deferred to v3 |
| O6 | Multi-select field writes | No clear label-based signal for set membership; v3 |
| O7 | Custom field formulas / computed fields | Read-only on the GitHub Projects surface |
| O8 | Field-value rollups from linked PRs | Requires PR↔issue linkage graph; v3 |
| O9 | Automatic option-ID refresh on renamed board options | Rename detection requires a live probe on every run; re-init is the intended recovery path |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Modify** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump version to `2.4.0`. Add `--fields-only` to argv contract. Add `ITP_SKIP_FIELDS` env var. Update HALT codes table (add `FIELD_TYPE_UNSUPPORTED`, `FIELD_NOT_FOUND`). Update idempotency contract. Update R1 sentinel example. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Document `fields` dict shape. Document v1 read-compat detection. Add per-type required keys table. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Steps 4–6: add field discovery loop, confirmation UX, wiring of Priority/Iteration/Estimate/Date Target. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Step 2.5 (signal extraction). Step 3 (snapshot enrichment). Step 4 (field-write loop). Step 5 (schema v2 artifact). |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/field-type-routing.md` | Per-type write call reference: single-select (`--single-select-option-id`), iteration (`--iteration-id`), number (`--number`), date (`--date`). Signal resolution rules per type. `SIZE_MAP` constant. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | Bump `schema_version` enum to `["1","2"]`. Add `fields` array definition. Keep `final_status` as optional deprecated key. Add `field_writes_attempted/succeeded/failed` to summary. |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New `## issue-to-project` section with `**2.4.0**` block. |

## Testing Strategy

Inherits v1 testing posture (static + dry-run + one live smoke test per major path). Additions:

| Test | What it covers | How |
|---|---|---|
| Config migration | v1 flat config read-compat: `_detect_v1_config()` translates and emits deprecation warning | `DRY_RUN=1` with a hand-crafted v1-shaped config; assert warning in output |
| Multi-field dry-run | Synthetic `created-issues.json` with `priority:p1 points:3 iter:2026-Q3`; `DRY_RUN=1`; verify all three fields appear in `fields[]` with `outcome: "dry_run"` | Manual |
| `no_signal` path | Issue with no priority/estimate/iteration labels; verify `fields[]` has `outcome: "no_signal"` for those fields | Manual |
| `skipped_already_set` path | Run normal sync; run again; second run shows `skipped_already_set` for all fields already written | Manual re-run guard test |
| `--fields-only` flag | Issues already on board; `--fields-only`; items not on board recorded as `not_on_board_skipped` | Manual |
| Schema v2 validation | `project-sync.schema.json` validates correctly against a v2-shaped artifact and rejects a v1-shaped artifact missing `fields[]` | `python3 -c "import json, jsonschema; ..."` |
| `FIELD_NOT_FOUND` halt | Config has a field id that doesn't exist on project; assert HALT `FIELD_NOT_FOUND` and exit 1 | Manual against a stripped-down test project |

## Migration Notes

Consumers on v1.0.0 upgrading to v2.4.0:

1. Pull the skill update (v2.4.0 bump in `SKILL.md`).
2. Run `issue-to-project` normally. The v1 flat config (`status_field_id` / `options.*`) is read-compat; a deprecation warning is printed.
3. Re-run `issue-to-project --init` to migrate config to the v2 `fields` dict shape. This is non-destructive — `--init` re-discovers field IDs and rewrites the `github_project` block.
4. Verify `project-sync.json` shows `schema_version: "2"` and the new `fields[]` array.
5. Update any downstream scripts that read `final_status` from result rows to use `fields[name="Status"].current_value` before v2.5 ships.
