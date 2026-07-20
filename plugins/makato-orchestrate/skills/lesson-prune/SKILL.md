---
name: lesson-prune
description: >-
  Operator-gated curation tool for the committed makato memory store
  (.makato/memory/procedural.jsonl and semantic.jsonl). Classifies every
  record as KEEP / DUPLICATE / GRADUATED / STALE / CONSOLIDATE, renders a
  diff-before-write classification table, and — only on explicit operator
  approval — rewrites the files atomically. Operator-only: never wired into
  any per-issue build lane or autonomous pipeline.
version: "1.0.0"
argument-hint: "[MEMORY_DIR] [--non-interactive]"
---

<!-- markdownlint-disable MD013 -->

# lesson-prune

> **Operator curation tool.** Human-gated. Never invoked per-issue or autonomously.
> Classifies memory records; no mutation until you explicitly approve.

## When to Use

Use when the committed memory store (`.makato/memory/procedural.jsonl` and
`semantic.jsonl`) has grown enough that stale, duplicate, or redundant entries
may be degrading the quality of lesson recall. Typical cadence: after every 3–5
merged epics, or whenever `recall-lessons` returns obviously outdated content.

**Do NOT use** as an automated build step, a CI gate, or inside any autonomous
pipeline. This skill is operator-only: it requires a human to review and approve
the classification table before any record is touched.

## Classification Classes

| Class | Meaning | Proposed action |
|---|---|---|
| **KEEP** | No curation signal — record is current and unique | No change |
| **DUPLICATE** | Same `hash(normalize_text(text) + sorted(tags))` as another record | Remove; canonical record is noted in `target` |
| **GRADUATED** | Lesson text (verbatim or strong token subset) already encoded in an `AGENTS.md` | Remove — the rule is now architecture, not memory |
| **STALE** | `repo_sha` not reachable from HEAD **and** `date` >90 days old | Remove — probable dead-branch remnant |
| **CONSOLIDATE** | 2+ records sharing a tag cluster, not identical | Merge into a single authoritative entry |

### STALE false-positive warning

A lesson whose originating commit was legitimately **rebased out** (clean history
rewrite, squash merge) will appear STALE even though its content remains relevant.
**Always review STALE proposals with human judgment.** When in doubt, keep the
record — the cost of a false negative (removing a valid lesson) outweighs the cost
of a false positive (keeping an old-but-relevant one).

## Workflow

### Step 1 — Read and classify

```bash
MEMORY_DIR="${1:-.makato/memory}"
CLASSIFICATION="$(bash plugins/makato-orchestrate/scripts/lesson-prune.sh "$MEMORY_DIR")"
```

The helper reads both `procedural.jsonl` and `semantic.jsonl` and emits one JSON
line per record: `{"key":"…","action":"KEEP|…","reason":"…","target":"…"}`.

### Step 2 — Render the classification table

Parse `$CLASSIFICATION` and display:

```
Lesson-prune classification (N records across procedural + semantic)
──────────────────────────────────────────────────────────────────────
 # │ Source     │ Action      │ Key (first 8 chars) │ Reason
───┼────────────┼─────────────┼─────────────────────┼──────────────────
 1 │ procedural │ KEEP        │ a3f7c1…             │ unique record
 2 │ procedural │ DUPLICATE   │ 9b22e0…             │ same text+tags as record 1
 3 │ semantic   │ STALE       │ 1d4fa2…             │ repo_sha unreachable, 210 days old
 4 │ semantic   │ GRADUATED   │ c80011…             │ text encoded in AGENTS.md
 5 │ procedural │ CONSOLIDATE │ 44fe8d…             │ shares tag "shell" with record 6
 6 │ procedural │ CONSOLIDATE │ 7a91cc…             │ shares tag "shell" with record 5
──────────────────────────────────────────────────────────────────────
Actions: KEEP×1  DUPLICATE×1  STALE×1  GRADUATED×1  CONSOLIDATE×2
```

If **all records are KEEP**: print "All N records are KEEP — no curation needed."
and exit 0 without touching any file (non-interactive no-mutation path).

### Step 3 — Approval gate

Prompt:

```
Apply the proposed curation? [y/N]
```

- **y / yes**: apply (Step 4).
- **anything else / no input**: print "No changes made." and exit 0. Both JSONL
  files are left **byte-identical** to the pre-run state.

When `--non-interactive` is passed (or stdin is not a TTY): treat as rejection
and exit 0 without touching either file. This makes the skill safe to call from
scripts that must never mutate without a live operator.

### Step 4 — Apply approved actions (atomic write)

For each record classified as non-KEEP, remove it from the in-memory record list.
For CONSOLIDATE pairs: remove all but the record with the highest `occurrences`
(tie-break: newest `date`), matching the DUPLICATE keeper selection logic.

Rewrite both files atomically using the `tmp + os.replace` pattern (mirrors
`promote-lessons.sh`):

```python
import os, tempfile

for filepath, records in [(proc_file, proc_records), (sem_file, sem_records)]:
    mem_dir = os.path.dirname(filepath)
    fd, tmp_path = tempfile.mkstemp(dir=mem_dir, prefix=".lesson-prune-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for rec in records:
                fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
        os.replace(tmp_path, filepath)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
```

Print a summary: "Curation applied: N records removed (K DUPLICATE, M STALE, …)"

## Examples

### Run against the default memory location

```bash
plugins/makato-orchestrate/skills/lesson-prune/SKILL.md
# OR invoke via the skill router:
/makato-orchestrate:lesson-prune
```

### Run against a custom memory directory

```bash
/makato-orchestrate:lesson-prune /path/to/.makato/memory
```

### Dry-run (classification only, no approval prompt)

```bash
bash plugins/makato-orchestrate/scripts/lesson-prune.sh .makato/memory
```

## Smoke tests

```bash
plugins/makato-orchestrate/scripts/lesson-prune-smoke-tests.sh
```

Covers: each classification class, operator rejection (byte-identical), all-KEEP
no-mutation exit-0, GRADUATED with two AGENTS.md layouts.

## See also

- `scripts/lesson-prune.sh` — classification helper (pure read, no mutation)
- `scripts/lesson-prune-smoke-tests.sh` — offline smoke tests (real git fixture for STALE)
- `scripts/promote-lessons.sh` — the write counterpart (adds new lessons at merge time)
- `.makato/memory/procedural.jsonl`, `.makato/memory/semantic.jsonl` — the stores this skill curates
