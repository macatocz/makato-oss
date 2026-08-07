# Contract: makato-change → `.makato/memory/` → recall-lessons seam

> **Seam #3 of 5** from the suite feature audit
> (`docs/makato-feature-audit.md` → Cross-plugin integration seams).
>
> This document is the authoritative reference for the boundary spanning
> three components:
>
> 1. `plugins/makato-change/skills/execute/SKILL.md` and
>    `plugins/makato-change/skills/resolve-review/SKILL.md` — the **writers**
>    that call `plugins/makato-build/shared/write-lessons.sh`.
> 2. `plugins/makato-orchestrate/scripts/promote-lessons.sh` — the **promoter**
>    that lifts `scope:generalizable` records into `.makato/memory/`.
> 3. `plugins/makato-orchestrate/shared/workflow-state.sh recall-lessons` —
>    the **reader** invoked by `plugins/makato-change/skills/analyze/SKILL.md`
>    Step 2.7 on session resume.
>
> It contains **no code duplication** — all implementation details reference
> source files as the single source of truth. (issue #720)

---

## 1 — Shared JSONL record schema

All three components share a single JSONL record contract defined in
`plugins/makato-build/shared/write-lessons.sh` (header comment) and
`plugins/makato-orchestrate/scripts/promote-lessons.sh` (header comment).
The boundary data shape is:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ts` | string | yes | ISO-8601 timestamp written by `write-lessons.sh` at append time |
| `tier` | string | yes | `"procedural"` \| `"semantic"` — stamped verbatim from the caller's second positional argument |
| `scope` | string | yes | `"generalizable"` \| `"local"` — stamped verbatim from the caller's third positional argument |
| `text` | string | yes | lesson/fact body; also aliased as `description` for `workflow-state-<N>.json` source-A compatibility |
| `tags` | array | no | JSON array derived from a comma-separated CSV argument; defaults to `[]` when absent |
| `key` | string | yes | story key identifying the source spec folder (e.g. `720-makato-change-feat-specify-verify-change`) |
| `repo` | string | yes | `owner/repo` slug normalized from `git remote get-url origin` (e.g. `macatocz/makato`) |

The `repo` normalization strips the `https://github.com/` or `git@github.com:` prefix and
removes any trailing `.git` suffix. Both `write-lessons.sh` and `promote-lessons.sh` apply
the same normalization so the `repo` field is consistent across writer, promoter, and reader.

---

## 2 — Which source files write records

Two terminal steps in the change lane call `write-lessons.sh`:

**`plugins/makato-change/skills/execute/SKILL.md` Step 11** — after the
`change-implementer` sub-agent completes and the quality gate passes, the
execute skill appends noteworthy implementation lessons (e.g. patch-ordering
constraints, integration gotchas discovered during the change) to
`specs/<key>-*/change-lessons.jsonl`.

**`plugins/makato-change/skills/resolve-review/SKILL.md` terminal step (Step 9)** —
after all PR review comments are addressed and the push succeeds, the
resolve-review skill appends lessons learned from the review cycle
(e.g. recurring MUST-FIX categories, reviewer preference patterns) to
`specs/<key>-*/change-lessons.jsonl`.

Both steps invoke:

```bash
plugins/makato-build/shared/write-lessons.sh \
  "<key>" "<tier>" "<scope>" "<text>" "[tags-csv]"
```

`write-lessons.sh` is a **pure writer** — it appends exactly one JSONL line to
`specs/<key>-*/change-lessons.jsonl` and **never touches `.makato/memory/`**.
That invariant is enforced and verified by the integration test
`tests/integration/change-memory-handoff-e2e.sh` (Scenario A Step A assertion).

---

## 3 — How `promote-lessons.sh` promotes records

**Source:** `plugins/makato-orchestrate/scripts/promote-lessons.sh`

`promote-lessons.sh` accepts `<ISSUE_NUMBER> [SPECS_DIR] [MEMORY_FILE] [SEMANTIC_MEMORY_FILE]`
and reads two source types per matching spec folder:

- **Source A** — `specs/<key>-*/workflow-state-<N>.json` → `.lessons_learned[]` (build-lane records)
- **Source B** — `specs/<key>-*/change-lessons.jsonl` (change-lane records, one JSON object per line)

**Filtering:** only records with `scope == "generalizable"` are promoted. Records
with `scope == "local"` or a missing `scope` field are silently skipped.

**Routing by `tier`:**

| Condition | Target file |
|-----------|-------------|
| `scope == "generalizable"` AND `tier == "semantic"` | `.makato/memory/semantic.jsonl` |
| `scope == "generalizable"` AND `tier == "procedural"` (or absent) | `.makato/memory/procedural.jsonl` |
| `scope == "local"` | not promoted |

**Deduplication:** each promoted record is keyed by
`sha256(normalize(text) + json(sorted(tags)))` where `normalize` lowercases the
text, collapses whitespace, and strips non-alphanumeric characters. A second
promotion of an identical record bumps `occurrences` on the existing entry rather
than appending a new line.

**Atomic write:** `promote-lessons.sh` writes via a sibling tmp file + `os.replace()`.
Tests must not assert file presence before the script exits (Hard Constraint #6 from
the plan's Knowledge Graph).

---

## 4 — How `workflow-state.sh recall-lessons` reads from `.makato/memory/`

**Source:** `plugins/makato-orchestrate/shared/workflow-state.sh` subcommand `recall-lessons`

**Call signature used by `makato-change:analyze` Step 2.7:**

```bash
REPO_REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
_recalled="$(plugins/makato-orchestrate/shared/workflow-state.sh \
  recall-lessons "$REPO_REMOTE" 3 2>/dev/null || echo "[]")"
```

Note: `recall-lessons` accepts either the full remote URL
(`https://github.com/macatocz/makato.git`) or the normalized slug (`macatocz/makato`).
The matching in the Python reader is an exact string comparison against the `repo` field —
callers should pass the same normalized form that `write-lessons.sh` wrote.

**Two-step collection:**

1. Scans `specs/*/workflow-state-<N>.json` for `.lessons_learned[]` entries where
   `repo` matches the argument (live state source).
2. Reads every `*.jsonl` file under `$MAKATO_MEMORY_ROOT/.makato/memory/` line by line,
   skipping malformed lines, retaining records where `repo` matches (committed store source).

**`MAKATO_MEMORY_ROOT` override:** tests set this environment variable to redirect
`recall-lessons` from the production `.makato/memory/` to a sandbox path. This is
Hard Constraint #3 from the plan's Knowledge Graph — required for hermetic tests.

**Sort and limit:** records are merged, sorted by scope asc / occurrences DESC / ts DESC,
and the top N (default 3, configurable) are returned as a JSON array. An empty store
returns `[]` without error.

---

## 5 — HALT-007B context-handoff resume path

When the PO-agent (or `makato-change:orchestrate`) hits the context ceiling, the
proactive handoff is coordinated by `scripts/context-handoff.sh`:

1. **`context-handoff.sh emit-resume`** writes `.claude/state/resume-{KEY}.sh` containing
   a `claude --resume $SESSION_ID -p "..."` invocation that exec-s the orchestrate skill in
   autonomous mode.

2. **The resume script** runs:
   ```bash
   claude --resume "$SESSION_ID" \
     -p "Use the Skill tool to invoke the makato-change:orchestrate skill with args '$KEY --autonomous'"
   ```

3. **`makato-change:orchestrate` resumes mid-phase** — it reads `change-state-<N>.json` to
   determine which phase was interrupted (`analyze`, `design`, `execute`, or `resolve-review`)
   and continues from there. It does **not** restart from analyze.

4. **The resumed `analyze` phase calls `recall-lessons`** at Step 2.7 using the
   two-step collection described in Section 4. Lessons written by the prior change session
   (via `write-lessons.sh`) and promoted by `promote-lessons.sh` are available to the fresh
   context window through the standard `recall-lessons` path — the committed `.makato/memory/`
   survives the context boundary because it is a persistent file on disk (and, for the
   multi-session scenario, is committed to the repo via the post-merge promotion hook).

**Chain summary:**

```
prior session:
  execute/resolve-review Step 11/9
    └─ write-lessons.sh → specs/<key>-*/change-lessons.jsonl

promotion (post-merge or documentation-agent):
  promote-lessons.sh <N>
    └─ .makato/memory/procedural.jsonl  (tier:procedural records)
    └─ .makato/memory/semantic.jsonl    (tier:semantic records)

fresh session (post-HALT-007B resume):
  context-handoff.sh emit-resume
    └─ resume-{KEY}.sh → claude --resume … → makato-change:orchestrate
         └─ analyze Step 2.7
              └─ recall-lessons → .makato/memory/*.jsonl
```

---

## 6 — Change-lane vs build-lane record distinction

Both change-lane (`makato-change`) and build-lane (`makato-build`) records share
the **same** `.makato/memory/procedural.jsonl` and `.makato/memory/semantic.jsonl`
store. There is no reserved field that separates the two lanes — the schema is
intentionally lane-agnostic so `recall-lessons` returns relevant lessons regardless
of which pipeline produced them.

**Runtime distinguishers available within each record:**

| Distinguisher | How to inspect |
|---------------|---------------|
| `key` | The story key identifies the source spec folder; change-lane keys typically follow the `<issue>-makato-change-*` naming convention |
| `tags` | Optional tags may carry lane hints written by the caller (e.g. `"change,execute"` or `"build,verify"`) — these are advisory, never enforced by the schema |

A consumer that needs to filter by lane must inspect `key` or `tags`; there is no
first-class `lane` field. New records added by `write-lessons.sh` carry whatever
tags the caller supplies; older records from `workflow-state-<N>.json`
`.lessons_learned[]` carry no lane tag.

---

## 7 — Test coverage

The integration test at `tests/integration/change-memory-handoff-e2e.sh` exercises
the contract described above:

| Scenario | Property verified |
|----------|-------------------|
| A — happy path | Full write → promote → recall chain (Sections 2, 3, 4) |
| A — pure-writer invariant | `write-lessons.sh` does not touch `.makato/memory/` (Section 2) |
| B — broken-seam guard | When `promote-lessons.sh` is skipped, `recall-lessons` returns no matching record (Section 4 isolation) |

Run from repo root:

```bash
bash tests/integration/change-memory-handoff-e2e.sh
```

Exit 0 means all scenarios passed. Exit non-zero (equal to the count of failed
scenarios) means at least one seam is broken.
