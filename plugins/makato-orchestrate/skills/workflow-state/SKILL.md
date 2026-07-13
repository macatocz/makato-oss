---
name: workflow-state
description: >-
  Read and write PO-agent resumable session state at
  `specs/<key>-<slug>/workflow-state-<issue>.json`. Per-issue file layout
  (#173) — multiple GitHub issues can share a story-level spec folder without
  clobbering each other's audit trails. Provides eight subcommands
  (init / read / write / patch / append-lesson / append-halt /
  recall-lessons / summarise-lessons) via `shared/workflow-state.sh`,
  backed by a JSON Schema draft-07 contract. PO-agent (GAP-006 / #32) is
  the sole writer in production. Use when you need a resumable overlay
  over `build.jsonl` — the audit log captures forensics, this skill
  captures live loop state (sub-task graph, current phase, budget, HALT
  audit, structured lessons learned).
version: "1.5.0"
argument-hint: "<subcommand> <key|repo> [<issue>] [args…]"
---

<!-- markdownlint-disable MD013 -->

# workflow-state

## When to Use

Use **only** from:

1. The PO-agent outer loop (GAP-006 / #32) — sole writer in steady state.
2. The session-status hook (GAP-007 / follow-up) — read-only at session start.
3. `build-implement-tdd`'s narrow guarded patch on task completion (see *Cross-plugin caller* below).

Do **not** call from sub-agents (`coder`, `diff-reviewer`, `gate-scout`, `plan-analyst`, etc.). Sub-agents return R1 envelopes; the PO-agent translates those into state patches. Concurrent writes are a design failure, not a race to manage.

## Schema Reference

The full contract lives at @references/workflow-state.schema.json (draft-07, `additionalProperties: false` at top level). Top-level fields:

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
| `resume_point` | string \| null | opaque hint for session-status hook |
| `budget_consumed_tokens` | integer ≥ 0 | cumulative; updated after each dispatch; never reset (HALT-007 cost ceilings evaluate this total) |
| `session_baseline_tokens` | integer ≥ 0 | `budget_consumed_tokens` at the current session's start (#281); HALT-007B evaluates the delta `consumed - baseline` and sets this to `consumed` on each handoff so a resumed session's context budget restarts at 0. Optional for pre-#281 in-flight state (readers default 0) |
| `budget_limit_tokens` | integer ≥ 1 | HALT-007 fires at ceiling (cost control) |
| `context_warn_tokens` | integer ≥ 1 | HALT-007B fires when the session delta reaches this threshold (quality control; default 150000) |
| `outer_iteration` | integer ≥ 0 | HALT-008 fires at 3 |
| `merge_conflict_cycles` | integer ≥ 0 | count of merge-conflict resolution attempts; HALT-008 fires independently at `MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3) |
| `ci_failure_cycles` | integer ≥ 0 | count of CI-failure fix attempts (#288); HALT-008 fires independently at `MAKATO_MAX_CI_FAILURE_CYCLES` (default 3) — kept separate from `outer_iteration` so transient CI noise does not consume the re-plan budget |
| `halt_audit` | array | append-only; see *halt_audit shape* |
| `human_review_cycles` | integer ≥ 0 | count of `needs-human-review` labellings |
| `github_pr_number` | integer \| null | set after `build-create-pr` succeeds |
| `lessons_learned` | array | append-only; see *lessons_learned shape* |
| `session_summary` | string \| null | ≤ 500-token handoff payload from context-summariser (GAP-004 / #30) |
| `session_count` | integer ≥ 0 | handoff-cycle counter; HALT-007 fires at `MAKATO_MAX_HANDOFFS` (default 5) |
| `handoff_reason` | string \| null | `"context_ceiling"` during a HALT-007B handoff; null otherwise |
| `restart_failed` | boolean | set true when context-handoff self-restart fails — triggers HALT-007 fallback |
| `created_at` | date-time | ISO-8601 ms, set once at init |
| `updated_at` | date-time | ISO-8601 ms, auto-set on every write |

**sub_tasks[] item:** `id` (int ≥ 1), `description` (non-empty), `status` (`pending` \| `in_progress` \| `complete` \| `failed` \| `skipped`), `phase` (`tdd` \| `goal` \| null), `agent_result` (R1 envelope object or null).

**halt_audit[] item:** `code` (e.g. `HALT-007B`, `HALT-008`), `ts` (ISO-8601 ms), `data` (object, schema varies per code — consumers tolerate unknown keys).

**lessons_learned[] item:** `ts` (ISO-8601 ms, helper-injected), `cycle` (integer ≥ 0, mirrors `outer_iteration`), `trigger` (`ci_failure` | `halt` | `review_comment` | `sensor` | `merge_conflict`), `description` (non-empty, ≤ 200 chars — helper truncates with `…` suffix), `files_affected` (array of repo-relative paths, may be empty). The structured shape lands per GAP-015 / #37. The schema is strict (`additionalProperties: false` at the item level): a legacy `{ts, text}` entry in a pre-existing `workflow-state.json` will halt the next mutating call with `HALT: INVALID_STATE`. There is no automatic migration — operators upgrading mid-flight must either re-`init` the spec folder (losing in-flight state) or hand-edit `workflow-state.json` to drop the legacy entries before resuming. This is a one-time hazard: every fresh run from `init` writes the new shape from the start.

## Operations

Seven subcommands operate on per-issue state files at
`specs/<key>-<slug>/workflow-state-<ISSUE_NUMBER>.json` (#173) — spec-folder
resolution still prefix-matches `specs/<key>-*/` (same convention as
`build-log.sh`), then routes to the per-issue file. Every mutating and reading
subcommand except `recall-lessons` takes `<KEY>` **and** `<ISSUE_NUMBER>` as
positional arguments.

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

Validate against the schema then atomically overwrite the file. `updated_at` is injected automatically (any value the caller supplies is replaced). Use for bulk state replacement (e.g. resuming from a checkpoint).

```bash
shared/workflow-state.sh write gap-003 26 "$(cat /tmp/new-state.json)"
```

### `patch <KEY> <ISSUE_NUMBER> <JQ-PATH> <VALUE>`

Read → apply a single jq-style mutation → validate → atomically overwrite. `VALUE` is a JSON literal (caller quotes strings as `'"value"'`). Supports nested and indexed paths.

```bash
shared/workflow-state.sh patch gap-003 26 .current_phase '"implement"'
shared/workflow-state.sh patch gap-003 26 '.sub_tasks[0].status' '"complete"'
shared/workflow-state.sh patch gap-003 26 .outer_iteration '2'
shared/workflow-state.sh patch gap-003 26 .github_pr_number '42'
```

### `append-lesson <KEY> <ISSUE_NUMBER> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]`

Append a structured lesson to `lessons_learned[]` (GAP-015 / #37). `ts` is helper-injected. `CYCLE` mirrors the current `outer_iteration`. `TRIGGER` must match the schema enum: `ci_failure`, `halt`, `review_comment`, `sensor`, `merge_conflict`. `DESCRIPTION` is auto-truncated at 200 chars with a `…` suffix. Remaining positional args become `files_affected[]` (variadic; may be zero).

```bash
shared/workflow-state.sh append-lesson gap-003 26 1 ci_failure \
  "ruff F401 unused import in tracer test" \
  tests/test_tracer.py src/tracer/__init__.py
```

### `append-halt <KEY> <ISSUE_NUMBER> <CODE> <JSON-DATA>`

Append a structured HALT entry to `halt_audit[]` (#118). `ts` is helper-injected. `CODE` must match `HALT-NNN`, `HALT-NNN[A-Z]` (e.g. `HALT-007B`), or `HALT-STRUCTURAL` per `plugins/makato-orchestrate/halt-conditions.md`. `JSON-DATA` must be a JSON **object** — arrays, scalars, and malformed JSON are rejected before the patch lands. The helper merges via `+ [new]` so the audit log preserves immutable append-only semantics, and the entry is schema-validated like every other write.

```bash
shared/workflow-state.sh append-halt gap-003 26 HALT-007B \
  '{"budget_consumed_tokens":180000,"warn_threshold":170000,"session":2}'
```

This subcommand replaces the open-coded read-merge-write pattern that previously lived in `scripts/context-handoff.sh` (`_append_halt_audit()`) and at every inline HALT-fire site in `agents/po-agent.md`. Callers MUST use `append-halt` rather than `patch .halt_audit ...` so the canonical entry shape and code-format validation stay in one place.

### `recall-lessons <REPO> [N]`

Aggregate `lessons_learned[]` across every `specs/*/workflow-state-*.json` whose `.repo` matches `<REPO>`. Returns the top-`N` (default 3) most recent lessons as a JSON array, sorted `(cycle DESC, ts DESC)`. Used by the PO-agent at session start (GAP-015 / #37 AC3) to warm-start the dispatch bundle with prior lessons from the same repository. The glob widened from `workflow-state.json` to `workflow-state-*.json` in #173 — legacy pre-migration files are picked up by their next read/mutate and thereafter appear in the aggregate view.

```bash
shared/workflow-state.sh recall-lessons macatocz/my-app 3 | jq '.[].description'
```

Returns `[]` when no matching repo is found or `specs/` does not exist.

### `summarise-lessons <KEY> <ISSUE_NUMBER>`

Render `lessons_learned[]` for the given issue as `specs/<key>-<slug>/lessons-YYYYMMDD-issue-<ISSUE_NUMBER>.md` (GAP-015 / #37 AC4). Idempotent: a same-day re-run overwrites in place. Writes a minimal stub file when `lessons_learned[]` is empty so the audit trail records that no lessons were captured. Prints the absolute output path to stdout. The filename now carries the issue number so multiple issues sharing a spec folder do not overwrite each other's summaries (#173).

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

Every mutating call (`init` / `write` / `patch` / `append-lesson` / `summarise-lessons`) **must** be followed by an `orchestrate.jsonl` entry from the calling skill. `recall-lessons` is read-only and does not require an audit entry. The helper does not write its own log — separation of concerns mirrors `build-log.sh` (which writes the log, not the data).

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

Smoke tests live in @references/smoke-tests.sh — run from repo root after any change to `workflow-state.sh` or the schema. The script covers init/read/write/patch/append-lesson/recall-lessons/summarise-lessons, duplicate-init refusal, missing-file `{}` response, indexed-path patches, invalid-write halts, the GAP-015 / #37 lessons schema (enum violation, cycle integer guard, 200-char truncation, files_affected variadic, merge_conflict trigger, patch-preserves-lessons, recall filter by repo, summarise idempotency).
