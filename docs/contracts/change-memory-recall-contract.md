# Change-memory recall contract

Cross-plugin contract between `makato-build` (write-lessons.sh), `makato-orchestrate`
(promote-lessons.sh, workflow-state.sh recall-lessons, context-handoff.sh), and the PO-agent outer
loop.

## 1. JSONL record shape

Every lesson written by `plugins/makato-build/shared/write-lessons.sh` and read by
`plugins/makato-orchestrate/scripts/promote-lessons.sh` shares this schema:

| Field   | Type   | Required | Description                                                                  |
| ------- | ------ | -------- | ---------------------------------------------------------------------------- |
| `ts`    | string | yes      | ISO-8601 UTC timestamp (`…Z`), injected by write-lessons.sh                  |
| `tier`  | string | yes      | `"procedural"` or `"semantic"` — stamped verbatim from the caller's argument |
| `text`  | string | yes      | Lesson or fact body                                                          |
| `tags`  | array  | no       | JSON array of strings (default `[]`)                                         |
| `scope` | string | yes      | `"generalizable"` or `"local"`                                               |
| `key`   | string | yes      | Story key — identifies the source spec folder                                |
| `repo`  | string | yes      | `"owner/repo"` slug derived from `git remote get-url origin`                 |

Captures also carry `event_id` and optional `issue_number`, `bundle`, and `label`. The executable
lifecycle and provenance rules are defined in
[the handoff contract](change-memory-handoff-contract.md).

## 2. Lane distinction: change-lane vs. build-lane

The `key` field encodes which lane originated the record:

| Lane                         | Key shape                   | Example                                        |
| ---------------------------- | --------------------------- | ---------------------------------------------- |
| Build lane (new-work issues) | `<N>-<slug>` — number-first | `473-makato-build-lane-lesson`                 |
| Change lane                  | `<slug>-<N>` — number-last  | `720-makato-change-feat-specify-verify-change` |

The writer resolves exact spec keys first, then unique `key-*` matches. Promotion also discovers
numeric issues by `workflow-state-N.json` identity inside slug-only feature folders. Shared specs
require explicit issue attribution; an exact slug can represent ad-hoc work with no issue. Folder
spelling is not a lane authority.

Source: `promote-lessons.sh` discovery and `write-lessons.sh` spec-folder resolution.

## 3. Promotion gate

`plugins/makato-orchestrate/scripts/promote-lessons.sh` lifts records from the per-issue per-spec
store (`specs/<key>-*/change-lessons.jsonl`) into the committed memory store (`.makato/memory/`).

**Filter:** only records where `scope == "generalizable"` are promoted. Records with
`scope == "local"` or a missing `scope` field are silently skipped.

**Routing by `tier`:**

| tier value                                   | Target file                       |
| -------------------------------------------- | --------------------------------- |
| `"semantic"`                                 | `.makato/memory/semantic.jsonl`   |
| `"procedural"` (or absent / any other value) | `.makato/memory/procedural.jsonl` |

Tier routing was added in issue #494. Any `tier` value that is neither `"semantic"` nor
`"procedural"` falls through to the procedural store as a safe default.

**Dedup:** records are keyed by `sha256(normalize(text) + json(sorted_tags))`. A distinct capture
with duplicate text+tags bumps `occurrences`; replaying the same source event does not. New records
start at `occurrences=1`. The writer invokes promotion at capture time; neither a merge nor a
post-merge agent is required.

Source: `promote-lessons.sh` promotion and provenance merge.

## 4. Recall contract

`plugins/makato-orchestrate/shared/workflow-state.sh recall-lessons` reads lessons from two stores
and merges them:

**Store 1 — live workflow-state files:** `specs/*/workflow-state-*.json` → `.lessons_learned[]`
array. Only files whose top-level `.repo` field equals the requested `REPO` are included.

