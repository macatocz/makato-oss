<!-- markdownlint-disable MD013 -->
# Spec: Bulk Reconciliation — Detect and Repair Board Drift, v2.2.0

> **Status:** Design. Targets `issue-to-project` v2.2.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Add a `reconcile` subcommand to `issue-to-project` that diffs the live board snapshot against expected state derived from `specs/*/created-issues.json` and reports drift without mutating by default. Two opt-in repair modes let operators apply safe or aggressive fixes. The feature closes the feedback loop that v1's "never overwrite a human-edited Status" guarantee left open: operators can now see and selectively repair every class of board/label disagreement without running a blind re-sync.

## Non-Goals

- Auto-scheduling or cron invocation — operators pick cadence.
- Slack, email, or PagerDuty notification — feed `reconcile-report.json` to existing observability.
- Reconcile across multiple boards in a single invocation — one board per run.
- Delete orphan items from the board — even `--repair-aggressive` never removes items.
- Any drift class that depends on unshipped features (cases 5, 6) is reported as `pending_future_feature` with no repair action.

## Architecture

### High-level

```
plugins/makato-plan/skills/issue-to-project/
├── SKILL.md                        (argv contract — updated, new subcommand)
├── references/
│   ├── config-schema.md            (unchanged)
│   ├── init-wizard.md              (unchanged)
│   ├── sync-process.md             (unchanged)
│   ├── project-sync.schema.json    (unchanged)
│   ├── reconcile-process.md        (NEW — full reconcile flow)
│   └── reconcile-report.schema.json  (NEW — artifact schema)
```

Execution path added alongside the two v1 paths:

```
issue-to-project reconcile [<slug>]
  │
  ├─ Step 0: Pre-flight (same 4 checks as v1)
  ├─ Step 1: Read config (same rules as v1 normal-run)
  ├─ Step 2: Resolve input scope (slug or union all created-issues.json)
  ├─ Step 3: Paged board snapshot (replaces single item-list call)
  ├─ Step 4: Drift detection (classify each issue into drift cases)
  ├─ Step 5: Repair (conditional on --repair-* flag; default: skip)
  └─ Step 6: Write reconcile-report.json + emit R1 sentinel
```

`project-sync.json` is written by the v1 normal-run only. This subcommand writes `reconcile-report.json` exclusively. Both can coexist in `specs/{slug}/`.

### Why this approach (alternatives considered)

**Separate skill (`reconcile-project-board`).** Rejected — duplicates pre-flight, config-read, and snapshot infrastructure. Co-locating as a subcommand keeps the `gh project` wrapper DRY and lets `reconcile` share the config-declared field/option IDs cached by `--init`.

**Always-on drift detection in normal-run.** Rejected — normal-run mutates; mixing detection output with mutation output confuses operators. A dedicated subcommand makes the read-only vs. mutating contract explicit.

**GraphQL-only approach (skip `gh` CLI, use `gh api graphql` directly).** Rejected — `gh project item-list` is the v1 tested surface; changing to raw GraphQL in v2.2 would require re-validating every field path. Cost exceeds value. Paged snapshot (step 3) achieves scale within the CLI surface.

## Data Flow

```
.claude/config.json ──────────────────────────────┐
                                                   ▼
specs/{slug}/created-issues.json  ──►  [merge deduped input]
specs/*/created-issues.json (slug-less) ──►        │
                                                   ▼
                              [paged gh project item-list]
                                         │
                                         ▼
                              [drift detection — 6 cases]
                                         │
                              ┌──────────┴──────────┐
                          no flag              --repair-*
                        (read-only)          (conditional)
                              │                     │
                              └──────────┬──────────┘
                                         ▼
                          specs/{slug}/reconcile-report.json
                          stdout: human summary + R1 sentinel
```

Slug resolution for the union (slug-less) path mirrors v1: glob `specs/*/created-issues.json`, union all `issues[]`, dedupe by URL with first-occurrence-wins and a `WARN` log per dup.

## Config Schema (diff vs v1)

