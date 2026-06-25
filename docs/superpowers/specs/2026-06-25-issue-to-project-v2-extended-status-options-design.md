<!-- markdownlint-disable MD013 -->
# Spec: Extended Status options + linked-PR signal — `Ready`, `In review`, `PR` label, v2.7.0

> **Status:** Design — patch revision after adversarial 10-lens review (2026-06-25, 98 surviving findings). Targets `issue-to-project` v2.7.0. Depends on v1.0.0+ contract; supersedes the lifecycle-transition portion of v2.0.0 for the PR-open case.
> **Spec date:** 2026-06-25 (patched same day)
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0); supersedes the routing portion of v1.2.0 and the v2.0.0 PR-open lifecycle rule.
> **Trigger:** the `macatocz/sagibeast` board ships with six Status options (`Todo`, `Ready`, `In progress`, `Blocked`, `In review`, `Done`). v1.2.0 only routes to four (`Todo`, `In Progress`, `Blocked`, `Done`); the other two columns are unreachable from `labels[]`. Plus: linked PRs need a visible signal on the board card — a `PR` repo label stamped onto the issue when a PR opens.

## Goal

Three additive capabilities:

1. **Six-status surface from `labels[]`.** Extend `STATUS_MAP` with `status:ready` → `Ready` and `status:in-review` → `In review`. Multi-label collision priority is extended to include the new statuses. Routing remains a pure function of `labels[]` — no live GitHub queries.
2. **PR-open transition flips to `In review`, not `In Progress`.** v2.0.0 routed `pull_request.opened` → `In Progress`. The semantically correct mapping is `pull_request.opened` → `In review` (the issue is now under code review). `In Progress` stays for "human is actively working on it, no PR yet". v2.0 outcomes rename accordingly. The merge transition (`pull_request.merged` → `Done`) is unchanged.
3. **`PR` repo label stamp (additive, never removed).** Whenever `sync-lifecycle` or `--from-webhook` resolves a linked open PR for an issue, the skill calls `gh issue edit --add-label PR` on that issue. The label is a **permanent historical marker** — once added, the skill NEVER removes it, even after the PR closes or merges. This keeps a durable, greppable record on the issue that a PR existed for it. Transient "PR is open right now" state is already encoded by Status (`In review` while open, `Done` after merge) and by the board's "Linked pull requests" field. `--init` creates the `PR` label in the repo if absent (color `0E8A16` green).

Implementation is purely additive on top of v1.2.0's `resolve_status_label()` and v2.0.0's `sync-lifecycle`. The skill keeps working on boards that lack `Ready` or `In review` because both new keys are optional in `options.*` — when a label routes to an absent option, the skill emits a loud `WARN` and falls through to `Todo`. Likewise, when `options.in_review` is absent and a PR opens, the v2.0 fallback `In Progress` is used and a loud WARN is emitted.

## Non-Goals

- Reordering the priority constants on operator request (O1). The order is hard-coded; operators wanting different precedence can pre-filter labels in `to-issues`.
- Per-repo Status name overrides (O2). The skill matches against the four canonical English names plus the two new English names. Localized Status names require a config-declared routing table — deferred to v3.0.
- Emission of the new labels by `to-issues` (O3). v2.7 only handles the *consumer* side. Operators may set `status:ready` / `status:in-review` manually between `to-issues` and `issue-to-project` runs, or a future `to-issues` release can add inference.
- Lifecycle transitions to `Ready` from PR/issue events (O4). `Ready` is an operator-set "next up" signal; there is no PR/issue event that semantically maps to "ready for pickup." Operators set this label manually.
- Bidirectional sync — removing a `status:*` label when the board card moves columns (O5). Board-to-label is covered by future `reconcile --label-sync`.
- Renaming the `PR` label to anything else (O6). The string `"PR"` is the **default** value of `pr_label_name`; operators **can** override it per-repo via the config key. Operators who want to disable the feature entirely set `pr_label_name: ""` (empty-string sentinel; D9). What is out of scope is **further customization beyond per-repo override** — e.g. per-label-event customization, multi-label sets, or templating from issue metadata.

## Architecture

### High-level

```text
plugins/makato-plan/skills/issue-to-project/
├── SKILL.md                          (updated: version, frontmatter description (names "In review" alongside "In Progress"/"Done"), Status routing table (adds Ready/In review rows), hooks list (adds route status:ready, route status:in-review, autonomous auto-promote), PR-label note, sync-lifecycle R1 RESULT example (adds set_ready, set_in_review, auto_promoted_ready, pr_label_added, pr_label_failed), NEVER section amended for autonomous narrowing)
├── references/
│   ├── config-schema.md              (updated: options.ready, options.in_review, pr_label_name (incl. empty-string disable sentinel), ready_queue_mode; validation Rule 3 extended for new optionals)
│   ├── init-wizard.md                (updated: step 4 captures all six options; step 5 validates only required options; step 6c creates PR label if absent (exact `gh label create` command, treats already-exists as success, soft-warns on permission failure, requires Issues:write scope); step 6d prompts ready_queue_mode with preserve-existing-on-reinit logic)
│   ├── sync-process.md               (updated: STATUS_MAP, PRIORITY, outcome routing — no PR-label calls here; normal-run only routes from labels; explicit auto_promote_to_ready dispatch pseudocode at call site)
│   ├── lifecycle-process.md          (updated: SUPPORTED set extended to accept all `1.x` and `2.x` artifacts through '2.7' (fixes pre-existing v2.1 regression); pull_request.opened → In review (was In Progress) when options.in_review present, else In Progress fallback with WARN (outcome `pr_opened_set_in_progress_fallback`); PR-label stamp on detect-open via `gh issue edit --add-label` — never removed (D9); WRITTEN_BY_SKILL set adds 'In review' for D5 precedence)
│   ├── webhook-lifecycle.md          (updated: SUPPORTED set extended through '2.7'; same In review remap on pull_request.opened; PR-label stamp on the matching webhook event — never removed; Token setup requires `Issues: Read and write`)
│   ├── retry-process.md              (updated: RETRY_TARGET extends to new edit_failed outcomes incl. auto_promoted_ready_edit_failed; schema_version gate extended through '2.7' — fixes pre-existing v2.1 regression)
│   ├── reconcile-process.md          (updated: 3 new drift cases — label_ready_board_not, label_in_review_board_not, label_pr_drift)
│   ├── project-sync.schema.json      (updated: schema_version '2.7'; 8 new outcomes; 5 new optional summary keys; 2 new optional per-row fields pr_label_action/pr_label_error)
│   ├── reconcile-report.schema.json  (updated: drift_case enum gains 3 new values — label_ready_board_not, label_in_review_board_not, label_pr_drift)
│   ├── field-type-routing.md         (unchanged)
│   ├── auto-reinit-process.md        (unchanged)
│   ├── board-audit.md                (unchanged)
│   └── board-audit.schema.json       (unchanged)
└── CHANGELOG.md                      (updated: **2.7.0** block)
```

### Why this approach (alternatives considered)

**Hard-coded label-to-name map vs. config-declared routing table:**

Hard-coded is chosen for v2.7 (D1). The six canonical names (`Todo`, `Ready`, `In progress`, `Blocked`, `In review`, `Done`) cover the entire GitHub-recommended Status surface as of 2026-06. A config-declared table would introduce a new validation surface (label→name shape, name→options.* lookup, missing-option fallback) for a single-option-pair addition. Defer the generalized form to v3.0 alongside localization support (O2).

**PR-label vs board "Linked pull requests" field:**

The board already exposes a "Linked pull requests" field that GitHub auto-populates. A repo-level `PR` label is **redundant data** with respect to that field — but the redundancy is the point: the label travels with the issue everywhere (PR list, issue list, search, notifications). The board field only shows on the board. v2.7 ships both: the board field is GitHub-managed and the skill never touches it; the `PR` label is skill-managed.

**`pull_request.opened` → `In review` vs `In Progress`:**

