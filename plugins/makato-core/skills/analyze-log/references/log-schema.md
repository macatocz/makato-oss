# build.jsonl Entry Types for analyze-log

> Reference for the `analyze-log` skill. Documents all JSONL entry types consumed
> and how they map to report sections.

## Entry Types

### Session Entries

Every skill emits `session` start and end entries:

```json
{"ts": "...", "skill": "build-implement-tdd", "story": "ISSUE-1234", "step": "session", "status": "start", "model": "sonnet", "data": {...}}
{"ts": "...", "skill": "build-implement-tdd", "story": "ISSUE-1234", "step": "session", "status": "ok", "data": {...}}
```

- `status: start` → session began
- `status: ok` → session completed successfully
- `status: error` → session failed (check `error` field)

### Step Entries

Intermediate steps within a session. The `model` field is not written by the emitting skill:
`build-log.sh` copies it from the session-start entry, so it appears on every stored entry.

```json
{"ts": "...", "skill": "build-coder", "story": "ISSUE-1234", "step": "red", "task": 1, "status": "ok", "model": "<from session start>", "data": {...}}
```

### Telemetry Entries

Token usage data (when available):

```json
{"ts": "...", "skill": "...", "story": "...", "step": "telemetry", "data": {"input_tokens": 1234, "output_tokens": 567, "model": "<model id>"}}
```

### Critical Finding Entries

```json
{"ts": "...", "skill": "build-review", "story": "...", "step": "critical-finding", "data": {"finding": "description", "severity": "CRITICAL", "file": "path", "line": 42}}
```

## Skill-to-Phase Mapping

| Phase | Skills |
|-------|--------|
| refine | `build-refine`, `build-start` |
| implement | `build-implement-tdd`, `build-implement-goal`, `build-coder` |
| simplify | `build-simplify` |
| review | `build-review`, `diff-reviewer` |
| verify | `build-verify`, `build-runtime-qa` |
| push | `build-push-to-git` |
| pr | `build-create-pr`, `build-coordinate-repos`, `build-address-pr-comments` |
| change | `change-implementer`, `code-reviewer`, `quality-guard` |

## Session Matching

Sessions are matched by `skill` name + timestamp order, NOT by `session_id`.
The `session_id` field rotates on harness reconnect, making it unreliable for
session grouping. Instead: group all entries with the same `skill` + `story`
that fall between a `session:start` and the next `session:ok|error` for that
skill.

## Retry Detection

A retry is detected when the same `skill` + `story` combination has:
1. A `session:error` entry
2. Followed by a later `session:start` + `session:ok` for the same skill

Mark retries with `↩` in the audit trail table.
