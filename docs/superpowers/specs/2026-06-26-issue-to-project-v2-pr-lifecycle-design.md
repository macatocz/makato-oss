<!-- markdownlint-disable MD013 -->
# Spec: PR-open / merge lifecycle transitions, v2.0.0

> **Status:** Design. Targets `issue-to-project` v2.0.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Extend `issue-to-project` so a project item's Status automatically tracks its linked PR as the PR moves through its lifecycle — without any new daemon, webhook, or persistent process. A single `issue-to-project sync-lifecycle <slug>` invocation queries GitHub once per input issue, flips Status to `In Progress` when a PR has been opened (or `Done` when merged), and writes an enriched `project-sync.json`. Calling the command repeatedly is safe and idempotent.

Lifecycle logic is isolated behind a clean function boundary so that O2 (webhook-triggered invocation) can consume it without duplicating it.

## Non-Goals

- Webhook listener or GitHub Actions integration (O2).
- Reopened-PR detection: a PR that was closed unmerged and then re-opened is treated as newly open on the next polling run (O3).
- Per-PR comment posting board URLs back to the PR thread (O4).
- CI / checks status integration: build-failed does not affect Status (O5).
- Regressing Status to `Todo` when a PR is closed unmerged (O6).
- Regressing a human-pinned `Done` back to `In Progress` when a follow-up PR opens (O7).

## Architecture

### High-level

```
plugins/makato-plan/skills/issue-to-project/
├── SKILL.md                          (updated: new subcommand, new HALT, updated R1)
├── references/
│   ├── config-schema.md              (updated: include_draft_prs flag)
│   ├── init-wizard.md                (unchanged)
│   ├── sync-process.md               (unchanged)
│   ├── lifecycle-process.md          (NEW — GraphQL queries, precedence rules, outcome routing)
│   └── project-sync.schema.json      (updated: schema_version 2, new per-row keys, new summary keys)
```

The new subcommand `sync-lifecycle` invokes `references/lifecycle-process.md`. The existing `issue-to-project [slug]` (v1 normal run) path is untouched; v2 adds a second execution path alongside it.

```
issue-to-project sync-lifecycle [slug]
        │
        ▼
  Step 0: Pre-flight (same 4 checks as v1)
        │
        ▼
  Step 1: Read config (.claude/config.json → github_project)
        │
        ▼
  Step 2: Read input (specs/{slug}/project-sync.json — v1 artifact; abort if absent)
        │
        ▼
  Step 3: Snapshot current board state (gh project item-list, same as v1 Step 3)
        │
        ▼
  Step 4: For each project item in snapshot whose issue is in input:
            → GraphQL closingIssuesReferences lookup (batched per PR, not per issue)
            → Apply precedence rule → determine target Status
            → If target ≠ current and current was not externally set: item-edit
        │
        ▼
  Step 5: Write project-sync.json (schema_version: 2, overwrite-with-atomic-rename)
```

### Why this approach (alternatives considered)

**Subcommand `sync-lifecycle` vs. flag `--with-lifecycle` vs. always-on:**

`sync-lifecycle` is a distinct subcommand (D1). A flag conflates two concerns — adding new issues and transitioning existing ones — in one invocation. Always-on would silently change behavior for every existing `to-issues` → `issue-to-project` pipeline. A subcommand makes the lifecycle step explicit in shell history, composable in scripts, and independently retryable.

**GraphQL `closingIssuesReferences` vs. `gh pr list --search` vs. issue timeline events:**

`closingIssuesReferences` on the PR node is the canonical, structured field (D2). `gh pr list --search "linked:<url>"` calls the search API which has a separate rate limit and returns partial results for large repos. Issue timeline events (`timelineItems`) are write-heavy for cross-referenced issues and don't reliably encode "this PR closes this issue" as a structured predicate. GraphQL `closingIssuesReferences` is the GitHub-documented first-class surface for this relationship.

## Data Flow

```
specs/{slug}/project-sync.json (v1 output, schema_version: 1)
        │
        └─► lifecycle-process reads issue URLs and project item IDs
                │
                ├─► gh api graphql → PR nodes for each issue
                │     query: closingIssuesReferences on each issue node
                │     returns: [{ url, state, isDraft, mergedAt }]
                │
                ├─► precedence rule applied per issue (D5)
                │
                ├─► gh project item-edit (only when target ≠ current and not pinned)
                │
                └─► specs/{slug}/project-sync.json (schema_version: 2, overwritten)
```