Decided: `In review` (D8). Rationale: an open PR means the issue is *under review* (either by reviewers or by CI). "In progress" semantically belongs to "human is working on it, no code visible yet." The v2.0 mapping was correct only for boards that lacked an `In review` column. On v2.7 six-option boards, `In review` is the precise mapping. v2.0 had no choice; v2.7 does.

## Data Flow

```text
created-issues.json (from to-issues)
        │
        ▼
resolve_status_label(labels)  ← v2.7 STATUS_MAP + PRIORITY extended
        │
        ├─ status:ready          → ("Ready",       "ready")
        ├─ status:in-review      → ("In review",   "in_review")
        ├─ <v1.2 labels>         → <v1.2 mappings>
        └─ <unknown / none>      → (None, None)
        │
        ▼
gh project item-edit \
  --id <project_item_id> \
  --project-id <project_node_id> \
  --field-id <status_field_id> \
  --single-select-option-id $gp.options.<resolved_key>
```

The only new branches are the two `STATUS_MAP` entries and the corresponding `PRIORITY` insertions.

## Config Schema (diff vs v2.6)

Two new **optional** keys added to `github_project.options`, plus one new top-level optional key for the PR label name:

```json
{
  "github_project": {
    "...": "...",
    "options": {
      "todo":       "f75ad846",   // required (v1.0.0+)
      "in_progress":"47fc9ee4",   // required (v1.0.0+)
      "done":       "98236657",   // required (v1.0.0+)
      "blocked":    "51fc4188",   // required (v1.0.0+)
      "ready":      "61e4505c",   // optional (v2.7.0+)
      "in_review":  "df73e18b"    // optional (v2.7.0+)
    },
    "pr_label_name": "PR",         // optional (v2.7.0+), default "PR"
    "ready_queue_mode": "manual"    // optional (v2.7.0+), default "manual"
  }
}
```

| Field | Required | Default | Purpose |
|---|---|---|---|
| `options.ready` | no | *absent* | Write target for `status:ready`. Absent → routing falls through to `Todo` with WARN. |
| `options.in_review` | no | *absent* | Write target for `status:in-review` AND for the v2.0 `pull_request.opened` lifecycle event. Absent → label routes to `Todo` with WARN; lifecycle event falls back to `In Progress` with WARN (v2.0 backward-compat). |
| `pr_label_name` | no | `"PR"` | Repo label name **stamped once** on an issue when a linked open PR is first detected by `sync-lifecycle` / `--from-webhook`. Permanent historical marker — never removed by the skill. Operators can override (e.g. `"has-pr"`); empty string explicitly disables all label calls (D9-edge). |
| `ready_queue_mode` | no | `"manual"` | One of `"manual"` or `"autonomous"`. In `"manual"`, the skill NEVER auto-promotes Todo → Ready; the Ready column is strictly user-driven. In `"autonomous"`, the skill auto-promotes Todo → Ready for items that pass the `auto_promote_to_ready()` gate (no `status:*` label, no `needs-human-review` label, no `blocked-by:*` label, current board status `Todo` or absent). |

The `--init` wizard's Step 4 captures all six options into `options.*` (case-insensitive name match `"In review"` → `in_review`); Step 5 keeps validating only the four required keys. Step 6c (new) creates the `pr_label_name` repo label if it does not already exist, with color `0E8A16` and description `"This issue has an open linked pull request."` (D9). Implementation contract for Step 6c:

```python
# Skip the step entirely when pr_label_name is the empty-string disable sentinel.
if pr_label_name == "":
    log_info("Step 6c skipped: pr_label_name is empty — PR-label feature disabled.")
else:
    gh label create "$pr_label_name" \
        --color "0E8A16" \
        --description "This issue has an open linked pull request." \
        --force=false   # never overwrite an existing label with a different color/description
    # Exit codes:
    #   0  → created OR already exists (gh treats both as success when --force=false omitted; spec treats "already exists" as success).
    #   non-zero → soft-warn; do NOT HALT the wizard. Message:
    #     "[issue-to-project:init] WARN: could not create repo label '$pr_label_name': <stderr>.
    #      The skill will still attempt to stamp the label at sync-lifecycle time; if the
    #      label does not exist there, the per-row pr_label_action will be 'failed'.
    #      Most common cause: the GitHub token lacks 'issues:write' (Issues: Read and write) scope."
```

Step 6c additionally runs a **pre-flight token-scope check** when `pr_label_name` is non-empty: it inspects `gh auth status --show-token` (or `gh api user --include` headers) for the `repo` / fine-grained `issues:write` scope and emits a single loud INFO line confirming the scope is present, or a loud WARN line naming the missing scope and the consequence (every label stamp will fail at runtime). The pre-flight check is advisory only — it does NOT HALT. Step 6d (new) prompts:

```text
Ready-queue ownership: who promotes Todo → Ready?
  [m] manual     — the user moves items via UI or sets status:ready in to-issues. (default)
  [a] autonomous — the orchestrator auto-promotes items with no status/blocked/review labels.
Choice [m]:
```

Existing configs from v1.0.0–v2.6.0 remain valid without re-init — they will route `status:ready` and `status:in-review` to `Todo` with a WARN until the operator re-runs `--init`, and they default to `ready_queue_mode: "manual"`.

### Validation rule changes (vs v2.6)

Rule 3 (option IDs) keeps its strict prefix check on the four required options; the two new options follow the same shape but are validated only when present. `pr_label_name`, when present, must be either the **empty string `""`** (a documented sentinel that explicitly disables all label calls — D9) **or** 1–50 chars matching `^[A-Za-z0-9_:.-]+$` (GitHub label-name rules — no spaces, no slashes). Whitespace-only values (e.g. a single space) → HALT `MALFORMED_CONFIG`. The regex/length check applies only to non-empty values. `ready_queue_mode`, when present, must be exactly `"manual"` or `"autonomous"`; any other value → HALT `MALFORMED_CONFIG` with the message `"issue-to-project: ready_queue_mode must be 'manual' or 'autonomous', got '<value>'."`

## Audit Artifact (diff vs v2.6)

`schema_version` advances from `"2.6"` to `"2.7"`.

### New summary keys

```json
"summary": {
  "...existing keys...",
  "set_ready": 0,
  "set_in_review": 0,
  "auto_promoted_ready": 0,
  "pr_label_added": 0,
  "pr_label_failed": 0
}
```

| Key | Meaning |
|---|---|
| `set_ready` | Items routed to `Ready` (outcome `added_ready`) this run — explicit `status:ready` labels |
| `set_in_review` | Items routed to `In review` (outcome `added_in_review` OR `pr_opened_set_in_review`) this run |
| `auto_promoted_ready` | Items where the skill auto-promoted Todo → Ready this run (autonomous mode only). Always `0` in `ready_queue_mode: "manual"`. |
| `pr_label_added` | Issues that received a successful `gh issue edit --add-label <pr_label_name>` call this run (counts every successful add invocation; GitHub treats add-label as idempotent at the API level so re-adds count as `added` — see D9). |
| `pr_label_failed` | Issues where the label add call failed (soft-warn; does not block the run) |

**Accounting invariants (v2.7).** Two separate identities apply, scoped explicitly to avoid conflating normal-run adds with lifecycle/autonomous transitions:

**Identity 1 — Normal-run add identity** (applies to artifacts emitted by the `add new items` path):

```text
set_todo + set_ready_label + set_in_progress + set_in_review_label + set_blocked + set_done + left_default
  = (items added by this run from created-issues.json)
```

…where `set_ready_label` and `set_in_review_label` count only the `added_ready` / `added_in_review` outcomes (label-driven adds), not lifecycle transitions or autonomous promotions.

**Identity 2 — Already-on-board transition identity** (applies to artifacts emitted by autonomous mode or `sync-lifecycle`):

```text
auto_promoted_ready + pr_opened_set_in_review + pr_opened_set_in_progress_fallback + pr_merged_set_done
  = (status transitions written this run for items already on the board)
```

