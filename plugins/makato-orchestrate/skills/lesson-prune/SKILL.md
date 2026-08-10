---
name: lesson-prune
description: >-
  Operator-gated curation tool for the committed makato memory store
  (.makato/memory/procedural.jsonl and semantic.jsonl). Classifies every
  record as KEEP / DUPLICATE / GRADUATED / STALE / CONSOLIDATE, renders a
  diff-before-write classification table, and — only on explicit operator
  approval — rewrites the files atomically. Trigger keywords: prune lessons,
  curate memory, clean memory store, trim procedural, trim semantic.
  Operator-only: never wired into any per-issue build lane or autonomous
  pipeline. Do NOT load this skill for recall-lessons, promote-lessons, or
  any read-only memory operation.
version: "1.1.0"
argument-hint: "[MEMORY_DIR] [--non-interactive]"
allowed-tools: Bash(python3 plugins/makato-orchestrate/scripts/lesson_prune.py *) Bash(python3 *) Read
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
the classification table before any record is touched. Do NOT load this skill
for read-only memory operations — use `recall-lessons` instead.

## Classification Classes

| Class | Meaning | Proposed action |
|---|---|---|
| **KEEP** | No curation signal — record is current and unique | No change |
| **DUPLICATE** | Same `hash(normalize_text(text) + sorted(tags))` as another record | Remove; canonical record is noted in `target` |
| **GRADUATED** | Lesson text (verbatim or strong token subset) already encoded in an `AGENTS.md` | Remove — the rule is now architecture, not memory |
| **STALE** | `repo_sha` not reachable from HEAD **and** `date` >90 days old | Remove — probable dead-branch remnant |
| **CONSOLIDATE** | 2+ records sharing a tag cluster, not identical | Merge into a single authoritative entry |

### GRADUATED: the critical boundary judgment

A GRADUATED lesson is one the classifier matched as already encoded in an
`AGENTS.md`. The non-obvious failure mode: the classifier detects a token-subset
match, not semantic equivalence. A lesson about a *failure scenario* ("never do X
because it triggers Y") can share 60–70% of tokens with an `AGENTS.md` rule that
encodes only the prohibition without the causation. If the `reason` field drops the
failure scenario, future agents lack the corrective context. Always read the
`AGENTS.md` anchor before approving GRADUATED — ask: does the encoded rule capture
*why*, not just *what*?

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
CLASSIFICATION="$(python3 plugins/makato-orchestrate/scripts/lesson_prune.py "$MEMORY_DIR")"
```

The helper reads both `procedural.jsonl` and `semantic.jsonl` and emits one JSON
line per record: `{"key":"…","action":"KEEP|…","reason":"…","target":"…"}`.

**Error paths — Step 1:**

- **`lesson_prune.py` exits non-zero**: print its stderr verbatim, then exit the
  skill without touching any file. Do not attempt to parse partial output.
- **Malformed JSONL** (a line that does not parse as JSON): print the offending
  line number and the raw content, then exit without touching any file. Do NOT
  silently skip the malformed record — a corrupt store requires manual repair
  before curation.
- **Both files absent or both empty** (fresh install / empty store): print
  "Memory store is empty — nothing to prune." and exit 0. There is no
  mutation path.

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

## Anti-patterns

**NEVER call from a CI job, pre-commit hook, or any automated pipeline.**
WHY: the `[y/N]` approval gate cannot fire in a non-TTY context. The
`--non-interactive` flag exits 0 silently — if the caller treats exit 0 as
success and assumes mutations were applied, the store is never pruned but the
caller sees no error. The operator-review requirement is not optional ceremony;
it is the only defense against bulk-removing lessons that were misclassified
by the hash algorithm.

**NEVER approve STALE records as a batch without reading each one individually.**
WHY: a rebased or squash-merged commit SHA is legitimately unreachable from HEAD
yet the lesson remains valid; `git log` will not surface it. Batch-approving
STALE removes knowledge the team wrote specifically because something went wrong
in a workflow that no longer exists in history. The `repo_sha unreachable` signal
is necessary but not sufficient for "this lesson is obsolete."

**NEVER approve GRADUATED without reading the matching `AGENTS.md` anchor.**
WHY: the classifier detects a token-subset match, not semantic equivalence. The
AGENTS.md rule may encode the prohibition but drop the *causation* (the failure
scenario that taught the rule). If the lesson's `text` adds corrective context not
present in AGENTS.md, removing it silently degrades future agent judgment.

**NEVER run lesson-prune while `promote-lessons.sh` is actively writing.**
WHY: both tools use `tmp + os.replace` but operate independently. A concurrent
`promote-lessons.sh` write replaces the file after lesson-prune reads it and
before lesson-prune's `os.replace` fires — the promoted record is silently lost
(last writer wins). The `os.replace` contract is process-safe against crashes, not
against concurrent writers. Coordinate via the same terminal session; do not
background either process.

**NEVER silently skip a malformed JSONL record.**
WHY: a JSON parse error means the file was written incorrectly by a prior
`promote-lessons.sh` run or a manual edit. If curation proceeds on the parseable
subset, the malformed record is silently discarded in the next `os.replace` pass —
permanent data loss with no audit trail. The correct response is to surface the
corrupt line and halt, forcing manual repair before curation.

**NEVER approve CONSOLIDATE without reading the full `text` of both candidates.**
WHY: the tie-break rule (highest `occurrences`, then newest `date`) retains the
better-anchored record structurally, but the *losing* record's text may contain
the clearer description or the only occurrence of a specific edge-case. The winning
record's `text` does not automatically absorb the loser's meaning; the curator must
decide whether to edit the surviving record before applying.

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
python3 plugins/makato-orchestrate/scripts/lesson_prune.py .makato/memory
```

## Smoke tests

```bash
python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_lesson_prune.py -v
```

Covers: each classification class, operator rejection (byte-identical), all-KEEP
no-mutation exit-0, GRADUATED with two AGENTS.md layouts.

## See also

- `scripts/lesson_prune.py` — classification helper (pure read, no mutation)
- `scripts/tests/test_lesson_prune.py` — pytest suite (14 scenarios, real git fixture for STALE)
- `scripts/promote-lessons.sh` — the write counterpart (adds new lessons at merge time)
- `.makato/memory/procedural.jsonl`, `.makato/memory/semantic.jsonl` — the stores this skill curates
