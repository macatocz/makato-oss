# Spec: Three-tier dev-time agent memory for makato-suite

> **Status:** draft — grilled design, pending review.
> **Domain:** makato-orchestrate (cross-branch: build, change, orchestrate).
> **Scope:** dev-time orchestrator memory (makato learning to build software).
> **NOT in scope:** runtime CMAI product memory (a SAGIBEAST agent remembering
> customer conversations). That is a separate runtime concern.

## Problem

`lessons_learned[]` exists today but is a **feature of the po-agent only**, not a
platform-wide capability. Three concrete gaps were confirmed by code inspection:

1. **`/build-start` loses lessons.** `build-implement-tdd` *consumes*
   `PRIOR_LESSONS` but never *recalls* it — only the po-agent (Step 2c) fills
   that field. A manual `/build-start` run leaves it empty; the coder works
   with no historical memory.
2. **makato-change has no lesson concept at all.** `grep` across the entire
   branch (analyze/design/execute/resolve-review + agents) finds zero lesson
   handling — neither read nor write. Change work never recalls prior bugfix
   patterns and never records new ones.
3. **Archival kills recall.** `recall-lessons` reads live `specs/*/workflow-state-*.json`.
   `archive-spec` does `mv specs/<folder> specs/archive/...`, moving the JSON
   below the recall glob depth — the lesson silently drops out of the loop.
   `lessons-*.md` is also gitignored, so the human render never reaches git.

The root cause: memory is pinned to the wrong layer (the orchestrator) and to a
transient location (per-issue spec folders that get archived).

## Inspiration

A three-dimension agent-memory model (episodic / semantic / procedural). Adopted
as a **framing**, not literally — makato already has all three dimensions
scattered across three unconnected files with different lifecycles. This spec
names them, fixes their persistence, and shares their recall across all three
entry branches (loop, build, change).

## The three tiers

| Tier | Format | Persistence | Written by | Read by |
|------|--------|-------------|------------|---------|
| **Episodic** (raw log) | JSONL (`*.jsonl` today) | local / gitignored | agent during run | forensic / handoff |
| **Semantic-B** (agent facts) | **JSONL** `.makato/memory/semantic.jsonl` | committed | agent at merge | agent at start |
| **Procedural** (lessons) | **JSONL** `.makato/memory/procedural.jsonl` | committed | agent at merge | agent at start |
| Semantic-A (requirements) | md `specs/master/<domain>.md` | committed | `archive-spec` | human |