The single emitted `set_ready` summary key counts `added_ready` outcomes only; the `set_in_review` summary key counts both `added_in_review` (normal-run adds) **and** `pr_opened_set_in_review` (lifecycle transitions). Consumers who need to disaggregate label-driven vs lifecycle-driven In review can group by `outcome` in the `results` array. `auto_promoted_ready` is a separate counter and is **not** part of the normal-run add total — autonomous promotions act on already-on-board items.

There is no `pr_label_removed` counter — the skill never removes the label.

### New `outcome` values

| Value | When |
|---|---|
| `added_ready` | `status:ready` resolved; `item-edit` ok (manual mode or operator-set label) |
| `added_ready_edit_failed` | `status:ready` resolved; `item-edit` failed; `needs_status_retry: true` |
| `added_in_review` | `status:in-review` resolved; `item-edit` ok |
| `added_in_review_edit_failed` | `status:in-review` resolved; `item-edit` failed; `needs_status_retry: true` |
| `auto_promoted_ready` | `ready_queue_mode == "autonomous"`: `auto_promote_to_ready()` returned True; the skill wrote `Ready` without a `status:ready` label being present. Only emitted in autonomous mode. |
| `auto_promoted_ready_edit_failed` | Same shape with `item-edit` failure; `needs_status_retry: true` |
| `pr_opened_set_in_review` | `sync-lifecycle` / `--from-webhook`: governing PR is open; Status set to `In review`. Supersedes v2.0's `pr_opened_set_in_progress` when `options.in_review` is present. |
| `pr_opened_set_in_progress_fallback` | `sync-lifecycle` / `--from-webhook`: governing PR is open, but `options.in_review` is absent; Status set to `In Progress` (v2.0 fallback). |

The PR-label mutation is **not** an `outcome` value. The label action is fully and exclusively encoded by the row-level `pr_label_action` field (see "PR-label row encoding" below). The `outcome` field continues to encode only the Status-transition signal. A row whose linked open PR triggered a label stamp will have `outcome` set to the Status-transition outcome (e.g. `pr_opened_set_in_review`) AND `pr_label_action: "added"` — both encodings coexist on the same row, but `outcome` itself is never set to a label-action value.

### PR-label row encoding

Two row-level fields document the label mutation, in addition to the existing `outcome`:

| Field | Type | Nullability |
|---|---|---|
| `pr_label_action` | `["string", "null"]` | `"added"`, `"failed"`, or `null` (no label action in this run; e.g. issue with no linked open PR). `"removed"` is NOT a valid value — the skill never removes the label. The skill emits `"added"` for **every** successful `gh issue edit --add-label` call regardless of whether the label was already present on the issue — `gh issue edit --add-label` is idempotent at the GitHub API level (it returns success when the label is already present), and the skill does NOT issue a pre-call `gh issue view --json labels` to distinguish the two cases (Hard Guarantee 3 prohibits label-read calls from this hot path). Operators wanting a precise "was this label newly stamped vs already present" distinction can grep the issue event timeline via `gh api`. |
| `pr_label_error` | `["string", "null"]` | First line of `gh issue edit` stderr when `pr_label_action == "failed"`; null otherwise |

Adding the `PR` label is a side-effect of the open-PR detection in `sync-lifecycle` / `--from-webhook` — it does **not** change the `outcome` value. `pr_label_action` is the **single** authoritative encoding of the label mutation; `pr_label_added` is **not** a member of the `outcome` enum. A failed label call does NOT mark `needs_status_retry: true`; the Status flip is the canonical board signal, and the label is durable metadata. Once stamped, the label is a historical fact about the issue and the skill leaves it alone forever — operators who want to remove it for any reason do so manually via the issue UI or `gh issue edit --remove-label`.

### Existing per-row keys unchanged

`project_item_id`, `final_status`, `needs_status_retry`, `cli_command`, `error`, `labels`, `linked_pr_url`, `linked_pr_state` — all retain v2.6 shape. `final_status` accepts the new strings `"Ready"` and `"In review"`.

## Routing Logic (`resolve_status_label`)

Extends v1.2.0 with two entries in `STATUS_MAP` and `PRIORITY`:

```python
STATUS_MAP = {
    "status:todo":        ("Todo",        None),         # no edit needed
    "status:ready":       ("Ready",       "ready"),      # NEW in v2.7
    "status:in-progress": ("In Progress", "in_progress"),
    "status:in-review":   ("In review",   "in_review"),  # NEW in v2.7
    "status:blocked":     ("Blocked",     "blocked"),
    "status:done":        ("Done",        "done"),
}

# Priority for multi-label collision (D2 v2.7). Reading the column as a workflow:
# blocked is most operationally urgent (must not be silently dropped); done > in-review >
# in-progress > ready > todo keeps a finished/late-stage item from regressing to earlier
# columns when a stale label survives a relabel.
PRIORITY = ["status:blocked", "status:done", "status:in-review",
            "status:in-progress", "status:ready", "status:todo"]
```

### Ready-queue ownership mode (D10)

`Ready` is the **handoff queue between user and orchestrator**. Issues land in `Ready` when they are scoped, triaged, and ready for an orchestrator to pick up. The skill supports two ownership modes via a new optional config key `ready_queue_mode`:

| Mode | Who promotes Todo → Ready | When |
|---|---|---|
| `"manual"` (default) | The user, via UI or via setting `status:ready` in `created-issues.json` | The skill never auto-promotes a `Todo` item to `Ready`. The `Ready` column is strictly user-driven. |
| `"autonomous"` | The skill itself, applying the auto-promotion rule below | Items not currently `Blocked`, not `In progress`/`In review`/`Done`, not awaiting human decision (no `needs-human-review` label), and not carrying any explicit `status:*` label → promoted to `Ready` on every normal-run pass. The user can always demote back to `Todo` manually; the skill respects the v1 "never overwrite externally changed Status" guarantee. |

Auto-promotion rule (autonomous mode only):

```python
def auto_promote_to_ready(issue_labels: list[str], current_board_status: str | None) -> bool:
    """Return True when an item should be auto-promoted Todo → Ready in autonomous mode."""
    # Hard guards: never override an externally-set non-Todo Status (v1 hard guarantee, narrowed for autonomous mode).
    # NOTE: this passes for current_board_status in (None, "Todo"). A human who manually
    # drags a card from Ready → Todo will be re-promoted on the next autonomous run unless
    # an explicit signal label is added. See the "Manual-demote escape hatch" note below.
    if current_board_status not in (None, "Todo"):
        return False
    # Skip if the issue carries any explicit status:* label — that label is the user's intent.
    if any(l.startswith("status:") for l in issue_labels):
        return False
    # Skip if the issue is flagged for human review.
    if "needs-human-review" in issue_labels:
        return False
    # Skip if blocked by dependency labels (e.g. `blocked-by:#42`).
    if any(l.startswith("blocked-by:") for l in issue_labels):
        return False
    # Skip if the operator has explicitly opted this issue out of auto-promotion.
    if "hold-in-todo" in issue_labels:
        return False
    return True
```

**Manual-demote escape hatch.** Autonomous mode cannot distinguish between a never-touched `Todo` and a human-demoted `Todo` from board state alone. Operators who need to keep a specific item at `Todo` without auto-promotion must add one of these signal labels: `status:todo` (explicit user intent — wins over auto-promotion), `needs-human-review` (flag for human decision), `hold-in-todo` (v2.7-introduced opt-out marker recognized by `auto_promote_to_ready()`), or any `blocked-by:*` label. This is a known constraint of autonomous mode and is documented in §Migration Note 9.

**Call-site dispatch (sync-process.md step 4).** The auto-promotion check is dispatched **after** `resolve_status_label()` returns `(None, None)` for an issue with no status label, and **before** the item-edit branch:

```python
# Inside the step-4 loop, per-issue, after item-add ok:
status_name, option_key = resolve_status_label(issue["labels"])
if status_name is None and ready_queue_mode == "autonomous":
    current = snapshot.get(issue["number"], {}).get("status")  # None if new-add, else cached value
    if auto_promote_to_ready(issue["labels"], current):
        status_name, option_key = ("Ready", "ready")
        # Emit auto-promote log line and prepare auto_promoted_ready outcome.
    else:
        log_skip_reason(issue, current)  # emits [issue-to-project:auto] skip line with reason code
