# Contract: capture → `.makato/memory/` → recall

This contract covers makato-build and makato-change capture, orchestrate promotion, and
workflow-state recall and summaries. It applies to interactive, autonomous, failed, and handed-off
sessions; a merge is not required for verified learning.

## Canonical destination

The consumer repository’s **main git checkout** owns:

- `.makato/memory/procedural.jsonl` — reusable procedures and failure-resolution patterns.
- `.makato/memory/semantic.jsonl` — durable technical facts.

Helpers resolve the main checkout using `git rev-parse --git-common-dir`, including calls from
linked worktrees. Plugin installation paths are executable locations, not memory destinations.
OMP/Claude host memory is separate and is not a substitute. For SagiBeast the destination is
`/Users/I346175/GITHUB/sagibeast/.makato/memory/`.

## Capture contract

At task completion or handoff, review evidence and capture useful new learning. Do not invent
lessons, duplicate discoveries across terminal skills, or store secrets. If nothing qualifies,
record a concrete `no_new_lessons` reason in the task audit or handoff. An empty generated report
alone does not prove that this review happened.

Resolve `MAKATO_BUILD_ROOT` and `MAKATO_ORCHESTRATE_ROOT` from the installed plugins; never assume
that the consumer repository contains a `plugins/` directory. Run these commands **from the consumer
checkout**:

```bash
"$MAKATO_BUILD_ROOT/shared/write-lessons.sh" \
  "<spec-key>" "<procedural|semantic>" "<generalizable|local>" \
  "<evidence-backed learning>" "<comma-separated-tags>" \
  --issue "<issue-number>" --bundle "<context-bundle>" --label "<label>"
```

The flags and tags are optional. `--issue` is required when multiple issues share a spec directory.
An exact spec key takes precedence over a unique `key-*` match; missing or ambiguous directories
fail without writing. For ad-hoc work, create a clearly named task directory under `specs/` before
capturing.

The writer appends source evidence to `specs/<key>/change-lessons.jsonl`. Each record contains
`event_id`, `ts`, `tier`, `scope`, `text`, `tags`, `key`, and `repo`, plus `issue_number`, `bundle`,
and `label` when available. It then invokes the promoter immediately for `generalizable` records.
`local` records remain per-task.

- Exit `0`: capture succeeded, including durable promotion when generalizable.
- Exit `1`: invalid arguments or identity; no capture claimed.
- Exit `2`: missing or ambiguous spec directory.
- Exit `3`: raw evidence retained, but durable promotion failed. Report this explicitly and retry
  promotion after repairing the cause; do not recapture the same event just to retry persistence.

`workflow-state.sh append-lesson` can also persist explicitly classified workflow lessons using
`--tier`, `--scope generalizable`, `--tags`, `--bundle`, and `--label`. Legacy entries without a
generalizable classification are not silently promoted.

## Promotion contract

```bash
"$MAKATO_ORCHESTRATE_ROOT/scripts/promote-lessons.sh" \
  "<issue-number-or-exact-spec-key>" \
  "<main-root>/specs" \
  "<main-root>/.makato/memory/procedural.jsonl" \
  "<main-root>/.makato/memory/semantic.jsonl"
```

Only the first argument is required. Default sources and stores use the main checkout; if a
procedural destination is supplied, the default semantic store is its sibling. Numeric lookup
includes slug-only folders containing the matching `workflow-state-N.json`, not just numeric folder
names. Exact slug lookup supports ad-hoc work with no GitHub issue. Explicit issue identity prevents
cross-issue attribution in shared feature directories.

Sources are `workflow-state-N.json` → `lessons_learned[]` and `change-lessons.jsonl`. Only
`scope: generalizable` is promoted. Semantic records go to `semantic.jsonl`; procedural and legacy
untyped records go to `procedural.jsonl`.

The durable `key` remains the existing normalized-text-plus-sorted-tags hash; `source_key` retains
the task key. `source_events` records capture provenance. Replaying the same capture does **not**
increase `occurrences`; a distinct capture of the same lesson does. Existing counts without
provenance are retained as a legacy baseline, not reconstructed from guesses. Bundle/label
annotations remain available for filtered recall, including later source events.

Per-store locks cover read/merge/atomic replacement. Malformed source or store content returns
nonzero without replacing durable data. A successful no-op means no eligible source was found, not
that a learning review took place. Reaper and merge-terminal promotion are recovery passes, not the
primary persistence path. A fresh CI checkout cannot recover uncommitted, gitignored captures.

## Recall and reporting

```bash
"$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" \
  recall-lessons "<owner/repo>" 10 --bundles "<bundle>" --labels "<label>"

"$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" \
  summarise-lessons "<spec-key>" "<issue-number>"
```

Recall merges live workflow lessons with durable memory, normalizes GitHub remote URLs to repository
slugs, applies optional bundle/label filters, and ranks by scope, occurrences, and recency.
`MAKATO_MEMORY_ROOT` and `SPECS_DIR` provide explicit isolated roots for tests. Existing malformed
durable lines are ignored by recall; promotion fails rather than overwriting malformed storage.

Summaries include both workflow lessons and raw captures for the requested issue. Malformed sources
or ambiguous attribution fail instead of replacing a report with a false-empty success. Genuine
empty history remains empty; no missing historical lesson is inferred from a successful build or PR.

## Root cause: stagnant SagiBeast memory

The October investigation found a disconnected lifecycle, not a JSONL disk failure:

1. Capture was optional and terminal-only. SagiBeast had no raw capture files; issue #887’s
   workflow-state had an empty `lessons_learned` array. Its August empty report accurately reflected
   missing capture, not lost report text.
2. The writer intentionally did not persist durable memory. Promotion depended on the local
   autonomous merge path; the CI documentation step was explicitly a no-op because source files are
   gitignored. Ordinary sessions had no path.
3. Numeric folder matching missed feature slugs. CWD-relative defaults split stores across
   worktrees; supplying a procedural path did not relocate semantic.
4. Workflow append did not carry promotion classification, and summaries ignored the separate raw
   capture file. Remote-URL and metadata mismatches impaired recall.
5. Tests checked that instructions mentioned helpers, or even required memory to remain empty after
   capture. Those checks passed despite the broken lifecycle.

The fix makes capture-time persistence executable, installs a project learning policy during
onboarding, and verifies real capture/promotion/recall behavior. It does not manufacture the missing
August-to-October learning history.

## Verification

- `tests/test_capture_memory.py`: real git worktree capture, both tiers, immediate recall, replay,
  issue attribution, local exclusion, and persistence failure.
- `tests/test_promote_lessons.py`: discovery, destination, provenance, locking, replay, malformed
  input, and preservation of existing records.
- Workflow-state behavior tests: source-aware summaries, typed capture, remote normalization, and
  filtered recall.
- `tests/integration/write-promote-lessons-e2e.sh` and
  `tests/integration/change-memory-handoff-e2e.sh`: actual cross-plugin commands.