No new keys in `github_project`. Reconcile reads the existing block verbatim: `owner`, `owner_type`, `number`, `project_node_id`, `status_field_id`, `options.*`.

One new **optional** top-level env var (not stored in config):

| Env var | Default | Purpose |
|---|---|---|
| `ITP_RECONCILE_PAGE_SIZE` | `100` | Items per page in the paged snapshot loop |

## Audit Artifact (diff vs v1)

`project-sync.json` is **unchanged**. New artifact:

```
specs/{slug}/reconcile-report.json
```

For slug-less (union) runs, written to `specs/.reconcile-report.json` (repo root of `specs/`). Schema at `references/reconcile-report.schema.json` (co-shipped).

```json
{
  "schema_version": "1",
  "reconcile_timestamp": "2026-06-26T10:00:00Z",
  "skill_version": "2.2.0",
  "mode": "read_only",
  "slug_scope": "my-feature",
  "project": {
    "owner": "zstary",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1",
    "total_board_items": 312
  },
  "summary": {
    "issues_in_input": 20,
    "board_items_inspected": 312,
    "clean": 17,
    "drift_total": 3,
    "by_case": {
      "orphan": 1,
      "sync_gap": 0,
      "label_blocked_board_not": 1,
      "board_blocked_label_not": 0,
      "pr_merged_not_done": 0,
      "field_disagrees": 0,
      "pending_future_feature": 1
    },
    "repaired": 0,
    "repair_skipped": 0
  },
  "drift": [
    {
      "case": "orphan",
      "severity": "warn",
      "url": "https://github.com/zstary/sagibeast/issues/55",
      "project_item_id": "PVTI_lAHOA6Q…",
      "board_status": "Todo",
      "input_labels": null,
      "note": "On board but not in any created-issues.json for this scope",
      "repaired": false,
      "repair_action": null
    },
    {
      "case": "label_blocked_board_not",
      "severity": "warn",
      "url": "https://github.com/zstary/sagibeast/issues/47",
      "project_item_id": "PVTI_lAHOA6Q…",
      "board_status": "In Progress",
      "input_labels": ["type:feat", "status:blocked"],
      "note": "labels say status:blocked but board Status is not Blocked — likely externally changed",
      "repaired": false,
      "repair_action": null
    }
  ],
  "orphans_for_review": [
    "https://github.com/zstary/sagibeast/issues/55"
  ]
}
```

`severity` is `info | warn | error`:

| Drift case | Default severity |
|---|---|
| `orphan` | `warn` — human review needed; no auto-delete |
| `sync_gap` | `warn` — v1 normal-run would fix this |
| `label_blocked_board_not` | `warn` — externally changed; not necessarily wrong |
| `board_blocked_label_not` | `warn` — mirror of above |
| `pr_merged_not_done` (case 5) | `error` — board is definitely stale |
| `field_disagrees` (case 6) | `error` — explicit config disagreement |
| `pending_future_feature` | `info` — case 5 or 6 detected but feature not shipped |

Schema at `references/reconcile-report.schema.json` (JSON Schema draft-07). Co-shipped with this version.

## Argv & flag contract

All v1 flags and env vars are inherited unchanged.

| Invocation | Behaviour |
|---|---|
| `issue-to-project reconcile` | Union all `specs/*/created-issues.json`; read-only report |
| `issue-to-project reconcile <slug>` | Scoped to one slug; read-only report |
| `issue-to-project reconcile [<slug>] --repair-additive` | Fix only `sync_gap` items (v1 safe re-sync logic) |
| `issue-to-project reconcile [<slug>] --repair-aggressive` | Fix all repairable drift; requires confirmation |
| `issue-to-project reconcile [<slug>] --repair-aggressive --yes-i-know` | Skip interactive confirmation (required on non-TTY) |
| `DRY_RUN=1 issue-to-project reconcile ...` | Reads and classifies drift; repair calls replaced by `cli_command` output only |

`reconcile` is a positional subcommand, not a flag — `--reconcile` is an alias accepted for backwards compatibility (D1).