# else: manual mode OR label-driven routing — proceed as v2.6.

if status_name is None:
    # No promotion, no label match → left at project default (Todo).
    outcome = "added_default"
    summary["left_default"] += 1
else:
    # Existing v1.0 item-edit path; outcome is one of added_*, added_*_edit_failed, auto_promoted_ready, auto_promoted_ready_edit_failed.
    ...
```

Autonomous-mode evaluations that return False emit `outcome: "added_default"` (no behavioral change vs manual mode for skipped items) and increment `left_default`. Each False return ALSO emits an `[issue-to-project:auto]` skip line so operators can grep for the rejection reason.

When `auto_promote_to_ready()` returns True, the skill emits `outcome: "auto_promoted_ready"` (new in v2.7), writes the `Ready` Status, and adds a clear log line:

```text
[issue-to-project:auto] issue #N: auto-promoted Todo → Ready (autonomous mode; no human signals on issue)
```

Autonomous-mode promotions are surfaced in the new R1 sentinel key `auto_promoted_ready` (integer count). Operators can audit by greping `project-sync.json` for `outcome: "auto_promoted_ready"`.

**Manual-mode invariant.** When `ready_queue_mode == "manual"`, the skill NEVER writes `Ready` autonomously. The only paths into `Ready` are:

1. A `status:ready` label in `created-issues.json` (operator-set).
2. A user moving the card on the UI.
3. A `reconcile --repair-aggressive` run that brings the board in line with a `status:ready` label.

This invariant gives manual-mode operators the same control over `Ready` as v1.2 gives over `Blocked`.

### Behavior changes vs v1.2.0

| Input labels | v1.2.0 outcome | v2.7.0 outcome |
|---|---|---|
| `["status:ready"]` | `added_default` + WARN unknown | `added_ready` (when `options.ready` present) OR `added_default` + WARN (when absent) |
| `["status:in-review"]` | `added_default` + WARN unknown | `added_in_review` (when `options.in_review` present) OR `added_default` + WARN |
| `["status:ready", "status:blocked"]` | `added_blocked` + WARN collision | `added_blocked` + WARN collision (priority unchanged for blocked) |
| `["status:in-review", "status:in-progress"]` | `added_in_progress` + WARN unknown for in-review | `added_in_review` + WARN collision (in-review wins over in-progress) |
| `["status:done", "status:in-review"]` | `added_done` + WARN unknown | `added_done` + WARN collision (done wins) |

The collision-priority change for the `in-review × in-progress` and `in-review × ready` cases is the **only behavioral regression** for v1.2.0 consumers that were already manually adding `status:in-review` labels and relying on the v1.2 silent-fallback-to-Todo behavior. v2.7.0 migration note (below) calls this out explicitly.

### `options.*` resolution branch

When `STATUS_MAP[lbl][1]` resolves to a key absent from `gp["options"]` (e.g. `options.ready` missing on a v1.0–v2.6 config), emit:

```text
[issue-to-project] WARN: status label 'status:ready' resolved to option 'ready' but options.ready is absent from .claude/config.json — leaving at project default (Todo). Re-run 'issue-to-project --init' to cache the optional Status options.
```

…and fall through to `added_default`. This makes v2.7 strictly forward-compatible — operators upgrade the skill first, then re-run `--init` at their leisure to enable the new routes.

## Argv & flag contract

No new flags, env vars, or subcommands. Backward-compatible.

## Error Handling

All v2.6 error rows are unchanged. New rows for the new outcomes:

| Failure mode | When | Severity | Action |
|---|---|---|---|
| `item-edit` to `Ready` failed after `item-add` ok | Step 4 | **Soft-warn** | Record `outcome: "added_ready_edit_failed"`, `needs_status_retry: true`, `final_status: "Todo"`, error string. `[issue-to-project] WARN: issue #N: status edit to 'Ready' failed after add: <error>. Item is on board at default Status. Re-run will NOT retry this edit (idempotency contract). Recovery: 'issue-to-project --retry-blocked-edits'.` |
| `item-edit` to `In review` failed after `item-add` ok | Step 4 | **Soft-warn** | Same shape as above with `"In review"`. |
| `options.ready` absent when `status:ready` resolves | Step 4 routing | **Soft-warn + fallback** | Record `outcome: "added_default"`, log message above, continue. Does NOT block the run. |
| `options.in_review` absent when `status:in-review` resolves | Step 4 routing | **Soft-warn + fallback** | Same shape. |

All four `*_edit_failed` outcomes from v1.2.0 plus the two new ones flow through the same `--retry-blocked-edits` path.

## Cross-cutting

### HALT codes

No new codes. All v1.0.0–v2.6.0 HALT codes are immutable.

### Logging

Same `[issue-to-project]` prefix convention for all manual-mode and label-driven paths. **In autonomous mode (D10), auto-promotion decisions use the new `[issue-to-project:auto]` prefix** — both successful promotions (`auto-promoted Todo → Ready`) and skipped evaluations (with a reason code: `status_label_present`, `needs_human_review`, `blocked_by_label_present`, `current_status_not_promotable`). The `:auto` prefix is reserved for inference decisions made by the skill without an explicit user-set signal; it is the only new prefix introduced in v2.7, and it is gated entirely behind `ready_queue_mode == "autonomous"` (so manual-mode operators see no `:auto` prefix lines at all). PR-label stamping uses the bare `[issue-to-project]` prefix because the trigger (an open PR linked to the issue) is explicit, not inferred.

### Idempotency contract

The v1 re-run guard (step 3 snapshot) continues to exempt already-on-board items from status writes in **manual mode**. The precedence rule from `sync-lifecycle` (D5 v2.0) continues to apply only to the PR-driven Statuses (`In Progress`, `In review`, `Done`, plus skipping when externally set); `Ready` and `In review` are operator-set labels and `Ready` has no PR-event sink in this version (O4).

**Amendment for autonomous mode (D10).** When `ready_queue_mode == "autonomous"`, items in the step-3 snapshot whose `current_board_status == "Todo"` are **not** exempted from the status-write path — `auto_promote_to_ready()` may write `Ready` over `Todo`. This is the **only** narrowing of the v1 re-run guard in v2.7. The hard guarantee that the skill never overwrites an **externally non-Todo** Status is preserved: items at `Ready`, `In progress`, `Blocked`, `In review`, or `Done` are still skipped, and the SKILL.md NEVER section is updated to reflect this narrowing explicitly. Manual mode is unchanged from v1.

## Return Format (R1)

New keys added to the R1 sentinel; v1 keys retained unchanged.

**Normal-run shape (v2.7):**

```text
RESULT: {"status":"ok","slug":"...","artifact_path":"...","issues_in_input":12,"already_on_board":3,"added":9,"set_todo":1,"set_ready":1,"set_in_progress":2,"set_in_review":2,"set_blocked":2,"set_done":1,"auto_promoted_ready":0,"pr_label_added":0,"pr_label_failed":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"ready_queue_mode":"manual"}
```

`set_ready` and `set_in_review` slot into the existing `set_*` count series. `auto_promoted_ready`, `pr_label_added`, and `pr_label_failed` are new top-level counters that always appear with at least `0` (so orchestrators reading by key get a defined value in manual mode and outside lifecycle paths). `ready_queue_mode` echoes the active config value so orchestrators can branch on it without re-reading config. Parsers that read by exact key match (`result["set_blocked"]`) are unaffected; parsers that iterate `set_*` keys see the new keys automatically.

`status` semantics unchanged: `"ok"`, `"partial"` (any `*_edit_failed` > 0), `"failed"`.

## Decisions

