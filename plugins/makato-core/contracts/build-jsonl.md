<!-- markdownlint-disable MD013 -->
# Contract: build.jsonl Event Schema

## Purpose

Defines the append-only JSONL event log written by all makato-build skills to `specs/<story-key>/build.jsonl`. This file is the audit trail for a build session — every skill appends structured events, and hook scripts read it to verify pipeline state.

## Format

One JSON object per line, UTF-8, newline-terminated. Append-only — skills must never overwrite or truncate existing entries.

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO 8601 timestamp with milliseconds: `2026-05-22T10:30:00.123Z` |
| `skill` | string | Skill or agent that emitted this entry: `build-implement-tdd`, `build-implement-goal`, `build-refine`, `build-simplify`, `build-review`, `build-verify`, `build-push-to-git`, `build-create-pr`, `build-address-pr-comments` |
| `story` | string | Work item key: `ISSUE-1234` |
| `step` | string | Step identifier within the skill (see Step Values below) |
| `status` | string | Enum: `start` \| `ok` \| `warn` \| `error` |
| `model` | string | Model name used for this entry (e.g. `sonnet`, `opus`, `haiku`). Auto-injected by `build-log.sh` from session-start cache when absent. |

## Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `task` | integer | 1-based task index within the plan; present for per-task steps |
| `data` | object | Step-specific structured payload; shape varies by step |
| `error` | string | Verbatim error message when `status: error`; required if status is error |

## Standard Step Values

Every skill must emit at minimum a `session` start and a `session` end:

| Step | Status | Required |
|------|--------|----------|
| `session` | `start` | Session start (first entry per skill invocation) |
| `session` | `ok` \| `error` | Session end (last entry per skill invocation) |

Common intermediate steps (examples — not exhaustive):

| Skill | Step examples |
|-------|--------------|
| `build-implement-tdd` | `baseline`, `load-context`, `load-knowledge-graph`, `tracer-stub`, `tracer-test`, `tracer-verify`, `red`, `green`, `integrate`, `verify-task`, `final-verify` |
| `coder` (agent) | `red`, `green`, `integrate`, `verify-task`, `review-repair` |
| `build-refine` | `explore-codebase`, `load-knowledge-graph` |
| `build-review` | `mechanical-fixes`, `analyze`, `blocking-finding`, `fix-blocking`, `zero-findings-recheck`, `mechanical-fixes-post`, `ac-verification` |
| `build-verify` | `gate-build`, `gate-lint`, `gate-unit`, `gate-integration`, `gate-coverage` |

## Example Entries

```json
{"ts":"2026-05-22T10:30:00.123Z","skill":"build-implement-tdd","story":"ISSUE-1234","step":"session","status":"start","data":{"tdd_tasks":3,"goal_tasks_skipped":0}}
{"ts":"2026-05-22T10:30:01.456Z","skill":"build-implement-tdd","story":"ISSUE-1234","step":"baseline","status":"ok","data":{"pre_existing_failures":0}}
{"ts":"2026-05-22T10:30:05.789Z","skill":"build-coder","story":"ISSUE-1234","step":"red","task":1,"status":"ok","data":{"unit_tests":3,"integration_tests":2}}
{"ts":"2026-05-22T10:30:10.012Z","skill":"build-coder","story":"ISSUE-1234","step":"verify-task","task":1,"status":"error","error":"Compilation failed: cannot find symbol OrderStatus"}
{"ts":"2026-05-22T10:31:00.345Z","skill":"build-verify","story":"ISSUE-1234","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"87%"}}
```

## Invariants

- Entries are append-only — never delete or overwrite
- `ts` values must be monotonically increasing within a single session
- The last `session` entry for a skill is authoritative for pipeline state checks (hooks read it to determine if a phase completed successfully)
- A `status: error` session entry means the skill stopped — a later `status: ok` session entry from the same skill in the same file means a resumed or retried run succeeded

## See Also

- `spec-folder.md` — full spec artifact directory contract
- makato-build AGENTS.md — logging requirements for skill authors