**GraphQL query shape** (one call per issue, `gh api graphql -f query=...`):

```graphql
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      closingPullRequests(first: 20) {
        nodes {
          url
          state        # OPEN | CLOSED | MERGED
          isDraft
          mergedAt
        }
      }
    }
  }
}
```

For 200 input issues this is 200 sequential GraphQL calls. At typical latency (~300 ms each) the worst-case wall-clock time is approximately 60–90 seconds, acceptable for a polling invocation run after a human action. Sequential also avoids secondary-rate-limit throttling from concurrent requests (D8).

## Config Schema (diff vs v1)

One new optional key added to the `github_project` block:

```json
{
  "github_project": {
    "...existing v1 keys...": "...",
    "include_draft_prs": true
  }
}
```

| Field | Required | Default | Purpose |
|---|---|---|---|
| `include_draft_prs` | no | `true` | When `true`, a draft PR counts as `In Progress`. Set to `false` to ignore draft PRs and only advance to `In Progress` on a non-draft open PR. |

The `--init` wizard gains a step 6b prompt:

```
Count draft PRs as In Progress? [Y/n]:
```

Default `Y`. Writes `include_draft_prs: true/false` into the block. Existing configs without the key behave as `true` (backward-compatible default, D6).

No v1 keys are renamed or removed.

## Audit Artifact (diff vs v1)

`schema_version` advances from `"1"` to `"2"`. v1 readers must reject v2 artifacts with a clear error:

```
issue-to-project: project-sync.json is schema_version 2; this reader requires version 1.
Upgrade to issue-to-project v2.0.0 or use the v1 artifact at specs/{slug}/project-sync.v1.bak.json.
```

Before overwriting, v2 backs up the prior file to `project-sync.v1.bak.json` (one generation only; subsequent v2 runs overwrite the `.bak` file) so v1 readers can still consume a snapshot.

### New summary keys

```json
"summary": {
  "...existing v1 keys...",
  "set_in_progress": 3,
  "set_done": 1,
  "lifecycle_lookup_failed": 0,
  "lifecycle_skipped": 4
}
```

| Key | Meaning |
|---|---|
| `set_in_progress` | Items whose Status was flipped to `In Progress` this run |
| `set_done` | Items whose Status was flipped to `Done` this run |
| `lifecycle_lookup_failed` | Items where the GraphQL query for linked PRs failed (per-item soft failure) |
| `lifecycle_skipped` | Items skipped because Status was externally set (precedence rule) |

### New per-row keys

```json
{
  "issue_number": 47,
  "url": "https://github.com/zstary/sagibeast/issues/47",
  "labels": ["type:feat", "tier:foundation"],
  "outcome": "pr_opened_set_in_progress",
  "project_item_id": "PVTI_lAHOA6Q…",
  "final_status": "In Progress",
  "needs_status_retry": false,
  "linked_pr_url": "https://github.com/zstary/sagibeast/pull/51",
  "linked_pr_state": "open",
  "cli_command": null,
  "error": null
}
```

| New field | Type | Nullability rule |
|---|---|---|
| `linked_pr_url` | `["string", "null"]` | Non-null when a governing PR was found; null when no PR or lookup failed |
| `linked_pr_state` | `["string", "null"]` | One of `"open"`, `"merged"`, `"closed"`, `"null"` (string `"null"` when no PR; actual JSON null is also valid — schema accepts both) |

Existing v1 per-row keys (`project_item_id`, `final_status`, `needs_status_retry`, `cli_command`, `error`) are unchanged in name and semantics.

### New `outcome` values (v1 values are immutable)

| Value | When |
|---|---|
| `pr_opened_set_in_progress` | Governing PR is open (or draft if `include_draft_prs: true`); Status flipped to `In Progress` |
| `pr_merged_set_done` | Governing PR is merged; Status flipped to `Done` |
| `pr_closed_no_change` | Governing PR closed unmerged; Status unchanged (O6) |
| `lifecycle_skipped_externally_set` | Current Status was not set by this skill (precedence rule applied; no write) |
| `lifecycle_lookup_failed` | GraphQL call failed for this issue; Status unchanged |