**D1 — Hard-coded routing extension over config-declared table**
Decided: extend `STATUS_MAP` and `PRIORITY` constants directly; no `routing_table` config block.
Rationale: (1) The six Status names (`Todo`, `Ready`, `In progress`, `Blocked`, `In review`, `Done`) cover GitHub's recommended Status surface — extending the constants is a one-time change. (2) A config-declared table introduces a routing-shape validation surface; the cost is disproportionate to the value for a single option pair. (3) Defer the generalized table to v3.0 alongside localization (O2).
Alternatives rejected: (a) config-declared `routing_table` map — over-engineering for two labels; (b) skip `In review` and only ship `Ready` — same gap reappears one column over; the two columns belong together on every modern Projects v2 template.
Implications: any future Status column not in this v2.7 set requires another skill version. Acceptable since the v2.7 set covers the GitHub default.

**D2 — Collision priority: blocked > done > in-review > in-progress > ready > todo**
Decided: insert the two new statuses into the existing priority chain at the points that match workflow semantics — `in-review` is a later stage than `in-progress`; `ready` is an earlier stage than `in-progress`.
Rationale: (1) Workflow-aligned priority makes the WARN behavior predictable on collision; (2) `blocked` remains the highest priority because urgency dominates; (3) `done` remains second-highest because finishing is terminal.
Alternatives rejected: (a) alphabetic priority — non-intuitive; (b) define `ready > in-progress` — would let a stale `status:ready` regress an actively-in-progress item to `Ready`; (c) define `in-review > done` — would let a stale `status:in-review` regress a merged-done item to `In review`.
Implications: rare collision sets like `["status:in-review", "status:in-progress"]` resolve to `In review` in v2.7 (vs `In Progress` in v1.2). Migration note (§Migration) calls this out.

**D3 — Two new `options.*` keys are optional**
Decided: `options.ready` and `options.in_review` are NOT in the required-key set; their absence does not abort `--init` or normal-run.
Rationale: (1) Backward-compat: every v1.0.0–v2.6.0 config is valid against v2.7 without re-init; (2) lets the skill route to v1.2's four columns on boards that lack Ready/In review (e.g. existing `zstary/sagibeast/1` test board); (3) the soft-warn + fallback path is consistent with v1.2's "unknown status label" behavior.
Alternatives rejected: (a) require all six options — breaks every existing config; (b) hard-fail when an absent option is needed — punishes operators who haven't re-inited even when no `status:ready` / `status:in-review` labels are in `created-issues.json`.
Implications: operators wanting the new routing must re-run `--init` once. Documented in §Migration.

**D4 — Loud WARN on absent option, fall through to `Todo`**
Decided: when a label resolves to an absent `options.*` key, log a loud WARN with the recovery hint and route to `Todo` via `added_default`.
Rationale: (1) Silent fallback would hide the misconfiguration; (2) hard-fail would block the entire batch on a single missing optional; (3) the explicit `[issue-to-project] WARN: ...` line names the missing key and the fix.
Alternatives rejected: (a) silent fallback — hides the gap; (b) HALT `MALFORMED_CONFIG` — punishes the entire batch.
Implications: re-running the same input after re-init produces a different outcome (no warn; new outcome value). Acceptable per `to-issues` v3.2's at-least-once delivery contract.

**D5 — `schema_version: "2.7"` bump**
Decided: emit `"2.7"`; downstream consumers must accept `schema_version ∈ {"1", "1.1", "1.2", "2", "2.1", "2.2", "2.3", "2.4", "2.5", "2.6", "2.7"}` — relax strict equality to a **major-version comparison** like `int(schema_version.split(".")[0]) >= 1`, which is forward-stable through v3.0 (D5-edge).
Rationale: (1) Consistent with every prior minor bump; (2) lets v2.6 readers detect the schema change and refuse incompatible artifacts cleanly; (3) the additive-only contract continues — no removed keys.
Alternatives rejected: keep `"2.6"` (silent format drift); jump to `"3.0"` (over-bumps a purely additive change).
Implications: documented in §Migration. Downstream tools (`build-create-pr`, future `manage-board`) must extend their schema_version validators.

**D6 — `--retry-blocked-edits` uniformly recovers all v2.7 `*_edit_failed` outcomes**
Decided: extend `RETRY_TARGET` in `retry-process.md` with three new rows for v2.7: `added_ready_edit_failed → ("ready", "Ready")`, `added_in_review_edit_failed → ("in_review", "In review")`, and `auto_promoted_ready_edit_failed → ("ready", "Ready")` (same target as label-driven Ready retry; the autonomous-vs-manual distinction is lost on retry because retry replays the cached `(option_key, option_name)` regardless of original cause).
Rationale: (1) Consistent with v1.2's pattern of routing every `*_edit_failed` outcome through the same retry verb; (2) no new HALT codes or argv surface needed; (3) `auto_promoted_ready_edit_failed` carries `needs_status_retry: true` (per §170-171), so omitting it from `RETRY_TARGET` would silently drop autonomous-mode retry rows.
Alternatives rejected: (a) per-outcome retry sub-flag — unnecessary complexity; (b) automatic in-run retry — risks rate-limit pressure and is inconsistent with v1.1's one-attempt-per-invocation rule; (c) treat `auto_promoted_ready_edit_failed` as non-retryable — would leave autonomous-mode failures unrecoverable except by re-running the whole batch.
Implications: `--retry-blocked-edits` is the canonical recovery path for all **seven** edit-failed outcomes (`added_blocked_edit_failed`, `added_in_progress_edit_failed`, `added_done_edit_failed`, `added_ready_edit_failed`, `added_in_review_edit_failed`, `auto_promoted_ready_edit_failed`, plus the v1.0 `added_default_edit_failed` if extant). The `retry-process.md` `schema_version` acceptance gate (currently `{"1", "1.1", "1.2"}` in shipped file) must also be extended through `'2.7'` — see File-by-File row.

**D7 — `reconcile` gains three new drift cases**
Decided: extend `reconcile-process.md`'s drift case classifier with `label_ready_board_not` (label says Ready, board says something else and is not externally pinned), `label_in_review_board_not`, and `label_pr_drift` (issue has `PR` label but no open linked PR found, or vice-versa). Same severity scaling as v2.2 existing cases.
Rationale: (1) Symmetry with v2.2's existing blocked-drift case; (2) the `PR` label is critical observability signal — a drift makes the board misleading.
Alternatives rejected: roll all into existing `label_blocked_board_not` — semantically distinct.
Implications: `reconcile-report.schema.json` `drift_case` enum gains three values. `--repair-additive` does NOT repair them (additive = sync_gap only). `--repair-aggressive` repairs them when the confirmation gate clears.

**D8 — `pull_request.opened` lifecycle event targets `In review`, not `In Progress` (v2.0 amendment)**
Decided: when `options.in_review` is present in config, the v2.0 `sync-lifecycle` and `--from-webhook` PR-opened transition writes `In review` (outcome `pr_opened_set_in_review`). When `options.in_review` is absent, fall back to the v2.0 behavior (`In Progress`, outcome `pr_opened_set_in_progress_fallback`) with a loud WARN.
Rationale: (1) An open PR semantically means *under review*, not *in progress* — the v2.0 mapping was correct only for four-column boards; (2) backward-compat preserved for v2.6 boards via fallback path; (3) the outcome rename makes audit logs unambiguous about which transition fired.
Alternatives rejected: (a) keep v2.0 always — semantically wrong on six-column boards; (b) require `options.in_review` for v2.7 — breaks v2.6 boards; (c) introduce a config switch for the target — adds surface for no value.
Implications: downstream readers must accept the new `pr_opened_set_in_review` outcome. v2.0's `pr_opened_set_in_progress` is **retired** for new artifacts but remains in the schema enum so old artifacts re-validate.