`--repair-additive` and `--repair-aggressive` are mutually exclusive. Passing both exits `1` with `"issue-to-project: --repair-additive and --repair-aggressive are mutually exclusive."`.

`reconcile` and `--init` are mutually exclusive (inherits v1 rule).

## Error Handling

All v1 HALT codes are inherited and fire under the same conditions. New conditions:

| Failure mode | When | Severity | Action |
|---|---|---|---|
| `--repair-aggressive` on non-TTY without `--yes-i-know` | Step 4 pre-repair check | **Abort** | Exit 1, HALT `RECONCILE_NEEDS_CONFIRM`: `"issue-to-project: --repair-aggressive requires interactive confirmation or --yes-i-know on non-TTY."` |
| Any page of paged item-list fails | Step 3, mid-page | **Abort** | Exit 1, HALT `PAGED_SNAPSHOT_FAILED`: `"issue-to-project: paged board snapshot failed at page <N> (offset <offset>). Partial snapshot discarded — re-run to retry."` |
| Paged item-list: page 1 fails | Step 3 | **Abort** | HALT `SNAPSHOT_FAILED` (existing code, consistent with v1 single-call failure) |
| `reconcile-report.json` write fails (I/O) | Step 6 | **Exit 1** | HALT `AUDIT_WRITE_FAILED`; print: `"issue-to-project: reconcile-report.json write failed (<errno>). Drift was detected — re-run to capture artifact."` |
| `reconcile-report.json` fails schema validation | Step 6 | **Abort write** | HALT `AUDIT_SCHEMA_FAILED`; print schema error. Skill bug — fail loud. |
| Repair mutation fails per-item (additive or aggressive) | Step 5, per-item | **Soft-warn** | Log `[issue-to-project] WARN: repair failed for <url>: <error>`. Record `repaired: false` in artifact. Continue batch. |
| All repair mutations failed | After step 6 | **Exit 1** | HALT `TOTAL_SYNC_FAILED` (reuses v1 code; same semantic: batch ran, zero mutations succeeded). |

## Cross-cutting

### Exit codes

Unchanged from v1. `0` = success or partial; `1` = abort or zero mutations; `2` = user-cancelled (interactive `--repair-aggressive` only — same exit-2 semantic as `--init` cancel).

### HALT codes (new + inherited)

All v1 codes are immutable. Two new codes:

| HALT code | Meaning | Exit |
|---|---|---|
| `RECONCILE_NEEDS_CONFIRM` | `--repair-aggressive` on non-TTY without `--yes-i-know` | 1 |
| `PAGED_SNAPSHOT_FAILED` | Any page ≥ 2 of multi-page board snapshot failed mid-loop | 1 |

Full inherited set: `PREFLIGHT_FAILED`, `MISSING_CONFIG`, `MALFORMED_CONFIG`, `MISSING_INPUT`, `MALFORMED_INPUT`, `EMPTY_INPUT`, `AMBIGUOUS_SLUG`, `SNAPSHOT_FAILED`, `STALE_CONFIG`, `TOTAL_SYNC_FAILED`, `AUDIT_WRITE_FAILED`, `AUDIT_SCHEMA_FAILED`, `INIT_FAILED`, `USER_CANCELLED`.

### Logging

Log prefix rules unchanged. `[issue-to-project]` for progress and warnings. `[issue-to-project:auto]` reserved (not used here). Examples:

```
[issue-to-project] INFO: paged snapshot: page 1/4 (100 items)
[issue-to-project] INFO: paged snapshot: page 4/4 (12 items) — 312 total
[issue-to-project] WARN: drift detected: label_blocked_board_not on issue #47
[issue-to-project] WARN: orphan on board (not in any created-issues.json): #55 — listed in reconcile-report.json for human review
[issue-to-project] INFO: --repair-aggressive: overriding board Status for issue #47 (label wins)
```

### Idempotency contract