## Argv & flag contract

New subcommand added. All v1 flags and env vars are preserved unchanged.

- `issue-to-project sync-lifecycle` — lifecycle transition run; resolves slug via most-recent-mtime.
- `issue-to-project sync-lifecycle <slug>` — lifecycle transition run against the named slug.
- `issue-to-project sync-lifecycle --dry-run` — prints what would change; no `item-edit` calls; writes artifact with `outcome: "dry_run"`. Note: this subcommand uses a `--dry-run` flag (in addition to `DRY_RUN=1` env var) because it is commonly invoked standalone and the flag is more discoverable than the env var for a new path. Both are honored; flag takes precedence.
- `sync-lifecycle` is **mutually exclusive** with `--init` and is a positional subcommand, not a flag. Passing `--init sync-lifecycle` exits `1`.
- `ITP_GH_TIMEOUT_SECONDS` applies to all `gh api graphql` calls in `sync-lifecycle` (same 30 s default).

## Error Handling

| Failure mode | When | Severity | Action |
|---|---|---|---|
| `project-sync.json` missing for slug | Step 2 | **Abort** | Exit 1, HALT `MISSING_INPUT`: `"issue-to-project sync-lifecycle: no project-sync.json found at specs/<slug>/. Run 'issue-to-project <slug>' first."` |
| `project-sync.json` is schema_version 2 already and no mutations needed | Step 2 | **Info** | Proceed normally; the artifact is already v2 format. No special handling. |
| `gh api graphql` fails for ALL issues | Step 4, batch-wide | **Abort** | Exit 1, HALT `LIFECYCLE_LOOKUP_FAILED`: `"issue-to-project sync-lifecycle: GraphQL PR-lookup failed for every issue. Check gh auth and network, then retry."` Artifact written with every entry as `outcome: "lifecycle_lookup_failed"`. |
| `gh api graphql` fails for an individual issue | Step 4, per-issue | **Soft-warn** | Log `[issue-to-project] WARN: issue #N: PR lookup failed: <error>`. Record `outcome: "lifecycle_lookup_failed"`. Continue. |
| `gh project item-edit` fails after a lookup | Step 4, per-issue | **Soft-warn** | Log warning, record `outcome` as the governing transition outcome with `error` populated. Does not set `needs_status_retry: true` (that flag is reserved for v1 Blocked-edit failures). |
| `item-edit` times out | Step 4, per-issue | **Soft-warn** | Treat as edit failure; record error, continue. |
| `project-sync.json` schema validation fails on write | Step 5 | **Abort write** | Exit 1, HALT `AUDIT_SCHEMA_FAILED`. Skill bug — fail loud. |
| `.bak` write fails (disk full, perms) | Step 5, pre-overwrite | **Soft-warn** | Log `[issue-to-project] WARN: could not write project-sync.v1.bak.json: <errno>`. Continue with main file write. The `.bak` is a convenience; its absence does not abort the run. |
| Every item's outcome is `lifecycle_skipped_externally_set` | After step 5 | **Exit 0** | All items were pinned by humans; nothing to do. Summary reflects reality. Not an error. |

All v1 error handling is unchanged. `TOTAL_SYNC_FAILED` does not apply to `sync-lifecycle` (the subcommand may legitimately find that no items need a transition).

## Cross-cutting

### Exit codes

Identical to v1:
- `0` — success or partial success (≥ 1 item evaluated, artifact written).
- `1` — abort or HALT condition.
- `2` — user-cancelled (only `--init`).

### HALT codes (new + inherited)

All v1 HALT codes are immutable. One new code added:

