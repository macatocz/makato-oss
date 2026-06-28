---
name: workflow-state
description: >-
  Read and write PO-agent resumable session state at
  `specs/<key>-<slug>/workflow-state.json`. Provides five subcommands
  (init / read / write / patch / append-lesson) via `shared/workflow-state.sh`,
  backed by a JSON Schema draft-07 contract. PO-agent (GAP-006 / #32) is the
  sole writer in production. Use when you need a resumable overlay over
  `build.jsonl` — the audit log captures forensics, this skill captures live
  loop state (sub-task graph, current phase, budget, HALT audit, lessons).
version: "1.0.0"
argument-hint: "<subcommand> <key> [args…]"
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
| `worktree_path` | string \| null | absolute path to worktree, null if main checkout |
| `issue_number` | integer ≥ 1 | GitHub Issue number |
| `sub_tasks` | array | ordered; see *sub_tasks shape* |
| `current_phase` | string \| null | `refine` \| `implement` \| `verify` \| `pr` \| `done` |
| `resume_point` | string \| null | opaque hint for session-status hook |
| `budget_consumed_tokens` | integer ≥ 0 | cumulative; updated after each dispatch |
| `budget_limit_tokens` | integer ≥ 1 | HALT-007B fires at ceiling |
| `outer_iteration` | integer ≥ 0 | HALT-008 fires at 3 |
| `halt_audit` | array | append-only; see *halt_audit shape* |
| `human_review_cycles` | integer ≥ 0 | count of `needs-human-review` labellings |
| `github_pr_number` | integer \| null | set after `build-create-pr` succeeds |
| `lessons_learned` | array | append-only; see *lessons_learned shape* |
| `created_at` | date-time | ISO-8601 ms, set once at init |
| `updated_at` | date-time | ISO-8601 ms, auto-set on every write |

**sub_tasks[] item:** `id` (int ≥ 1), `description` (non-empty), `status` (`pending` \| `in_progress` \| `complete` \| `failed` \| `skipped`), `phase` (`tdd` \| `goal` \| null), `agent_result` (R1 envelope object or null).

**halt_audit[] item:** `code` (e.g. `HALT-007B`, `HALT-008`), `ts` (ISO-8601 ms), `data` (object, schema varies per code — consumers tolerate unknown keys).

**lessons_learned[] item:** `ts` (ISO-8601 ms), `text` (non-empty).

## Operations

All five subcommands resolve the spec folder by prefix-matching `specs/<key>-*/` (same convention as `build-log.sh`).

### `init <KEY> <REPO> <BRANCH> <ISSUE_NUMBER>`

Create `workflow-state.json` with valid defaults: empty arrays, zero counters, `budget_limit_tokens: 500000`, `created_at == updated_at == now`. Errors if the file already exists.

```bash
shared/workflow-state.sh init gap-003 macatocz/my-app feat/gap-003 26
```

### `read <KEY>`

Print the full JSON to stdout, or `{}` if the file is missing. Never creates the spec folder. Safe to pipe to `jq`.

```bash
shared/workflow-state.sh read gap-003 | jq '.current_phase'
```

### `write <KEY> '<JSON>'`

Validate against the schema then atomically overwrite the file. `updated_at` is injected automatically (any value the caller supplies is replaced). Use for bulk state replacement (e.g. resuming from a checkpoint).

```bash
shared/workflow-state.sh write gap-003 "$(cat /tmp/new-state.json)"
```

### `patch <KEY> <JQ-PATH> <VALUE>`

Read → apply a single jq-style mutation → validate → atomically overwrite. `VALUE` is a JSON literal (caller quotes strings as `'"value"'`). Supports nested and indexed paths.

```bash
shared/workflow-state.sh patch gap-003 .current_phase '"implement"'
shared/workflow-state.sh patch gap-003 '.sub_tasks[0].status' '"complete"'
shared/workflow-state.sh patch gap-003 .outer_iteration '2'
shared/workflow-state.sh patch gap-003 .github_pr_number '42'
```

### `append-lesson <KEY> "<TEXT>"`

Append `{ts, text}` to `lessons_learned[]`. `updated_at` is updated automatically.

```bash
shared/workflow-state.sh append-lesson gap-003 "tracer bullet essential for multi-layer stories"
```

## Cross-plugin caller (`build-implement-tdd`)

`plugins/makato-build/skills/build-implement-tdd/SKILL.md` invokes `patch` after each successful coder dispatch. Because it lives in a sibling plugin, it resolves the helper via `git rev-parse --show-toplevel` and gates execution on an `-x` test so consumer-repo runs (where the orchestrate plugin is absent) skip silently. This is the only sub-skill that writes state directly — every other dispatch path mutates state via the PO-agent.

## Staleness Rule

A state file is considered **stale** when `(now − updated_at) > 86400 seconds` (24 h). The `workflow-state.sh` helper itself **does not enforce** this — staleness is a session-resume concern, handled by the session-status hook in GAP-007 / follow-up. Stateless helper, stateful consumer.

Detection formula (for downstream skills):

```bash
NOW_EPOCH=$(date +%s)
UPDATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" \
  "$(shared/workflow-state.sh read "$KEY" | jq -r '.updated_at' | cut -c1-19)" +%s)
[[ $((NOW_EPOCH - UPDATED_EPOCH)) -gt 86400 ]] && echo "stale"
```

## JSONL Audit Requirement

Every mutating call (`init` / `write` / `patch` / `append-lesson`) **must** be followed by an `orchestrate.jsonl` entry from the calling skill. The helper does not write its own log — separation of concerns mirrors `build-log.sh` (which writes the log, not the data).

Required audit shape:

```json
{"ts":"<ISO-8601-ms>","skill":"po-agent","issue":<N>,"step":"workflow-state","status":"ok","data":{"op":"patch","path":".current_phase","value":"implement"}}
```

Append via the orchestrate log helper (TBD: `shared/orchestrate-log.sh`) — until that ships, callers can append directly to `specs/<key>-<slug>/orchestrate.jsonl`.

## HALT Codes

The helper itself emits two:

- `HALT: INVALID_STATE` — schema validation failed. Stderr carries the failing field. Non-zero exit.
- `HALT: MALFORMED_JSON` — input could not be parsed as JSON. Non-zero exit.

The schema's `halt_audit[]` array **accommodates** future codes that downstream skills emit and persist into state:

- `HALT-007B` — context-ceiling reached (GAP-004 / #30 extension; documented at the issue level).
- `HALT-008` — `outer_iteration >= 3` (AGENTS.md § Security Model).
- `HALT-STRUCTURAL` — coder returned `r1.status == "failure"`.

The schema does not enforce a code enum — new HALT codes can be added without a schema change.

## Dependencies

- `bash`
- `jq` — used for all mutations (per issue #26 AC)
- `python3` + `jsonschema` (optional, fail-open if absent) — used for validation

All four are present on the repo's CI image and on standard developer machines.

## Verification

Smoke tests live in @references/smoke-tests.sh — run from repo root after any change to `workflow-state.sh` or the schema. The script covers init/read/write/patch/append-lesson, duplicate-init refusal, missing-file `{}` response, indexed-path patches, and invalid-write halts.