**D9 — `PR` label stamp on issue when a linked PR is first open; never removed; idempotent via gh's own semantics**
Decided: `sync-lifecycle` and `--from-webhook` call `gh issue edit --add-label <pr_label_name>` when they detect a linked open PR for an issue. The call is issued on **every** detection without a pre-call label-read (Hard Guarantee 3 prohibits label-read in this path) — the GitHub API treats `add-label` as idempotent when the label is already present, returning success and a no-op on the issue. The skill **never removes** the label — not on PR close, not on merge, not on issue close. Label name defaults to `"PR"`. `--init` creates the label in the repo if absent.
Rationale: (1) The label is **durable provenance** — "this issue had a PR" is a permanent historical fact about the issue, valuable in search, notifications, and audits months later; (2) transient "PR is open right now" state is already encoded by Status (`In review` → open; `Done` → merged) and by the board's "Linked pull requests" field — removing the label on close would duplicate signal that already exists elsewhere AND destroy the only durable record; (3) operators searching `is:issue label:PR` get a clean historical list of "issues that produced a PR" — useful for retro / metrics. The non-removal rule combined with gh's add-label idempotency means double-delivery of webhook events is trivially safe (the second call succeeds without mutating).
Alternatives rejected: (a) remove on close/merge — destroys the durable record and offers no benefit over reading Status; (b) write nothing extra and rely on the board "Linked pull requests" field — invisible outside the board view; (c) comment on the issue — creates noise on every PR open; (d) pre-call `gh issue view --json labels` to distinguish "newly added" vs "already present" — violates Hard Guarantee 3, doubles API calls on the hot path, and the distinction is not encoded in the artifact in v2.7 anyway.
Implications: new `pr_label_added` / `pr_label_failed` summary keys (no `pr_label_removed`, no `pr_label_skipped`). `pr_label_action` row-level field has enum `["added", "failed", null]` only — every successful gh call records `"added"` regardless of prior state. A `gh issue edit` add-label failure is soft-warn (does not block the Status flip). Operators who don't want the label set `pr_label_name: ""` (empty string disables all label calls). Operators who want to retroactively remove the label on specific issues do so manually — the skill makes no policy here.

**D10 — `ready_queue_mode` defaults to `"manual"`; `"autonomous"` is explicit opt-in**
Decided: default `ready_queue_mode` is `"manual"`. Autonomous auto-promotion only fires when the operator explicitly sets `"autonomous"` in config (via `--init` prompt or hand-edit).
Rationale: (1) **`Ready` is a handoff signal between user and orchestrator**; defaulting to autonomous would surprise users who expect the column to reflect their own decisions; (2) explicit opt-in matches the v1 philosophy of "skill never overwrites human-driven state by default"; (3) operators who want a fully autonomous orchestrator simply flip the config key once.
Alternatives rejected: (a) always-on autonomous — surprising for manual workflows; (b) per-issue autonomy flag (`autonomous:true` in `created-issues.json`) — adds emission burden on `to-issues`; (c) inferred autonomy from project type — fragile and unobservable.
Implications: the `auto_promote_to_ready()` function is dead code in manual mode (D10-edge: it is never called; the dispatch happens at `ready_queue_mode` read time). Autonomous mode users see `outcome: "auto_promoted_ready"` in the artifact and a `[issue-to-project:auto] issue #N: auto-promoted Todo → Ready` log line — the `:auto` prefix is intentional here because it IS an inference decision (which user/orchestrator philosophy the v1 prefix-rule reserved for).

## Out of Scope