| HALT code | Meaning | Exit | New in |
|---|---|---|---|
| `PREFLIGHT_FAILED` | *(v1 — unchanged)* | 1 | v1 |
| `MISSING_CONFIG` | *(v1 — unchanged)* | 1 | v1 |
| `MALFORMED_CONFIG` | *(v1 — unchanged)* | 1 | v1 |
| `MISSING_INPUT` | *(v1 — unchanged; also fires in sync-lifecycle if project-sync.json absent)* | 1 | v1 |
| `MALFORMED_INPUT` | *(v1 — unchanged)* | 1 | v1 |
| `EMPTY_INPUT` | *(v1 — unchanged)* | 1 | v1 |
| `AMBIGUOUS_SLUG` | *(v1 — unchanged)* | 1 | v1 |
| `SNAPSHOT_FAILED` | *(v1 — unchanged)* | 1 | v1 |
| `STALE_CONFIG` | *(v1 — unchanged)* | 1 | v1 |
| `TOTAL_SYNC_FAILED` | *(v1 — unchanged; not triggered by sync-lifecycle)* | 1 | v1 |
| `AUDIT_WRITE_FAILED` | *(v1 — unchanged)* | 1 | v1 |
| `AUDIT_SCHEMA_FAILED` | *(v1 — unchanged)* | 1 | v1 |
| `INIT_FAILED` | *(v1 — unchanged)* | 1 | v1 |
| `USER_CANCELLED` | *(v1 — unchanged)* | 2 | v1 |
| `LIFECYCLE_LOOKUP_FAILED` | GraphQL PR-lookup failed for every issue in the batch | 1 | **v2** |

### Logging

Same prefix convention as v1:

- `[issue-to-project]` — progress and warnings.
- `[issue-to-project:auto]` — reserved for v2 autonomous-mode inference (the precedence-rule application qualifies; emit one line per item where the rule fires, e.g. `[issue-to-project:auto] issue #47: Status externally set to 'In Review' — skipping lifecycle transition`).

### Idempotency contract

The precedence rule (D5) is the idempotency spine of `sync-lifecycle`:

1. Fetch the current board Status via the step-3 snapshot.
2. Determine what Status this skill last wrote by consulting the `final_status` field in the existing `project-sync.json` (the v1 output, read in step 2).
3. If `current_board_status ≠ last_written_status` → the item was externally touched. Record `outcome: "lifecycle_skipped_externally_set"`. No write.
4. If `current_board_status == last_written_status` → this skill still owns the value. Apply the PR-state rule: compute `target_status` from the governing PR. If `target_status ≠ current_board_status` → write. If equal → no-op.

This contract guarantees: a card a human pinned to `Done` stays `Done` even if a follow-up PR opens. A card at `In Progress` that a human moves to `In Review` stays `In Review`. Re-running `sync-lifecycle` does not regress any manually-set state.

**Edge case — item not in v1 project-sync.json:** If a project item's issue URL is in the board snapshot but not in `project-sync.json` (e.g. the issue was added outside of `issue-to-project`), treat `last_written_status` as `null`, which means "externally owned from the start." Record `outcome: "lifecycle_skipped_externally_set"`.

## Return Format (R1)

The sentinel is the second-to-last line of `sync-lifecycle` output. New keys added; v1 keys retained unchanged (callers that parse only v1 keys continue to work):

```
RESULT: {"status":"ok","slug":"<slug>","artifact_path":"specs/<slug>/project-sync.json","issues_in_input":12,"already_on_board":12,"added":0,"set_blocked":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"set_in_progress":3,"set_done":1,"lifecycle_lookup_failed":0,"lifecycle_skipped":4}
```

`status` values follow v1 semantics. `"partial"` fires when `lifecycle_lookup_failed > 0`.

After the sentinel, the human-readable handoff line:

```
Next: review specs/<slug>/project-sync.json; items with outcome lifecycle_skipped_externally_set were manually pinned and were not touched.
```

## Decisions

**D1 — Subcommand `sync-lifecycle` over flag or always-on**
Decided: new positional subcommand `issue-to-project sync-lifecycle [slug]`.
Rationale: (1) Keeps the existing `issue-to-project [slug]` call surface unchanged — zero risk of regressions in every deployed pipeline. (2) Makes lifecycle transition an explicit, independently retryable step in shell history and CI scripts.
Alternatives rejected: `--with-lifecycle` flag — conflates new-issue sync with existing-item transition in one invocation, making dry-run behavior ambiguous; always-on — silently changes behavior for all v1 consumers without any opt-in.
Implications: v1 pipelines require no changes. Operators who want lifecycle tracking add a second call after the normal run.