**Key split (Q2):** semantic data is two different kinds. Agent-generated facts
("BGE-M3 embeddings are dim 1024", "testcontainers need a colima socket
override") are machine-written and machine-read → **JSONL**. The curated
requirements narrative (`master/<domain>.md`, ADDED/MODIFIED/Evolution Log) is
human-authored and human-read → **stays markdown**, unchanged. Only the
agent-facing tiers unify on JSONL.

**Episodic stays local (Q7):** raw per-run event log is bulky, forensic, and
never read by recall — it is not committed and not promoted.

## JSONL record schema

```json
{
  "ts": "2026-07-19T09:00:00.000Z",
  "tier": "procedural | semantic",
  "repo": "macatocz/makato",
  "key": "216-feat-observability-capture-token",
  "text": "Run semgrep locally before pushing new urllib/subprocess/network code — the CI-only sensor set is broader than a manual lint subset.",
  "tags": ["python", "tech:harness"],
  "scope": "generalizable | local",
  "occurrences": 3,
  "source_issue": 216,
  "repo_sha": "c6766f4",
  "date": "2026-07-19"
}
```

## Lifecycle of one memory item

```
Konec issue (before merge)        Po merge PR (CI)              Start next issue
   agent writes raw                documentation-agent           agent recalls
   lessons+facts to                PROMOTES generalizable        from persistent
   per-issue store    ─────────▶   items to .makato/memory ──▶   store into context
   (po/build/change)               (dedup, repo_sha/date)        (guarded cache)
```

Two write moments, two actors: **"at end"** (po/build/change skill, local,
pre-merge) produces raw per-issue output; **"at merge"** (`documentation-agent`,
CI, post-merge) promotes only what earns permanence. One read moment: **"at
start"** = recall into context (recall = *how*, start = *when* — one action).

## Design decisions (grilled)

| # | Decision | Rationale |
|---|----------|-----------|
| Q1 | Mapping layer over existing artifacts, **not** a new service. Dev-time scope. | Three tiers already exist and hold the right data; the gap is persistence + shared recall, not a missing store. |
| Q2 | Split semantic: agent facts → JSONL; requirements narrative → stays md. | Two different data kinds with two different readers (machine vs human). |
| Q3 | Promote filter **B primary + A fallback**: writer stamps `scope: generalizable\|local`; `documentation-agent` promotes only `generalizable`; LLM-judge only for records missing the flag. | Writer knows best and it is deterministic/cheap; LLM-judge avoided on the hot path. |
| Q4 | Recall relevance **A + B**: tag via `context-bundles.yml` (changed files → bundle) + issue labels. No embeddings. | Reuse the existing, deterministic glob-specificity relevance model; labels cover the pre-implementation start when no changed files exist yet. |
| Q5 | Recall = shared helper with **guarded cache** (`PRIOR_LESSONS`). First caller (po-agent Step 2c / build-start / change analyze) fills it; downstream skills read. | One read per run regardless of entry point; loop, `/build-start`, and change all converge. |
| Q6 | Dedup **A**: exact `hash(normalized_text)+tags` at promote; on match bump `occurrences++`. | Deterministic, cheap (no embeddings, consistent with Q4). `occurrences` doubles as an importance signal for AGENTS.md graduation. |
| Q7 | Store lives in **`.makato/memory/`** (root); extend `scripts/check-root-structure.sh` ALLOWED with `.makato`. Episodic stays local/gitignored. | Clean separation from the spec lifecycle (survives `archive-spec`); root allowlist has a hidden-dir branch so one array entry suffices. |
| Q8 | Grow-append + ordering (`scope`, `occurrences DESC`, recency) + tag filter. Prune manually. | Large file is fine — filter+top-N always returns the sharp head. TTL rejected (kills rare-but-valid lessons). |
| Q9/9b | New **`makato-orchestrate:lesson-prune`** skill: human-gated, classification model (KEEP/DUPLICATE/GRADUATED/STALE/CONSOLIDATE) ported from the positronic vault skill, adapted to JSONL + `repo_sha`/`date`-aware STALE detection. | Prune is destructive → diff-before-write + approval is load-bearing. It is an operator curation tool, not a per-issue build step. |

## Division of write labor

- **`documentation-agent` (CI, per merge):** cheap exact+tag dedup + promote of
  `generalizable` records; stamps `repo_sha` + `date`.
- **`lesson-prune` (operator, occasional):** heavy human-gated curation —
  GRADUATED check against AGENTS.md, CONSOLIDATE, `repo_sha`/`date`-aware STALE.

Two distinct responsibilities, not duplication.

## Affected components

1. **`shared/workflow-state.sh` `recall-lessons`** — extend signature to
   `recall-lessons <repo> <bundles[]> <labels[]> <N>`; read `.makato/memory/*.jsonl`
   alongside live `workflow-state-*.json`; filter `repo AND (bundle ∈ my_bundles
   OR label ∈ my_labels)`; order `scope, occurrences DESC, recency`.
2. **`build-start` / `build-refine`** — guarded recall: fill `PRIOR_LESSONS` when
   absent from the input bundle (Q5).
3. **makato-change `analyze` + `execute`/`resolve-review`** — wire recall (into
   `change-implementer` as `PRIOR_LESSONS`) and write (lessons at end).
4. **`documentation-agent`** — new promote step: read per-issue lessons/facts,
   dedup, promote `generalizable` to `.makato/memory/`, stamp `repo_sha`/`date`.
5. **`scripts/check-root-structure.sh`** — add `.makato` to `ALLOWED`.
6. **New skill `makato-orchestrate:lesson-prune`** — JSONL-native, human-gated.
7. **`.gitignore`** — commit `.makato/memory/{semantic,procedural}.jsonl`; keep
   episodic `*.jsonl` ignored.
8. **`context-bundles.yml`** — reused as-is for tagging (no change expected;
   confirm the bundle keys agent-facts should carry).

## Open questions for review

- Should `semantic.jsonl` and `procedural.jsonl` be one file with a `tier` field
  or two files? (Schema has `tier`; two files aid human diffing, one file
  simplifies recall.)
- Does `documentation-agent` run reliably per-merge in every consumer repo, or
  only where `workflows/post-merge.yml` is installed? (Determines whether promote
  is universal or opt-in.)
- Cross-repo scope: `.makato/memory/` is per-repo. Is a shared cross-repo store
  ever wanted (the makato board hosts multiple repos)? Out of scope for v1.