| ID | Item | Why deferred |
|---|---|---|
| O1 | Operator-configurable PRIORITY chain | Adds a config-shape; hard-code is sufficient for the canonical workflow. Revisit when there is a clear demand signal for non-default priority. |
| O2 | Localized Status names (e.g. German `"Erledigt"` → `Done`) | Requires a config-declared name→options.* table. v3.0 will generalize. |
| O3 | `to-issues` emission of `status:ready` and `status:in-review` | This spec is consumer-only. A future `to-issues` PR can add emission rules (e.g. "story has open PR + `code-review` label set" → `status:in-review`). |
| O4 | Lifecycle transitions to `Ready` from PR/issue events | `Ready` is an operator-set "next up" signal. There is no PR/issue event that semantically maps to "ready for pickup." Operators set this label manually OR enable autonomous mode (D10). |
| O5 | `reconcile --repair-additive` repairs the new drift cases | Additive remains its narrow "sync_gap only" contract. Use aggressive mode for label-drift repair. |
| O6 | Renaming the `PR` label globally to something other than what `pr_label_name` allows | The string `"PR"` is the default; operators can override via `pr_label_name`. No further customization beyond per-repo override is in scope. |
| O7 | `--retry-pr-labels` recovery verb for failed label add calls | A failed PR-label add is soft-warn observability only. Re-running `sync-lifecycle` re-attempts the add naturally on the next pass while the PR is still open (and idempotently no-ops via gh's own add-label semantics — see D9 — recording another `pr_label_action: "added"` row). After the PR closes the skill stops touching the label entirely (D9). |
| O8 | Autonomous auto-promotion `Todo → In progress` (orchestrator picks up Ready) | The skill writes Status, not assignments. An orchestrator picking up a Ready item should set `status:in-progress` (or open a PR, which now triggers `In review`). v2.7 leaves Ready → In progress to the orchestrator's own logic. |
| O9 | Per-repo `ready_queue_mode` (different repos in a cross-repo board run different modes) | v2.3's `known_repos` is read-only metadata. v2.7's `ready_queue_mode` is a global per-board setting; per-repo split is deferred to v3.0 alongside O2 localization. |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Update** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version: 2.7.0`. Frontmatter `description:` updated to name `In review` alongside `In Progress`/`Done` in the lifecycle blurb (fixes stale routing claim picked up by Claude's skill-routing). Status routing table gains two rows (`status:ready` → `Ready`, `status:in-review` → `In review`). Hooks list gains `"route status:ready"`, `"route status:in-review"`, and `"autonomous auto-promote (D10, gated by ready_queue_mode)"`. Argv contract unchanged. R1 sentinel example for both normal-run and sync-lifecycle paths updated to include all 5 new summary keys + `ready_queue_mode` echo. NEVER section amended for autonomous-mode narrowing of the v1 re-run guard (D10 + §Idempotency amendment). |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Add `options.ready`, `options.in_review`, `pr_label_name`, and `ready_queue_mode` rows under config keys with "no" Required column. Validation rule 3 notes the new optionals. **New validation rule** covering `pr_label_name`: empty string is valid (sentinel disables label calls); non-empty must match `^[A-Za-z0-9_:.-]+$` (1–50 chars); whitespace-only → HALT `MALFORMED_CONFIG`. **New validation rule** covering `ready_queue_mode`: must be exactly `"manual"` or `"autonomous"` when present. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Step 4 example output captures all six options. Step 5 explicit note that `ready` and `in_review` are not required for `--init` to succeed; their absence emits one INFO line per missing optional. Step 6c (new) — see Config Schema diff for full contract including pre-flight token-scope check. Step 6d (new) — prompts `ready_queue_mode` with **preserve-existing-on-reinit logic**: when the prior config already contains `ready_queue_mode`, default the prompt to that value (pressing Enter keeps the current mode); only on a fresh init does the default fall back to `"manual"`. Same preserve logic applies to `pr_label_name`. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | `STATUS_MAP` extended; `PRIORITY` extended; outcome routing table rows for the four new outcomes; `left_default` semantics statement extended; soft-warn message text. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/retry-process.md` | (a) `RETRY_TARGET` map gains **3** rows: `added_ready_edit_failed → ("ready", "Ready")`, `added_in_review_edit_failed → ("in_review", "In review")`, `auto_promoted_ready_edit_failed → ("ready", "Ready")`. (b) `schema_version` acceptance gate extended to accept all `1.x` and `2.x` values through `'2.7'` — fixes pre-existing v2.1 regression in shipped file (currently `{"1", "1.1", "1.2"}` rejects every v2.0+ artifact). |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/reconcile-process.md` | Drift-case classifier extended with **3** new cases: `label_ready_board_not` (label says Ready, board says something else and is not externally pinned), `label_in_review_board_not` (same shape for In review), `label_pr_drift` (issue has `PR` label but no open linked PR found, or vice-versa). `--repair-aggressive` repair table extended for all three. `repaired_summary` example updated with the new keys. `--repair-additive` does NOT repair them (additive = sync_gap only — O5). |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | `schema_version` enum adds `"2.7"`. `summary` props add **5 new optional integer keys (minimum: 0)**: `set_ready`, `set_in_review`, `auto_promoted_ready`, `pr_label_added`, `pr_label_failed`. `outcome` enum adds **8 new values**: `added_ready`, `added_ready_edit_failed`, `added_in_review`, `added_in_review_edit_failed`, `auto_promoted_ready`, `auto_promoted_ready_edit_failed`, `pr_opened_set_in_review`, `pr_opened_set_in_progress_fallback` (NOT `pr_label_added` — that is a row-level field, not an outcome). `results` item props add **2 new optional fields**: `pr_label_action` (enum `["added", "failed", null]`) and `pr_label_error` (`["string", "null"]`). All new summary keys and per-row fields are OPTIONAL (not in `required`), preserving v2.6 artifact re-validation (consistent with the v2.5 `auto_reinit_log` precedent). `allOf` if/then adds branches for `added_ready_edit_failed`, `added_in_review_edit_failed`, and `auto_promoted_ready_edit_failed` (each requires `needs_status_retry: true`, same shape as v1.2's `added_*_edit_failed` conditionals). `description` updated. |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/reconcile-report.schema.json` | `drift_case` enum adds **3 values**: `label_ready_board_not`, `label_in_review_board_not`, `label_pr_drift`. `summary.by_case` required properties extended with the 3 new keys (`additionalProperties: false` policy preserved). |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/lifecycle-process.md` | (a) Extend `SUPPORTED` set to accept all `1.x` and `2.x` `schema_version` values through `'2.7'` via prefix/version-tuple check — fixes pre-existing v2.1 regression in shipped file (lines 37–46) that already rejects v2.1–v2.6 artifacts. (b) `select_governing_pr()` / PR-opened branch: when `gp.options.in_review` present → write `In review` (outcome `pr_opened_set_in_review`); when absent → write `In Progress` with loud WARN (outcome `pr_opened_set_in_progress_fallback`). (c) Add `gh issue edit --add-label <pr_label_name>` call on open-PR detection — never on close (D9). (d) Add `'In review'` to the WRITTEN_BY_SKILL set so D5 precedence covers v2.7 writes. (e) Define exact fallback WARN text: `"[issue-to-project] WARN: pull_request.opened received but options.in_review is absent — falling back to In Progress. Re-run --init to enable the In review transition."` |
| **Update** | `plugins/makato-plan/skills/issue-to-project/references/webhook-lifecycle.md` | Mirror of lifecycle-process.md changes: SUPPORTED set extended through `'2.7'`; same In-review remap on `pull_request.opened` event; same PR-label stamp on detect-open via `gh issue edit --add-label`; Token setup section updated to require `Issues: Read and write` (PR-label stamp needs `issues:write`); add an init-time pre-flight check / soft-warn when `pr_label_name` is non-empty but the token lacks the scope. |
| **Keep** | `references/field-type-routing.md`, `references/auto-reinit-process.md`, `references/board-audit.md`, `references/board-audit.schema.json` | Unchanged. `sync-lifecycle` still does not write `Ready` autonomously from PR/issue events (O4). |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | New **2.7.0** block under the `issue-to-project` skill section — **≥ 8 bullets** covering each logical change. See the CHANGELOG-bullets list immediately below this table for the required nine bullets. |

**CHANGELOG-bullets** (referenced from the table above — each is one bullet under the v2.7.0 block):

1. `Ready` + `In review` routing.
2. PR-open lifecycle remap → `In review` + fallback outcome.
3. `PR` label stamp (permanent, never removed).
4. `ready_queue_mode` config + autonomous auto-promotion.
5. `pr_label_name` config + empty-string disable sentinel.
6. Reconcile drift cases gain `label_ready_board_not` / `label_in_review_board_not` / `label_pr_drift`.
7. Schema bumps to `"2.7"` with 8 new outcomes + 5 new optional summary keys + 2 new optional per-row fields.
8. `lifecycle-process.md` + `webhook-lifecycle.md` + `retry-process.md` `SUPPORTED` / `schema_version` gate extensions through `"2.7"` (fixes pre-existing v2.1 regression).
9. `[issue-to-project:auto]` log prefix introduced (autonomous mode only).

## Testing Strategy

Static + dry-run + one live smoke against `macatocz/sagibeast` (the trigger board — owner-org rename of zstary's org, configured with all six Status options) and one against `zstary/sagibeast` (the four-option legacy board, used to prove backward compatibility with v1.0–v2.6 configs) — to prove forward + backward compatibility. The two boards live in different organizations; smoke-test repro requires the operator to have edit access to both, or to substitute equivalent boards under their own org.

| Test | What it covers | How |
|---|---|---|
| Frontmatter parse | `version: 2.7.0`, required keys | `head -22 SKILL.md` |
| Schema files valid | `project-sync.schema.json` and `reconcile-report.schema.json` parse as draft-07; new enum values present | `python3 -c "import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(...)))"` |
| `STATUS_MAP` test — Ready | Synthetic `created-issues.json` with `labels: ["status:ready"]`; dry-run; assert `outcome: "added_ready"` and `cli_command` shows option-id resolution against `options.ready` | Manual dry-run |
| `STATUS_MAP` test — In review | Same shape for `status:in-review` | Manual dry-run |
| Optional-option fallback | Use a v2.6 config (no `options.ready`); run with `status:ready` label; assert `outcome: "added_default"` and WARN line on stderr | Manual dry-run |
| Collision priority — in-review beats in-progress | Labels `["status:in-review", "status:in-progress"]`; assert resolves to `In review` with collision WARN listing both | Static `resolve_status_label()` invocation |
| Collision priority — blocked still wins | Labels `["status:blocked", "status:ready"]`; assert resolves to `Blocked` | Static |
| Schema-valid artifact emission | Synthetic 6-row run produces a v2.7 artifact that re-validates | Round-trip in Python |
| `--retry-blocked-edits` covers new outcomes | Hand-author a prior artifact with `added_ready_edit_failed` and `added_in_review_edit_failed` rows; run retry verb dry-run; assert both rows route through `RETRY_TARGET` lookup and emit `outcome: "dry_run"` with the correct `--single-select-option-id` | Static |
| Live smoke 1 (six-option board) | Create one issue per Status label on `macatocz/sagibeast`; run skill; verify each board card lands in the expected column | Manual |
| Live smoke 2 (four-option board, backward compat) | Re-run an existing v1.0–v1.2 created-issues.json against `zstary/sagibeast/1`; assert behavior is byte-for-byte identical (no new outcomes emitted) | Manual |

## Migration Notes

**For existing `issue-to-project` consumers (v1.0.0–v2.6.0):**

1. **No-op upgrade path with observable degradation.** A v2.7 skill reading a v2.6 config continues to work for Status routing. `status:ready` / `status:in-review` labels in `created-issues.json` route to `Todo` with a WARN (same behavior as any v2.6 "unknown status label"). `pr_label_name` defaults to `"PR"`; `ready_queue_mode` defaults to `"manual"` so no auto-promotion fires. **However:** because `pr_label_name` defaults to `"PR"` and the `--init` Step 6c that creates the repo label has not been run on a v2.6 config, every `sync-lifecycle` / `--from-webhook` run that detects a linked open PR will attempt `gh issue edit --add-label PR` against a non-existent repo label and emit `pr_label_failed > 0` with `pr_label_action: "failed"` per row. This is soft-warn (does not HALT) but is observable in audit and in stderr until the operator re-runs `--init` (which creates the label in Step 6c) OR sets `pr_label_name: ""` to disable the feature.
2. **Opt-in path.** Re-run `issue-to-project --init` once — it captures all six `options.*` keys automatically, creates the `PR` repo label (Step 6c), and prompts for `ready_queue_mode` (Step 6d). After re-init, the full v2.7 surface is active.
3. **Behavior changes for `status:in-review` and `status:ready` labels.** These are the **primary behavioral regressions** v1.2 → v2.7. (a) **Single-label case**: an issue carrying only `["status:in-review"]` routed to `Todo` + WARN in v1.2 (unknown label silent fallback). In v2.7 with `options.in_review` present, it routes to `In review`. The same shape applies to `["status:ready"]` → `Ready`. (b) **Collision case**: in v1.2 the unknown `status:in-review` label silently fell through to `Todo`, and `status:in-progress` was the only known label, so the item routed to `In Progress`. In v2.7.0, `status:in-review` becomes a known label and wins the collision (priority `in-review > in-progress`). Operators who were relying on the v1.2 silent-fallback should pre-filter `status:in-review` and `status:ready` in `to-issues` if they want the old behavior, or simply not configure `options.in_review` / `options.ready` (the absent-option fall-through to `Todo` matches v1.2 behavior).
4. **v2.0 outcome rename for PR-opened transitions.** v2.0's `pr_opened_set_in_progress` is **retired for new artifacts** when `options.in_review` is present in config; the skill writes `pr_opened_set_in_review` instead. The old outcome string remains in the schema enum (existing v2.0–v2.6 artifacts re-validate) but `sync-lifecycle` v2.7+ no longer emits it for the open-PR path. v2.6 configs without `options.in_review` keep the v2.0 behavior via the explicit `pr_opened_set_in_progress_fallback` outcome.
5. **`schema_version: "2.7"`.** Downstream consumers parsing `project-sync.json` must accept the new value. Strict equality (`== "2.6"`) breaks. **Recommended forward-stable pattern**: `int(schema_version.split(".")[0]) >= 1` (accepts every shipped + future major); avoid `startswith("1") or startswith("2")` because it will silently refuse v3.0 artifacts. The shipped `lifecycle-process.md` SUPPORTED set should likewise migrate to a major-version comparison, and v2.7 picks up the gate-extension in the §File-by-File row.
6. **`outcome` enum extension.** Strict-enum validators must extend their allow-list with **8 new values**: `added_ready`, `added_ready_edit_failed`, `added_in_review`, `added_in_review_edit_failed`, `auto_promoted_ready`, `auto_promoted_ready_edit_failed`, `pr_opened_set_in_review`, `pr_opened_set_in_progress_fallback`. **`pr_label_added` is NOT in the outcome enum** — the label action is encoded exclusively via the row-level `pr_label_action` field. There is no `pr_label_removed` outcome value — the skill never removes the label.
7. **`summary` keys.** Five new integer keys (`set_ready`, `set_in_review`, `auto_promoted_ready`, `pr_label_added`, `pr_label_failed`) are additive and **declared optional** in the v2.7 schema (not in `required`). Existing parsers that read by key name are unaffected. Existing v2.6 artifacts re-validate against v2.7 (consistent with the v2.5 `auto_reinit_log` precedent for optional schema growth). There is intentionally no `pr_label_removed` counter — the skill never removes the `PR` label (D9).
8. **`PR` repo label is permanent.** Once stamped, the label stays on the issue forever — it is a durable historical record that a PR existed for the issue. Operators who don't want the label can set `pr_label_name: ""` (empty string disables all label calls) before running `--init`. Operators who want to retroactively remove the label on specific issues do so manually.
9. **`ready_queue_mode` decision matters and is reversible only with manual audit.** Default `"manual"` matches v1.0–v2.6 behavior (Ready column is operator-driven). Operators running fully autonomous orchestrators set `"autonomous"` once and the skill takes over Todo → Ready promotion for unflagged issues. **Reverting from `autonomous` to `manual`:** items already auto-promoted to `Ready` remain there — the skill does NOT demote them on mode change. To audit which items were auto-promoted vs human-promoted, grep prior `project-sync.json` artifacts for `outcome: "auto_promoted_ready"`; to demote en masse, use the UI or `gh project item-edit --single-select-option-id $options.todo`. **Operator opt-out for specific issues in autonomous mode:** add `status:todo`, `needs-human-review`, `hold-in-todo`, or any `blocked-by:*` label — `auto_promote_to_ready()` skips them.
10. **No new HALT codes.** Existing error-handling code paths are unchanged. `MALFORMED_CONFIG` covers invalid `ready_queue_mode` and invalid `pr_label_name` values.

11. **`pr_label_name` rename has no automated backfill.** Renaming the config key (e.g. from `"PR"` to `"has-pr"`) after issues have already been stamped causes the board to carry **two disjoint label sets** — issues stamped under the old name retain it permanently (D9 never-remove rule), and issues stamped after the rename get the new label. The skill provides no automated relabel procedure. Operators wanting a uniform label across all issues run a manual one-shot: `gh issue list --label "PR" --json number --jq '.[].number' | xargs -I{} gh issue edit {} --remove-label "PR" --add-label "has-pr"`. `reconcile --repair-aggressive` does NOT bulk-relabel for renames — `label_pr_drift` covers presence/absence mismatch against current `pr_label_name`, not migration between names. Recommendation: settle `pr_label_name` before the first `sync-lifecycle` run that stamps any label.

12. **v2.7 → v2.6 rollback is a manual recovery, not a supported reversal.** The v2.7 artifact (`schema_version: "2.7"`, `pr_label_*` per-row fields, 5 new summary keys) is not consumable by a v2.6 skill — the v2.6 `lifecycle-process.md` SUPPORTED set is `{"1", "1.1", "1.2", "2"}`, the v2.6 schema's `additionalProperties: false` rejects unknown summary keys and per-row fields, and v2.6's config-schema validator may reject the new `pr_label_name` / `ready_queue_mode` keys. Rollback procedure: (a) hand-edit `project-sync.json` artifacts: lower `schema_version` to `"2"` and drop the 5 new summary keys + 2 new per-row fields, OR delete the artifacts and let v2.6 emit fresh ones; (b) remove `pr_label_name` and `ready_queue_mode` from `.claude/config.json` if v2.6's validator rejects them; (c) the permanent `PR` repo label remains on stamped issues — the skill cannot un-stamp; operators wanting cleanup run the bulk-remove `gh issue list --label PR --json number --jq '.[].number' | xargs -I{} gh issue edit {} --remove-label PR`. Recommendation: treat v2.7 as one-way once any artifact has been emitted or any label stamped.

**For downstream skills (`build-create-pr` or similar):** the v2.7 artifact is a strict superset of v2.6. All v2.6 keys exist with the same types. The eight new outcome values can be ignored by v2.6 consumers (they'll see them as unknown enum members on strict validators — relax the validator as above). **Note:** `build-create-pr` itself reads `created-issues.json`, not `project-sync.json`, so its existing validator path is unaffected by the v2.7 schema bump; the D5 warning to "downstream tools" applies primarily to orchestrators and to a future `manage-board` skill, not to `build-create-pr` directly.

**For orchestrators consuming the `sync-lifecycle` R1 sentinel:** prior to v2.7, an orchestrator could sum `set_in_progress + set_done` to count "PRs processed this lifecycle run". In v2.7 with `options.in_review` configured, PR-opened transitions write `In review` instead — the correct aggregate is `set_in_progress + set_in_review + set_done` (still counting all three; the rename only shifts where in the count series the opened-PR contributions land). Orchestrators that hardcoded the v2.6 pair will undercount post-v2.7 runs. Recommended migration: switch to either summing all `set_*` keys via iteration, or filter `results` by `outcome ∈ {pr_opened_set_in_review, pr_opened_set_in_progress_fallback, pr_merged_set_done}` for precise counts.

**For orchestrators consuming the board:** the canonical "pick up next task" query becomes `Status = Ready` (in either mode). In autonomous mode, the orchestrator pulls items the skill auto-promoted. In manual mode, the orchestrator pulls items a human explicitly promoted. The orchestrator's responsibility on pickup is to set `status:in-progress` (or to open a PR, which `sync-lifecycle` will flip to `In review`).