**D2 — GraphQL `closingIssuesReferences` as the PR↔issue link source**
Decided: `repository.issue(number).closingPullRequests` via `gh api graphql`.
Rationale: (1) First-class structured field in GitHub's GraphQL schema; returns only PRs explicitly written with `Closes #N` or `Fixes #N` in body/title. (2) Not subject to the search API's separate rate limits or eventual-consistency lag.
Alternatives rejected: `gh pr list --search "linked:<url>"` — search API, secondary rate limit, partial results on large repos; issue timeline `timelineItems` — returns cross-reference events for every mention, requires client-side filtering and is unreliable for structured "closes" semantics.
Implications: requires `gh api graphql` (available in `gh` ≥ v2.13.0, same as v1 floor). One GraphQL call per issue; 200 issues ≈ 60–90 s sequential wall-clock time.

**D3 — Multiple PRs: merged-wins-over-open; among open, most-recently-updated**
Decided: governing PR is selected by: (a) if any PR is `MERGED`, pick the most recently merged one → Status `Done`. (b) else if any PR is `OPEN`, pick the most recently updated → Status `In Progress`. (c) else if all are `CLOSED` (unmerged), no change (O6).
Rationale: (1) A merged PR is the terminal state and should take precedence over any still-open PR on the same issue (hotfix + main-branch pattern). (2) "Most recently updated" among open PRs is the least surprising heuristic — it tracks the active PR rather than an abandoned draft.
Alternatives rejected: first-opened — stable but does not track the active work; last-touched (any state) — would let a closed PR re-govern after a merged one, reversing `Done` to `In Progress`.
Implications: the `linked_pr_url` in the artifact reflects the governing PR, not all PRs. Multiple-PR edge cases are logged at `[issue-to-project:auto]` level.

**D4 — Closed-without-merge: no Status change**
Decided: `PR.state == CLOSED && PR.mergedAt == null` → record `outcome: "pr_closed_no_change"`, do not modify Status.
Rationale: (1) Regressing to `Todo` removes human context; the issue may be addressed differently, abandoned, or the PR may be reopened. (2) The assignment brief explicitly recommends NO regression. (3) Aligns with v1's "never overwrite externally changed Status" philosophy — the human decides.
Alternatives rejected: auto-revert to `Todo` — treats `closed` as "work abandoned" which is often wrong; auto-revert to `Blocked` if `status:blocked` label present — requires reading live issue labels, which v1 explicitly prohibits (labels come only from `created-issues.json`).
Implications: operators wanting to track abandoned work must monitor the board manually or via a future `reconcile` skill.

**D5 — Precedence rule: externally-set Status blocks lifecycle writes**
Decided: if `current_board_status ≠ last_written_status` (as recorded in `project-sync.json.final_status`), treat the item as externally owned and skip the transition.
Rationale: (1) Prevents flip-flopping on boards where operators use custom statuses like `In Review`, `Needs QA`, or `Blocked` that are not in the skill's write set. (2) Consistent with v1's hard guarantee 2: "never overwrite a Status changed externally". (3) Opening a follow-up PR must not undo a human's `Done` pin.
Alternatives rejected: track-all-writes in a separate state file — more state to manage; query GitHub Project history API — not a stable v2 API surface; trust only the PR state — ignores human context entirely.
Implications: once a human edits Status, `sync-lifecycle` is permanently hands-off for that item unless the operator resets it (e.g. by manually returning it to the skill-expected value). This is intentional.

**D6 — `include_draft_prs: true` default**
Decided: draft PRs count as `In Progress` by default; `include_draft_prs: false` opts out.
Rationale: (1) Opening a draft PR represents real work-in-progress — the board should reflect it. (2) Most teams using GitHub Projects want visibility into in-flight work before review-ready. (3) Teams that use drafts for speculative work can opt out with one config key.
Alternatives rejected: default `false` — hides legitimate in-progress work until a PR is marked ready; no flag at all — removes team choice.
Implications: `--init` gains a prompt. Existing configs without the key default to `true` (backward-compatible).

