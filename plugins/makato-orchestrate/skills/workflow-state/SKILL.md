---
name: workflow-state
description: >-
  Read and write PO-agent resumable session state at
  `specs/<key>-<slug>/workflow-state-<issue>.json`. Per-issue file layout
  (#173) — multiple GitHub issues can share a story-level spec folder without
  clobbering each other's audit trails. Provides nine subcommands
  (init / read / write / patch / append-lesson / append-halt /
  bump-structural-halt / recall-lessons / summarise-lessons) via
  `shared/workflow-state.sh`,
  backed by a JSON Schema draft-07 contract. PO-agent (GAP-006 / #32) is
  the sole writer in production. Use when you need a resumable overlay
  over `build.jsonl` — the audit log captures forensics, this skill
  captures live loop state (sub-task graph, current phase, budget, HALT
  audit, structured lessons learned).
version: "1.7.1"
argument-hint: "<subcommand> <key|repo> [<issue>] [args…]"
allowed-tools: []
---

<!-- markdownlint-disable MD013 -->

# workflow-state

## When to Use

Use **only** from:

1. The PO-agent outer loop (GAP-006 / #32) — sole writer in steady state.
2. The session-status hook (GAP-007 / follow-up) — read-only at session start.
3. `build-implement-tdd`'s narrow guarded patch on task completion (see *Cross-plugin caller* below).

Do **not** call from sub-agents (`coder`, `diff-reviewer`, `gate-scout`, `plan-analyst`, etc.). Sub-agents return R1 envelopes; the PO-agent translates those into state patches. Concurrent writes are a design failure, not a race to manage.

## Anti-patterns

### NEVER use `patch .halt_audit` directly — use `append-halt`

**WHY:** Open-coded `read → jq '. + [entry]' → write` bypasses the HALT-code format validation (`HALT-NNN[A-Z]` / `HALT-STRUCTURAL` enum check) and the required-keys check on the entry object. A malformed code silently lands in the audit; the next `append-halt` call then rejects the array with `HALT: INVALID_STATE` because the pre-existing entry fails schema re-validation. Debugging traces back to the original silent corruption, not the failing call.

### NEVER write partial JSON via `write` to update a subset of fields

**WHY:** `write` validates then atomically overwrites the entire file. A partial JSON blob that passes schema validation (all required fields present, all optional fields absent) silently drops every field the caller omitted — `lessons_learned`, `halt_audit`, `sub_tasks` arrays, `github_pr_number`, `structural_halt_cycles`. There is no diff or merge: the file is replaced wholesale. Every unset optional field reverts to its default. Use `patch` for any update that touches fewer than the full document.

### NEVER call from two agents concurrently — not even "just reads" followed by a patch

**WHY:** The read → validate → atomic-overwrite path in `patch` has a TOCTOU window. Two agents that each read the same state file, compute an update, and race to write will produce last-write-wins JSON clobber — the slower write discards the faster write's mutation entirely. This is not a race the helper can manage; it is a design failure. The result on the next read is `HALT: INVALID_STATE` if the winner's write dropped a required field, or silent data loss if it dropped only optional data (e.g. a `halt_audit` entry appended by the loser).

### NEVER use `write` with a path derived from `pwd` — use `git rev-parse --show-toplevel`

**WHY:** `workflow-state.sh` resolves `specs/<key>-*/` from the repo root. A caller that constructs the checkpoint path from `pwd` (e.g. inside a worktree or a sub-directory) resolves to the wrong directory, writes to a stale or nonexistent path, and the helper on the next read silently returns `{}` (missing-file behavior) — the issue resumes from a blank state as if `init` were never called.

### NEVER reset `structural_halt_cycles` on a HALT-007B handoff

**WHY:** This counter is specifically designed to be durable across context handoffs. It measures cross-run recurrence of structural failure on the same issue — the property epic #319's AC-epic-1 needs to detect "repeated" structural HALT and trigger the Needs Planning signal (#348). A handoff that resets it causes the Needs Planning signal to never fire on an issue that repeatedly hits structural failures across sessions.

### NEVER call `bump-structural-halt` with non-structural codes expecting a counter increment

**WHY:** HALT-007, HALT-007B, and HALT-008 with `origin=ci_failure` or `origin=merge_conflict` are explicitly documented no-ops. The command exits 0 with no counter change and no error. Callers that do not read the printed counter value and assume an increment occurred will under-count structural recurrence, making epic #319's detection threshold unreachable.

## Schema Reference

The full contract lives at @references/workflow-state.schema.json (draft-07, `additionalProperties: false` at top level).

On CI-repair cutover, PO-agent reads the full existing state, removes only
`flake_rerun_pending` via `jq 'del(.flake_rerun_pending)'`, and calls
`write` with that complete document before any patch/resume acknowledgement.
This one-time schema migration preserves all other fields and remains subject
to normal validation; never reintroduce the obsolete flake probe.
Load MANDATORY when: modifying `workflow-state.sh`, adding a new top-level field, or writing a new HALT-audit shape.
Do NOT Load unless you need to inspect the field-level JSON Schema constraints (the table below covers all caller needs).

Top-level fields:

| Field | Type | Notes |
|-------|------|-------|
| `repo` | string | `owner/name` form |
| `branch` | string | feature branch name |
| `worktree_path` | string \| null | absolute path to worktree, null if main checkout (managed by `shared/worktree.sh` per GAP-017 / #46) |
| `worktree_retained` | boolean | true when the worktree was retained after a HALT (GAP-017 / #46); set by `worktree.sh retain` |
| `worktree_retain_reason` | string \| null | reason marker paired with `worktree_retained` — typically a HALT code (e.g. `HALT-003`) or a free-form marker (`merge_conflict`) |
| `issue_number` | integer ≥ 1 | GitHub Issue number |
| `sub_tasks` | array | ordered; see *sub_tasks shape* |
| `current_phase` | string \| null | `refine` \| `implement` \| `verify` \| `pr` \| `done` |
| `resume_point` | string \| null | Resume hint; `ci-poll` re-enters the shared CI gate for the saved PR, never PR creation. |
| `budget_consumed_tokens` | integer ≥ 0 | cumulative; updated after each dispatch; never reset (HALT-007 cost ceilings evaluate this total) |
| `session_baseline_tokens` | integer ≥ 0 | `budget_consumed_tokens` at the current session's start (#281); HALT-007B evaluates the delta `consumed - baseline` and sets this to `consumed` on each handoff so a resumed session's context budget restarts at 0. Optional for pre-#281 in-flight state (readers default 0) |
| `budget_limit_tokens` | integer ≥ 1 | HALT-007 fires at ceiling (cost control) |
| `context_warn_tokens` | integer ≥ 1 | HALT-007B fires when the session delta reaches this threshold (quality control; default 150000) |
| `outer_iteration` | integer ≥ 0 | HALT-008 fires at 3 |
| `merge_conflict_cycles` | integer ≥ 0 | count of merge-conflict resolution attempts; HALT-008 fires independently at `MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3) |
| `ci_failure_cycles` | integer ≥ 0 | PO-agent mirror of `build-fix-ci` R1 `repair_cycles`; polling does not consume repairs. `MAKATO_MAX_CI_FAILURE_CYCLES=0` disables an arbitrary cap; a positive operator limit is enforced by the CI coordinator. |
| `structural_halt_cycles` | integer ≥ 0 | **durable cross-run** count of PO-agent runs on this issue that terminated on a structural HALT (#347, epic #319) — HALT-003, HALT-STRUCTURAL, HALT-010, HALT-008/origin=outer_iteration. Distinct from `outer_iteration` (within-run); never reset on a HALT-007B handoff. Written only via `bump-structural-halt`. Optional for pre-#347 in-flight state (readers default 0) |
| `halt_audit` | array | append-only; see *halt_audit shape* |
| `human_review_cycles` | integer ≥ 0 | count of `needs-human-review` labellings |
| `github_pr_number` | integer \| null | Persist as soon as a PR exists, including when its subsequent CI gate returns non-success. |
| `lessons_learned` | array | append-only; see *lessons_learned shape* |
| `session_summary` | string \| null | ≤ 500-token handoff payload from context-summariser (GAP-004 / #30) |
| `session_count` | integer ≥ 0 | handoff-cycle counter; HALT-007 fires at `MAKATO_MAX_HANDOFFS` (default 5) |
| `handoff_reason` | string \| null | `"context_ceiling"` during a HALT-007B handoff; null otherwise |
| `restart_failed` | boolean | set true when context-handoff self-restart fails — triggers HALT-007 fallback |
| `created_at` | date-time | ISO-8601 ms, set once at init |
| `updated_at` | date-time | ISO-8601 ms, auto-set on every write |

**sub_tasks[] item:** `id` (int ≥ 1), `description` (non-empty), `status` (`pending` \| `in_progress` \| `complete` \| `failed` \| `skipped`), `phase` (`tdd` \| `goal` \| null), `agent_result` (R1 envelope object or null).

**halt_audit[] item:** `code` (e.g. `HALT-007B`, `HALT-008`), `ts` (ISO-8601 ms), `data` (object, schema varies per code — consumers tolerate unknown keys).

**lessons_learned[] item:** `ts` (ISO-8601 ms), `cycle` (integer ≥ 0), `trigger` (schema enum), `description` (non-empty, ≤ 200 chars), `files_affected` (repo-relative paths). Optional `tier`, `scope`, `tags`, `bundle`, `label`, and `occurrences` retain capture classification for recall and promotion. `scope: generalizable` triggers immediate promotion to the selected persistent memory tier; local entries remain in workflow state. The schema is strict (`additionalProperties: false`): legacy `{ts, text}` entries are not auto-migrated.

## Operations

Eight subcommands operate on per-issue state files at
`specs/<key>-<slug>/workflow-state-<ISSUE_NUMBER>.json` (#173) — spec-folder
resolution still prefix-matches `specs/<key>-*/` (same convention as
`build-log.sh`), then routes to the per-issue file. Every mutating and reading
subcommand except `recall-lessons` takes `<KEY>` **and** `<ISSUE_NUMBER>` as
positional arguments.

**patch vs write — when to use each:**

| Situation | Command |
|-----------|---------|
| Advancing a single field (`current_phase`, `outer_iteration`, `github_pr_number`, a single sub-task status) | `patch` |
| Restoring a full checkpoint (e.g. from `/tmp/` during a HALT-007B resume) | `write` |
| Updating two or more unrelated fields in one call | Multiple `patch` calls, NOT `write` — preserves all other fields |

Use `patch` for any single-field update. Use `write` **only** when restoring a full validated checkpoint JSON from disk. Writing a partial JSON object via `write` silently drops every field not present in the supplied JSON — schema validation catches missing required fields but not missing optional ones.

**Backward-compat migration**: on first `read`/`write`/`patch`/`append-*`/
`summarise-lessons` for a given `<KEY>`, any legacy
`specs/<key>-<slug>/workflow-state.json` is promoted in-place to
`workflow-state-<its own .issue_number>.json` (content-driven rename). The
promotion is atomic and idempotent — a second reader that arrives after the
rename falls through cleanly.

The exception is `recall-lessons`, which takes `<REPO>` instead of `<KEY>` and
scans every `specs/*/workflow-state-*.json` to aggregate across prior runs.

### `init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>`

Create `workflow-state-<ISSUE_NUMBER>.json` with valid defaults: empty arrays, zero counters, `budget_limit_tokens: 500000`, `context_warn_tokens` from `MAKATO_CONTEXT_WARN_TOKENS` env (default 150000), `session_count: 0`, `restart_failed: false`, `worktree_retained: false`, nullable fields (`session_summary`, `handoff_reason`, `github_pr_number`, `current_phase`, `resume_point`, `worktree_path`, `worktree_retain_reason`) set to `null`, `created_at == updated_at == now`. Errors if the file already exists.

```bash
shared/workflow-state.sh init gap-003 macatocz/my-app feat/gap-003 26
```

### `read <KEY> <ISSUE_NUMBER>`

Print the full JSON to stdout, or `{}` if the file is missing. Never creates the spec folder. Safe to pipe to `jq`.

```bash
shared/workflow-state.sh read gap-003 26 | jq '.current_phase'
```

### `write <KEY> <ISSUE_NUMBER> '<JSON>'`

Validate against the schema then atomically overwrite the file. `updated_at` is injected automatically (any value the caller supplies is replaced). Use for bulk state replacement (e.g. resuming from a checkpoint). **Validation is fail-open when `jsonschema` is absent** — the write proceeds without structural checking; the caller is responsible for supplying a complete, valid document (all required fields, no extra top-level keys). See *Dependencies* below.

```bash
shared/workflow-state.sh write gap-003 26 "$(cat /tmp/new-state.json)"
```

### `patch <KEY> <ISSUE_NUMBER> <JQ-PATH> <VALUE>`

Read → apply a single jq-style mutation → validate → atomically overwrite. `VALUE` is a JSON literal (caller quotes strings as `'"value"'`). Supports nested and indexed paths. **Validation is fail-open when `jsonschema` is absent** — same caveat as `write`: the patched document is written without schema enforcement. In practice CI has `jsonschema`; local developer machines default to fail-open if the package is missing.

```bash
shared/workflow-state.sh patch gap-003 26 .current_phase '"implement"'
shared/workflow-state.sh patch gap-003 26 '.sub_tasks[0].status' '"complete"'
shared/workflow-state.sh patch gap-003 26 .outer_iteration '2'
shared/workflow-state.sh patch gap-003 26 .github_pr_number '42'
```

### `append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…] [OPTIONS]`

Append a structured lesson to `lessons_learned[]` (GAP-015 / #37). `ts` is helper-injected; `CYCLE` mirrors `outer_iteration`. `TRIGGER` uses the schema enum, and `DESCRIPTION` is truncated at 200 chars. Remaining positional paths become `files_affected[]`.

Optional flags may follow the description and may be interspersed with file paths: `--tier procedural|semantic`, `--scope generalizable|local`, `--tags tag1,tag2`, `--bundle name`, and `--label name`. A `generalizable` lesson is immediately promoted: semantic tier routes to `.makato/memory/semantic.jsonl`; procedural or omitted tier routes to `.makato/memory/procedural.jsonl`. Local or unclassified entries remain in workflow state.

```bash
shared/workflow-state.sh append-lesson gap-003 26 1 review_comment "Keep tenant identity bound to the verified issuer" body/auth.py --tier semantic --scope generalizable --tags identity,security --bundle python --label auth
```

### `append-halt <KEY> <ISSUE_NUMBER> <CODE> <JSON-DATA>`

Append a structured HALT entry to `halt_audit[]` (#118). `ts` is helper-injected. `CODE` must match `HALT-NNN`, `HALT-NNN[A-Z]` (e.g. `HALT-007B`), or `HALT-STRUCTURAL` per `plugins/makato-orchestrate/halt-conditions.md`. `JSON-DATA` must be a JSON **object** — arrays, scalars, and malformed JSON are rejected before the patch lands. The helper merges via `+ [new]` so the audit log preserves immutable append-only semantics, and the entry is schema-validated like every other write.

```bash
shared/workflow-state.sh append-halt gap-003 26 HALT-007B \
  '{"budget_consumed_tokens":180000,"warn_threshold":170000,"session":2}'
```

This subcommand replaces the open-coded read-merge-write pattern that previously lived in `scripts/context-handoff.sh` (`_append_halt_audit()`) and at every inline HALT-fire site in `agents/po-agent.md`. Callers MUST use `append-halt` rather than `patch .halt_audit ...` so the canonical entry shape and code-format validation stay in one place.

### `bump-structural-halt <KEY> <ISSUE_NUMBER> <CODE> [<ORIGIN>]`

Increment the durable `structural_halt_cycles` counter by exactly 1 — **but only** when `<CODE>` (with `<ORIGIN>` for HALT-008) names a structural HALT (#347, epic #319). The authoritative structural set is **HALT-003**, **HALT-STRUCTURAL**, **HALT-010**, and **HALT-008 with `<ORIGIN>` == `outer_iteration`**. Any other code — HALT-007 (cost), HALT-007B (context handoff), HALT-008 with origin `merge_conflict`/`ci_failure`, HALT-008 with no origin — is a documented **no-op**: the counter is left untouched and the command exits 0. A malformed code (not matching `HALT-NNN[A-Z]` / `HALT-STRUCTURAL`) is rejected. Prints the resulting counter value to stdout and, on a real increment, appends a `step: "structural_halt_increment"` entry to `orchestrate.jsonl`.

```bash
# structural — increments (e.g. 1 → 2):
shared/workflow-state.sh bump-structural-halt gap-003 26 HALT-STRUCTURAL
shared/workflow-state.sh bump-structural-halt gap-003 26 HALT-008 outer_iteration

# non-structural — no-op (counter unchanged):
shared/workflow-state.sh bump-structural-halt gap-003 26 HALT-007
shared/workflow-state.sh bump-structural-halt gap-003 26 HALT-008 ci_failure
```

Called by the PO-agent **exactly once per run** at its terminal state (Step 7) so the counter measures cross-run recurrence of structural failure on the same issue — the property epic #319's AC-epic-1 needs to detect "repeated" structural HALT. It is **never** reset on a HALT-007B context handoff: the resumed session must read the same value the prior session persisted. Backward-compatible with pre-#347 in-flight state files — an absent field is treated as 0 and backfilled on the first structural increment. This counter drives the Needs Planning signal in sibling story #348.

### `recall-lessons <REPO|GIT-URL> [N] [--bundles b1,b2,...] [--labels l1,l2,...]`

Aggregate lessons from two sources for the given repo:

1. `lessons_learned[]` arrays across every `specs/*/workflow-state-*.json` whose `.repo`
   matches the canonical `owner/name` slug.
2. JSONL records in `.makato/memory/*.jsonl` in the main checkout whose `repo` field
   matches that slug (committed persistent store, #470).

A slug, HTTPS remote URL, or SSH Git remote URL is accepted and normalized to `owner/name` before matching.

Returns the top-`N` (default 3) lessons as a JSON array, sorted by **scope asc**
(`generalizable` before `local`), then **occurrences DESC**, then **recency DESC**
(cycle DESC, ts DESC as tiebreaker). The sort is a two-pass stable sort: ts-DESC
first, then scope+occurrences+cycle as the primary key, so recency is the final
tiebreaker within otherwise equal groups.

Optional filters (both default to no-filter when omitted — **AC-2 backward compat**):

- `--bundles b1,b2,...` — restrict results to lessons whose top-level `bundle` or
  any `source_events[].bundle` matches one of the comma-separated values.
- `--labels l1,l2,...` — similarly match top-level `label` or
  `source_events[].label`; this preserves retrieval metadata when duplicate captures
  merge and the consolidated top-level fields represent only one source event.

When both filters are provided, a lesson passes if either filter matches (OR semantics).

```bash
# Original 2-arg call — returns top-3 for repo, no filter (AC-2 backward compat)
shared/workflow-state.sh recall-lessons macatocz/my-app 3 | jq '.[].description'

# Filtered call — top-5 lessons for the python bundle
shared/workflow-state.sh recall-lessons macatocz/my-app 5 --bundles python

# Multiple bundles
shared/workflow-state.sh recall-lessons macatocz/my-app 3 --bundles python,infra

# SSH remote URLs work too
shared/workflow-state.sh recall-lessons git@github.com:macatocz/my-app.git 3 --labels auth
```

Returns `[]` when no matching repo is found, `specs/` does not exist, and
`.makato/memory/` is absent or empty for that repo. Malformed JSONL lines in the
committed store are skipped silently (AC-4). See `MAKATO_MEMORY_ROOT` env var to
override the committed store root in tests.

### `summarise-lessons <KEY> <ISSUE_NUMBER>`

Render the requested issue’s `lessons_learned[]` entries together with matching `change-lessons.jsonl` captures as `specs/<key>-<slug>/lessons-YYYYMMDD-issue-<ISSUE_NUMBER>.md`. Raw captures require explicit issue metadata or an unambiguous legacy issue owner; ambiguous/unreadable input fails without replacing an existing report. If valid sources contain no lessons, the report records that fact. Writes atomically, overwrites idempotently on the same day, and prints the output path.

```bash
shared/workflow-state.sh summarise-lessons gap-003 26
# → /…/specs/gap-003-foo/lessons-20260629-issue-26.md
```

The PO-agent calls this once on every terminal state (success at Step 6 #8, every HALT path in § *Error modes*) so each run leaves a human-readable lesson summary alongside `workflow-state-<issue>.json` and `build.jsonl`.

## Cross-plugin caller (`build-implement-tdd`)

`plugins/makato-build/skills/build-implement-tdd/SKILL.md` invokes `patch` after each successful coder dispatch. Because it lives in a sibling plugin, it resolves the helper via `git rev-parse --show-toplevel` and gates execution on an `-x` test so consumer-repo runs (where the orchestrate plugin is absent) skip silently. It threads the PO-agent's `ISSUE_NUMBER` into the new positional #3 (#173). This is the only sub-skill that writes state directly — every other dispatch path mutates state via the PO-agent.

## Staleness Rule

A state file is considered **stale** when `(now − updated_at) > 86400 seconds` (24 h). The `workflow-state.sh` helper itself **does not enforce** this — staleness is a session-resume concern, handled by the session-status hook in GAP-007 / follow-up. Stateless helper, stateful consumer.

Detection formula (for downstream skills):

```bash
NOW_EPOCH=$(date +%s)
UPDATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" \
  "$(shared/workflow-state.sh read "$KEY" "$ISSUE" | jq -r '.updated_at' | cut -c1-19)" +%s)
[[ $((NOW_EPOCH - UPDATED_EPOCH)) -gt 86400 ]] && echo "stale"
```

## JSONL Audit Requirement

Every mutating call (`init` / `write` / `patch` / `append-lesson` / `bump-structural-halt` / `summarise-lessons`) **must** be followed by an `orchestrate.jsonl` entry from the calling skill. `recall-lessons` is read-only and does not require an audit entry. `bump-structural-halt` additionally self-logs a `step: "structural_halt_increment"` entry on a real increment (a no-op logs nothing). The helper does not write its own data-mutation log — separation of concerns mirrors `build-log.sh` (which writes the log, not the data).

Required audit shape:

```json
{"ts":"<ISO-8601-ms>","skill":"po-agent","issue":<N>,"step":"workflow-state","status":"ok","data":{"op":"patch","path":".current_phase","value":"implement"}}
```

For `summarise-lessons`, use a dedicated `step: "summarise-lessons"` entry that records the rendered path and the terminal state:

```json
{"ts":"<ISO-8601-ms>","skill":"po-agent","issue":<N>,"step":"summarise-lessons","status":"ok","data":{"path":"<absolute path printed by the helper>","terminal_state":"<success|failure>"}}
```

Append via `plugins/makato-build/shared/build-log.sh` (the same helper used by makato-build; see AGENTS.md § *Skill Authoring*) targeting `specs/<key>-<slug>/orchestrate.jsonl`.

## HALT Codes

The helper itself emits two:

- `HALT: INVALID_STATE` — schema validation failed. Stderr carries the failing field. Non-zero exit.
- `HALT: MALFORMED_JSON` — input could not be parsed as JSON. Non-zero exit.

The schema's `halt_audit[]` array **accommodates** future codes that downstream skills emit and persist into state:

- `HALT-007` — per-task or daily token budget exceeded (GAP-004 / #30 — cost control, applies `needs-human-review`).
- `HALT-007B` — context-ceiling reached (GAP-004 / #30 — quality control, triggers proactive handoff via `scripts/context-handoff.sh`; sets `handoff_reason: "context_ceiling"` and increments `session_count`).
- `HALT-008` — `outer_iteration >= 3` (AGENTS.md § Security Model).
- `HALT-009` — GitHub `claude-halt` label detected (GAP-004 / #30).
- `HALT-STRUCTURAL` — coder returned `r1.status == "failure"`.

The schema does not enforce a code enum — new HALT codes can be added without a schema change.

## Dependencies

- `bash`
- `jq` — used for all mutations (per issue #26 AC)
- `python3` + `jsonschema` (optional, fail-open if absent) — used for validation

All four are present on the repo's CI image and on standard developer machines.

## Verification

Smoke tests live at @references/smoke-tests.sh — run from repo root after any change to `workflow-state.sh` or the schema.
Load MANDATORY when: after any edit to `workflow-state.sh` or `workflow-state.schema.json`; before releasing a version bump.
Do NOT Load in routine read-only use of this skill.

The script covers init/read/write/patch/append-lesson/append-halt/bump-structural-halt/recall-lessons/summarise-lessons, duplicate-init refusal, missing-file `{}` response, indexed-path patches, invalid-write halts, the GAP-015 / #37 lessons schema (enum violation, cycle integer guard, 200-char truncation, files_affected variadic, merge_conflict trigger, patch-preserves-lessons, recall filter by repo, summarise idempotency), and the #347 structural-HALT counter matrix (T47–T54: init default, HALT-STRUCTURAL / HALT-008-outer_iteration / HALT-003 / HALT-010 increments, non-structural no-ops incl. HALT-007B handoff, backward-compat backfill, malformed-code rejection).

The `recall-lessons` extension (#470) is covered by @references/recall-extension-smoke-tests.sh (T59–T64): backward-compat 2-arg call, `--bundles` filter, scope/occurrences/recency sort order, `[]` on missing committed store, malformed-JSONL skip, and committed-store integration.
Load MANDATORY when: after any change to `recall-lessons` logic or the committed memory store format.
Do NOT Load unless debugging the recall/filter/sort pipeline.

Focused behavior tests in `tests/test_workflow_lessons.py` cover mixed-source reports, issue attribution, failure preservation, and immediate durable promotion; `tests/test_recall_lessons.py` covers Git remote normalization and filtering from `source_events` metadata.