Read-only mode is trivially idempotent (no mutations). `--repair-additive` is idempotent (same contract as v1 normal-run — add-only, no status overwrites). `--repair-aggressive` **explicitly overrides the v1 hard guarantee** that "we never overwrite a Status changed externally." In aggressive mode, labels are the source of truth: if `status:blocked` is in `labels[]`, the board Status is set to `Blocked` regardless of what a human previously set. Operators must confirm this override interactively or pass `--yes-i-know`. This override applies only to the drift cases repaired in this run; it does not change v1 normal-run behavior, which remains non-aggressive.

Re-running reconcile after a partial repair: items repaired in a prior run will appear `clean` in the next snapshot (no regression). Items where repair failed will still appear as drift and can be retried.

## Return Format (R1)

Second-to-last stdout line (before optional `HALT:` tail), mirroring v1:

```
RESULT: {"status":"ok","mode":"read_only","slug_scope":"my-feature","artifact_path":"specs/my-feature/reconcile-report.json","drift_total":3,"repaired":0,"orphans":1,"sync_gap":0,"label_blocked_board_not":1,"board_blocked_label_not":0}
```

`status` values: `"ok"` (drift detected or clean, exit 0), `"partial"` (some repair mutations failed), `"failed"` (exit 1, any HALT).

`mode` values: `"read_only"`, `"repair_additive"`, `"repair_aggressive"`.

v1 `artifact_path`, `status` key names are preserved. New keys are additive.

After the sentinel, human handoff line:

```
Next: review specs/<slug>/reconcile-report.json; orphans listed in orphans_for_review[] require manual board action.
```

## Decisions

**D1 — `reconcile` as a positional subcommand, not a `--reconcile` flag, with `--reconcile` alias.**
Decided: positional subcommand is the canonical form; `--reconcile` is a tolerated alias.
Rationale: (1) Subcommands communicate a distinct execution path more clearly than flags, matching `--init`'s own pattern in v1. (2) A positional subcommand allows `[<slug>]` to follow naturally without ambiguity.
Rejected: flag-only (`--reconcile [slug]`) — syntactically awkward; `--reconcile my-feature` is easily confused with a value for the flag. Pure new skill (`reconcile-project-board`) — duplicates all shared infrastructure; rejected in Architecture.
Implications: `argparse` subparser added; backward-compat alias handled via `sys.argv` rewrite before parse.

**D2 — Board items beyond v1's 9999 ceiling use a paged snapshot strategy.**
Decided: check `totalCount` via `gh project view`, then loop `gh project item-list` in pages of `ITP_RECONCILE_PAGE_SIZE` (default 100) until all items fetched. Pseudocode:

```python
total = gh_project_view_total_count(owner, number)  # gh project view --format json | .items.totalCount
snapshot = {}
offset = 0
page = 1
while offset < total:
    batch = gh_project_item_list(owner, number, limit=PAGE_SIZE, after=offset)
    # gh project item-list <n> --owner <o> --format json --limit <PAGE_SIZE> --skip <offset>
    if batch fails: raise PAGED_SNAPSHOT_FAILED(page, offset)
    for item in batch['items']:
        if item.get('content') and item['content'].get('url'):
            snapshot[item['content']['url']] = { 'projectItemId': item['id'],
                                                  'currentStatusName': (item.get('status') or {}).get('name') }
    offset += len(batch['items'])
    page += 1
```

Rationale: (1) A single `--limit 9999` call on a 10k+ board risks memory/timeout; paging bounds both. (2) `totalCount` from `gh project view` is one cheap extra call that enables a progress log.
Rejected: Unlimited single call — `gh` has no `--limit 0` semantics; 9999 is the documented cap. Client-side streaming — not available through the `gh project` CLI surface.
Implications: `PAGED_SNAPSHOT_FAILED` is a new HALT code (page ≥ 2 only; page 1 failure keeps `SNAPSHOT_FAILED` for v1 consistency). `ITP_RECONCILE_PAGE_SIZE` env var. Reconcile is the only path using paged snapshot; v1 normal-run retains its single `--limit 9999` call (boards in normal sync are bounded by `to-issues` input size).