**D7 — Input to `sync-lifecycle` is the v1 `project-sync.json`, not `created-issues.json`**
Decided: `sync-lifecycle` reads `specs/{slug}/project-sync.json` for its issue list and existing `project_item_id` values, not `created-issues.json` directly.
Rationale: (1) `project-sync.json` already has `project_item_id` per issue — avoids a redundant snapshot-lookup step. (2) Ensures the lifecycle step only operates on issues that were successfully added to the board; issues with `outcome: "add_failed"` in v1 are naturally excluded. (3) Tighter coupling to the pipeline: `sync-lifecycle` is the step after `issue-to-project`, not a standalone tool.
Alternatives rejected: read `created-issues.json` — would require the full snapshot + lookup to get project_item_id; accept arbitrary issue URLs via argv — scope creep.
Implications: `sync-lifecycle` requires a prior v1 run. If `project-sync.json` is absent, the command aborts with `MISSING_INPUT`.

**D8 — Sequential GraphQL calls, not batched/concurrent**
Decided: one `gh api graphql` call per issue, executed sequentially.
Rationale: (1) GitHub's secondary rate limit triggers on concurrent requests; sequential is the safe default. (2) 200 issues ≈ 60–90 s — acceptable for a human-triggered polling command. (3) A failed call for one issue does not affect others; concurrency would complicate error attribution.
Alternatives rejected: single batched query (GraphQL aliases for N issues) — query length grows linearly, hits GH's 2 MB request limit around ~800 issues; concurrent via asyncio — risks secondary-rate-limit throttling, complicates the `ITP_GH_TIMEOUT_SECONDS` contract.
Implications: large boards (>200 issues) may take minutes. This is the expected ceiling for polling mode; O2 (webhooks) addresses real-time needs.

**D9 — `schema_version` 1 → 2; v1.bak preservation**
Decided: `sync-lifecycle` writes `schema_version: "2"` artifacts. Before the first v2 overwrite, the prior v1 file is copied to `project-sync.v1.bak.json`.
Rationale: (1) v1 readers must be able to detect an incompatible artifact cleanly rather than parsing a format they don't understand. (2) One-generation `.bak` lets operators and downstream tools that haven't upgraded yet access the prior state without a git checkout.
Alternatives rejected: in-place migration (upgrade the artifact to v2, keep the same filename with no version bump) — breaks v1 readers silently; separate filename (`project-sync-v2.json`) — doubles the consumer surface; semantic versioning in the filename — non-standard for artifacts in this repo.
Implications: `schema_version` must be the first validation gate in any reader. The `.bak` file is one generation only; subsequent v2 runs overwrite it.

**D10 — `LIFECYCLE_LOOKUP_FAILED` is the only new HALT code**
Decided: add exactly one new HALT code; per-issue lookup failures route to `outcome: "lifecycle_lookup_failed"` (not a HALT).
Rationale: (1) A single issue's GraphQL failure is a soft-warn consistent with v1's per-issue soft-fail philosophy. (2) A batch-wide GraphQL failure is a hard abort (HALT) because it indicates an auth or network problem that makes the entire run meaningless. (3) Fewer HALT codes mean simpler caller logic.
Alternatives rejected: HALT per-issue on first GraphQL failure — too aggressive, would halt on transient errors; never HALT for lookup failures — batch-wide failure would silently produce an all-`lifecycle_lookup_failed` artifact, which is misleading.
Implications: callers distinguish per-issue lookup failure (`summary.lifecycle_lookup_failed > 0`, exit 0) from batch-wide lookup failure (HALT `LIFECYCLE_LOOKUP_FAILED`, exit 1).

## Out of Scope