**Store 2 — committed memory stores:** `.makato/memory/*.jsonl` — both `procedural.jsonl` and
`semantic.jsonl` are read (any `*.jsonl` file under the memory directory). Lines failing JSON parse
are skipped silently (AC-4 / #470). Records are filtered to those whose `.repo` field equals the
requested `REPO`.

**Ordering:** scope ascending (generalizable < local < other), then occurrences descending, then
`ts` descending (newest first within the same scope+occurrences group).

**Optional filters:**

- `--bundles <csv>` — match top-level or source-event `.bundle` values.
- `--labels <csv>` — match top-level or source-event `.label` values.

GitHub HTTPS and SSH remote URLs normalize to `owner/repo` before matching.

An empty (or absent) filter means no filter — preserves backward-compat two-arg
`recall-lessons <REPO> [N]` call byte-for-byte.

**PO-agent Step 2c:** the PO-agent derives `BUNDLES_CSV` from the `tech:*` labels on the GitHub
issue and passes it to `recall-lessons` so only lessons relevant to the story's technology stack are
injected into the session warm-start context.

Source: `workflow-state.sh` `recall-lessons` subcommand.

## 5. HALT-007B context-handoff trigger

`plugins/makato-orchestrate/scripts/context-handoff.sh` triggers a HALT-007B handoff when the
per-session context delta (`budget_consumed_tokens - session_baseline_tokens`) crosses
`context_warn_tokens`.

**What the script does:**

1. **CHECK** — compares the session delta against `context_warn_tokens`. Exits 0 (no-op) when below
   threshold.
2. **CAP** — if `session_count >= MAKATO_MAX_HANDOFFS` (default 5), falls through to HALT-007
   cost-control fallback.
3. **CHECKPOINT** — patches workflow-state with `handoff_reason: "context_ceiling"`, increments
   `session_count`, advances `session_baseline_tokens` to the current cumulative total (so the
   resumed session starts its delta from zero — #281), appends a `HALT-007B` entry to
   `halt_audit[]`.
4. **EMIT** — writes `.claude/state/resume-{KEY}-{ISSUE_NUMBER}.sh`. The resume script calls
   `claude --resume <session-UUID>` where the UUID is `last_session_id` persisted by `loop.sh` after
   each dispatch. Passing the spec KEY to `--resume` was the root cause of #616 — the script now
   guards against a missing `last_session_id` and falls back to HALT-007 rather than emitting a
   broken resume script.
5. **RESTART** — executes the resume script detached (`nohup bash … &`), captures the PID into
   `spawned_pid` for the liveness watchdog (`check-pid` subcommand, #284).

**Why the script does NOT call Claude directly:** dispatching the context-summariser sub-agent
requires the Task tool, which is a Claude harness primitive. The PO-agent dispatches
context-summariser and writes `session_summary` to workflow-state before invoking this script. The
shell logic remains deterministic and unit-testable.

**Resume path — recall at session start:** the emitted resume script re-invokes the PO-agent with
`--resume <session-UUID>`. On session start the PO-agent runs Step 2c (`recall-lessons`) again,
reading both `.makato/memory/*.jsonl` stores and the live workflow-state files to inject the top-N
lessons as warm-start context into the fresh session. This is the standard session-start recall, not
a special-case handoff recall — the `HALT-007B` handoff path re-uses it identically.

Source: `context-handoff.sh` lines 263–378 (`_check` function), lines 146–231 (`_emit_resume`
function).

## 6. End-to-end integration test

`plugins/makato-orchestrate/tests/test_change_memory_recall_integration.sh`

Covers the full write → promote → recall pipeline:

1. Write a `scope:generalizable tier:semantic` lesson via `write-lessons.sh`.
2. Promote via `promote-lessons.sh` — assert the record lands in `semantic.jsonl`, not
   `procedural.jsonl`.
3. Recall via `workflow-state.sh recall-lessons` — assert the record surfaces in the output.
4. Write a `scope:local` lesson and assert it is NOT promoted.
5. Assert change-lane key shape (`<slug>-<N>`) is preserved through the pipeline.

See also: `tests/integration/write-promote-lessons-e2e.sh` for the write-promote seam test in
isolation.