**D3 — Orphan detection is report-only; even `--repair-aggressive` never deletes.**
Decided: orphans are listed in `orphans_for_review[]` and emitted as `severity: warn` drift rows. No repair action in any mode.
Rationale: (1) Deletion is irreversible. (2) An orphan may be a legitimate manually-added item (spike, ops task) — the skill has no way to distinguish. (3) Follows v1 Hard Guarantee 1 ("never removes an item from the board").
Rejected: Delete under `--repair-aggressive` with `--yes-i-know` — the cost of a false-positive delete (losing a board item, potentially with custom fields) exceeds the cost of requiring a human click.
Implications: Orphan list is always populated even in repair modes. Humans take action out-of-band.

**D4 — Labels win over board in `--repair-aggressive`; board wins in read-only and `--repair-additive`.**
Decided: The source-of-truth tie-breaking is mode-dependent.
Rationale: (1) In read-only mode there is no repair — both sources are reported as-is. (2) In `--repair-additive` the only fix is `sync_gap` (adding missing items), which doesn't touch Status, so no tie-break applies. (3) In `--repair-aggressive`, operators have explicitly opted in to label-wins semantics — this is the only mode where the skill should override a human-changed Status, and `status:blocked` in `labels[]` is the canonical source of truth for this skill's domain. The confirmation UX makes the override explicit.
Rejected: Board always wins — defeats the purpose of reconcile in aggressive mode. Always ask which wins per-item — too interactive for a batch tool.
Implications: Documented plainly in Idempotency contract. `--repair-aggressive` changes `board_blocked_label_not` and `label_blocked_board_not` cases; `--repair-additive` changes only `sync_gap`.

**D5 — Slug-less reconcile unions all `specs/*/created-issues.json` with first-occurrence-wins on URL duplicates.**
Decided: mirrors v1's slug-less normal-run deduplication rule.
Rationale: (1) Consistency with v1 means no new logic needed for deduplication. (2) First-occurrence-wins is deterministic and logged — operators can trace which slug "won" any URL.
Rejected: Error on cross-slug duplicate URLs — too strict; the same issue can legitimately appear in two specs during a refactor. Merge labels from both — ambiguous when labels conflict.
Implications: Union output written to `specs/.reconcile-report.json` (not inside any single slug directory). Per-dup `WARN` logged.

**D6 — Cases 5 and 6 (PR-merged-not-done, field-disagrees) are classified as `pending_future_feature` with `severity: info`.**
Decided: detect and report only; no repair; no error severity.
Rationale: (1) Neither O1 nor O5 is shipped. Raising `error` for an unshippable repair would alarm operators unnecessarily. (2) Including the rows in the artifact now means operators will see them without a schema change when the features ship — they just need the severity and repair_action to update.
Rejected: Omit cases 5 and 6 entirely — loses the forward-compatibility schema anchor. Raise `warn` — still too alarming for a non-actionable item.
Implications: When O1/O5 ship their own specs, they update `repair_action` and severity for these rows; no schema migration needed.

**D7 — `--repair-aggressive` requires TTY interactive `yes` OR `--yes-i-know`; non-TTY without `--yes-i-know` is HALT `RECONCILE_NEEDS_CONFIRM`.**
Decided: TTY check via `sys.stdin.isatty()` at the start of Step 5 (pre-repair).
Rationale: (1) Non-TTY environments (CI, scripts) should never silently apply aggressive mutations. (2) `--yes-i-know` provides a machine-readable escape hatch without requiring `expect`/`echo y |`. (3) The check happens before any mutation — after the report is fully classified — so operators can review the drift rows before committing.
Rejected: Always interactive — blocks CI. Environment variable override only — less discoverable than a named flag.
Implications: HALT `RECONCILE_NEEDS_CONFIRM` printed with actionable message: `"issue-to-project: --repair-aggressive requires interactive confirmation or --yes-i-know on non-TTY."` No state left behind (no partial repair).