| ID | Item | Why deferred |
|---|---|---|
| O1 | Webhook listener or GitHub Actions trigger | Different infrastructure; O2 tracks this. The lifecycle logic function this spec builds is reusable by O2. |
| O2 | Webhook-triggered invocation of the lifecycle logic | Depends on this spec's function boundary. Design separately after v2.0.0 ships. |
| O3 | Reopened-PR detection | A closed-then-reopened PR is treated as newly open on the next polling run. The edge case is uncommon enough to defer. |
| O4 | Per-PR comment posting board URL back to the PR | Noise for most workflows; no demand signal yet. |
| O5 | CI / checks status integration | Different signal domain; Status transitions on check results require a separate design. |
| O6 | Regression to `Todo` when a PR is closed unmerged | The human decides; auto-regression removes context and is incorrect more often than it is helpful. |
| O7 | Regression of human-pinned `Done` to `In Progress` when a follow-up PR opens | Covered by precedence rule (D5). Not a new out-of-scope item; stated here for clarity. |
| O8 | `--retry-blocked-edits` mode for v1 `needs_status_retry` rows | Still deferred from v1 O8; can ship independently of lifecycle work. |
| O9 | Per-status:* routing for `status:in-review`, `status:needs-info` etc. | Deferred from v1 O9; unchanged. |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Update** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version: 2.0.0`. Add `sync-lifecycle` to Argv contract. Add `LIFECYCLE_LOOKUP_FAILED` to HALT table. Update R1 sentinel with new summary keys. Add `references/lifecycle-process.md` to Reference Files block. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Document `include_draft_prs` optional key, default `true`. |
| **New** | `plugins/makato-plan/skills/issue-to-project/references/lifecycle-process.md` | Full `sync-lifecycle` flow: GraphQL query, PR selection rule (D3), precedence rule (D5), `include_draft_prs` check, per-item outcome routing, `.bak` write, artifact emission. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | `schema_version` enum adds `"2"`. New `summary` keys. New per-row keys `linked_pr_url`, `linked_pr_state`. New `outcome` enum values. `if/then` constraints for new outcomes. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Add step 6b prompt for `include_draft_prs`. No structural change. |
| **Keep** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Unchanged. v1 normal-run path is untouched. |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New `**2.0.0**` block under `## \`issue-to-project\` skill`. |

## Testing Strategy

Same posture as v1: static + dry-run + one live smoke test per major path.

| Test | What it covers | How |
|---|---|---|
| Frontmatter parse | `version: 2.0.0`, required keys | `bash scripts/check-skill-frontmatter.sh plugins/makato-plan/skills/issue-to-project` |
| Schema files valid | `project-sync.schema.json` v2 parses as JSON Schema draft-07; new keys present; new `outcome` enum values present | `python3 -c "import json, jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(...)))"` |
| Precedence rule — externally set | Seed `project-sync.json` with `final_status: "Todo"`, manually advance board item to `In Review`, run `sync-lifecycle --dry-run`; assert `outcome: "lifecycle_skipped_externally_set"` | Manual dry-run |
| Precedence rule — skill-owned, PR open | Seed board item at `Todo`, open a PR with `Closes #N`, run `sync-lifecycle --dry-run`; assert `outcome: "pr_opened_set_in_progress"` | Manual dry-run |
| Precedence rule — merged PR | Merge the PR, run `sync-lifecycle --dry-run`; assert `outcome: "pr_merged_set_done"` | Manual dry-run |
| Closed-no-change | Close PR unmerged, run `sync-lifecycle --dry-run`; assert `outcome: "pr_closed_no_change"` and Status unchanged | Manual dry-run |
| Draft PR with `include_draft_prs: true` | Open a draft PR, run; assert `In Progress` | Manual dry-run |
| Draft PR with `include_draft_prs: false` | Open a draft PR, run; assert no change | Manual dry-run |
| `.bak` preservation | Run `sync-lifecycle` on a v1 artifact; assert `project-sync.v1.bak.json` created and is valid v1 | Manual |
| Live smoke test | Full pipeline: `to-issues` → `issue-to-project` → open PR → `sync-lifecycle`; verify board Status = `In Progress` | Manual, one-time per release |
| Re-run idempotency | Run `sync-lifecycle` twice; second run produces identical artifact and no `item-edit` calls | Manual |

## Migration Notes

**For existing `issue-to-project` users (v1.0.0):**

1. `issue-to-project [slug]` (the v1 normal run) is unchanged. No pipeline breakage.
2. To enable lifecycle tracking, add one call after the normal run:
   ```
   issue-to-project sync-lifecycle <slug>
   ```
3. On first `sync-lifecycle` run, the v1 `project-sync.json` is backed up to `project-sync.v1.bak.json` and the main file is upgraded to `schema_version: 2`.
4. Any consumer that reads `project-sync.json` and checks `schema_version` should be updated to accept `"2"` or to read `project-sync.v1.bak.json` until upgraded.
5. Re-running `--init` is optional. The new `include_draft_prs` key defaults to `true` without re-init; run `--init` only to change it to `false`.

**For downstream skills** (`build-create-pr` or similar): the v2 artifact is a strict superset of v1. All v1 keys exist with the same types. New keys can be ignored by v1 consumers. The `schema_version` gate is the only required change.