**D8 — `reconcile-report.json` is a new artifact with its own schema; `project-sync.json` is untouched.**
Decided: separate files, separate schemas.
Rationale: (1) The reconcile artifact covers the full board (all items inspected) while `project-sync.json` covers only the input slug's issues. Merging the shapes would break downstream consumers of `project-sync.json`. (2) A dedicated schema makes `pending_future_feature` rows and `orphans_for_review[]` expressible without polluting the v1 schema.
Rejected: Append reconcile metadata to `project-sync.json` — breaks v1 schema consumers. Emit reconcile as a separate top-level summary only (no per-row detail) — loses the per-issue auditability.
Implications: Consumers needing both artifacts read both files. `reconcile-report.schema.json` co-shipped at `references/reconcile-report.schema.json`.

**D9 — `--repair-additive` is safe and non-interactive; it applies v1 normal-run logic to only the `sync_gap` drift case.**
Decided: `--repair-additive` calls the same `item-add` (and conditional `item-edit` for `status:blocked`) path as v1 step 4, but only for issues classified as `sync_gap`. No confirmation prompt. No TTY requirement.
Rationale: (1) `sync_gap` is the one drift case v1 normal-run would fix on re-run anyway — additive mode is a targeted re-sync. (2) It does not overwrite any Status, so v1 Hard Guarantee 2 is preserved. (3) Non-interactive makes it safe for scripted post-`to-issues` pipelines.
Rejected: Require confirmation for additive mode too — unnecessary friction for a safe operation. Let additive mode also fix label/board status disagreements — that crosses into aggressive territory; keep the boundary clean.
Implications: `--repair-additive` behaves identically to running `issue-to-project <slug>` for each sync-gap issue, plus it writes a reconcile-report rather than updating `project-sync.json`.

**D10 — Paged snapshot is used only in reconcile; v1 normal-run retains `--limit 9999`.**
Decided: Normal-run does not adopt paged snapshot in v2.2.
Rationale: (1) Normal-run input is bounded by `created-issues.json` size (typically tens to low hundreds of issues), so the 9999 ceiling is never hit in practice. (2) Changing normal-run snapshot logic in v2.2 is an unnecessary risk surface — v1 callers may rely on the single-call timing. (3) If a consuming board genuinely exceeds 9999 items during normal-run, the existing `SNAPSHOT_FAILED`/soft-warn path handles it; the team can migrate to reconcile for large boards.
Rejected: Replace all `--limit 9999` calls with paged loop — wider change than the spec targets; defer to a dedicated performance pass.
Implications: `ITP_RECONCILE_PAGE_SIZE` env var applies only to reconcile path. Normal-run's `ITP_GH_TIMEOUT_SECONDS` still applies per-call inside the reconcile paged loop.

**D11 — Human summary always printed to stdout; `reconcile-report.json` always written even in read-only mode.**
Decided: artifact write and stdout summary are unconditional outputs of a successful reconcile run.
Rationale: (1) Operators running reconcile from a terminal need an immediate human-readable summary without parsing JSON. (2) Consumers running reconcile in CI need the artifact for downstream steps. Both outputs serve without conflict.
Rejected: Human summary only in TTY mode — breaks operator workflows that `tee` stdout to a log. Artifact only — loses interactive usability.
Implications: Summary format is fixed: counts by case + orphan list. No interactive pager.

## Out of Scope

| ID | Item | Why deferred |
|---|---|---|
| O1 | Case 5 repair: PR merged → set Status=Done | Depends on PR-merge lifecycle (v1 O1); own design cycle. Drift row included in report as `pending_future_feature`. |
| O2 | Case 6 repair: tracked field disagrees with source signal | Depends on multi-field sync (v1 O5); own design cycle. Drift row included as `pending_future_feature`. |
| O3 | Orphan deletion, even under `--repair-aggressive` | Hard rule. See D3. |
| O4 | Cross-board reconcile in one run | One board per run. Multi-board operator runs the command once per board. |
| O5 | Auto-scheduling (cron, GitHub Actions trigger) | Operator picks cadence. |
| O6 | Notification routing (Slack, PagerDuty, email) | Feed `reconcile-report.json` to existing observability. |
| O7 | `--retry-blocked-edits` mode (v1 O8) | Still deferred; tracked by `needs_status_retry` annotation on `project-sync.json`. Separate verb. |
| O8 | Per-status routing for `status:in-review` etc. | Still deferred; v1 O9. |

## File-by-File Changes

| Status | Path | Responsibility |
|---|---|---|
| **Modify** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version: 2.2.0`. Add `reconcile` to frontmatter `argument-hint`. Add `reconcile` subcommand dispatch in Process section. Add new HALT codes to HALT table. Add `--repair-aggressive` idempotency override to Idempotency contract section. Add `reconcile` argv rows to Argv & flag contract. |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/reconcile-process.md` | Full reconcile flow: slug resolution, paged snapshot pseudocode, 6 drift-case classifiers with decision tables, repair-mode dispatch, TTY check, artifact emission rules, human summary format. Loaded only when `reconcile` subcommand is active. |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/reconcile-report.schema.json` | JSON Schema draft-07 for `reconcile-report.json`. `drift[]` items have `case` (enum of 6 cases + `pending_future_feature`), `severity` (enum `info|warn|error`), `repaired` (boolean), `repair_action` (`["string","null"]`). `orphans_for_review` is `array[string]` (URLs). |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New `## \`issue-to-project\` skill` entry: `**2.2.0**` block listing reconcile subcommand, new drift cases, new HALT codes, new artifact. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | No change — reconcile does not write `project-sync.json`. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | No change — normal-run snapshot logic unchanged. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | No change — no new config keys. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | No change. |

## Testing Strategy

Inherits v1's static + dry-run + one live smoke test posture.

| Test | What it covers | How |
|---|---|---|
| Frontmatter parse | version bumped to `2.2.0`, `reconcile` in hooks or argument-hint | `bash scripts/check-skill-frontmatter.sh` |
| Schema files valid | `reconcile-report.schema.json` parses as JSON Schema draft-07 | `python3 -c "import json, jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(...)))"` |
| Read-only dry-run, all 6 cases | Synthetic `created-issues.json` + synthetic snapshot covering each drift case; run `DRY_RUN=1 issue-to-project reconcile`; verify all 6 cases appear in report with correct severities | Manual |
| `--repair-additive` dry-run | Inject 2 sync_gap items; verify only those are in `repaired: true` rows; verify no Status overwrite | Manual |
| `--repair-aggressive` TTY guard | Run in a non-TTY pipe without `--yes-i-know`; verify HALT `RECONCILE_NEEDS_CONFIRM` | `echo "" \| issue-to-project reconcile --repair-aggressive`; assert exit 1 + HALT code |
| `--repair-aggressive --yes-i-know` dry-run | Verify `label_blocked_board_not` and `board_blocked_label_not` rows are repaired; verify orphan rows are NOT repaired | Manual |
| Paged snapshot ≤ 100 items | Single-page board; verify loop exits after page 1 | Manual, small board |
| Paged snapshot 101 items | Synthetic 2-page board (mock `gh` responses); verify both pages merged, `total_board_items: 101` | Manual |
| HALT `PAGED_SNAPSHOT_FAILED` | Simulate page-2 failure; verify partial snapshot discarded, correct HALT emitted | Manual |
| Live smoke test | Run against real sagibeast project after a `to-issues` + `issue-to-project` normal-run; verify `drift_total: 0` on a clean board | Manual, one-time per release |

## Migration Notes

No breaking changes to v1 normal-run or `--init`. Consumers using `project-sync.json` are unaffected. The only user-visible change is the new `reconcile` subcommand and the two new HALT codes; existing scripts parsing `HALT:` lines receive unrecognized codes gracefully if they use `case`/`switch` with a default.

For sagibeast operators: after upgrading to v2.2.0, run `issue-to-project reconcile` once to establish a baseline `reconcile-report.json`. There is no migration of prior run history. No re-init required.
