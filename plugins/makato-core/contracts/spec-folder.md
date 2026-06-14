<!-- markdownlint-disable MD013 -->
# Contract: specs/\<key\>/ Artifact Folder

## Purpose

Defines the shape of the `specs/<story-key>/` directory that makato-plan produces and makato-build consumes. This is the primary cross-plugin artifact boundary in the makato suite.

Both plugins are independently installable. Neither imports from the other at runtime — they share only this on-disk contract.

## Directory Layout

```text
specs/<story-key>/
├── stories.json          # REQUIRED — produced by makato-plan/decompose
├── plan.md               # REQUIRED (by makato-build) — produced by makato-build/refine
├── build.jsonl           # REQUIRED (by makato-build, after refine) — produced by makato-build skills
├── prd.md                # OPTIONAL — produced by makato-plan/create-prd
├── design.md             # OPTIONAL — produced by makato-plan/create-architecture
├── decisions.md          # OPTIONAL — produced by makato-plan/brainstorming
├── glossary.md           # OPTIONAL — produced by makato-plan/grill, enriched by makato-build/grill-with-docs
└── prototype.html        # OPTIONAL — produced by makato-plan/create-prototype
```

## File Ownership

| File | Producer | Consumer(s) |
|------|----------|------------|
| `stories.json` | makato-plan/decompose | makato-build/refine, makato-build/create-pr |
| `prd.md` | makato-plan/create-prd | makato-build/refine |
| `design.md` | makato-plan/create-architecture | makato-build/refine, makato-build/verify |
| `decisions.md` | makato-plan/brainstorming | makato-build/refine, makato-build/grill-with-docs |
| `glossary.md` | makato-plan/grill | makato-build/grill-with-docs (enriches), makato-build/agents/plan-analyst (reads), makato-build/implement-tdd, makato-build/implement-goal |
| `prototype.html` | makato-plan/create-prototype | makato-build/implement-goal |
| `plan.md` | makato-build/refine | makato-build/implement-tdd, makato-build/implement-goal, makato-build/simplify, makato-build/review, makato-build/push-to-git, makato-build/create-pr |
| `build.jsonl` | makato-build/* (all skills append) | makato-build/push-to-git (reads), hooks/pre-push (reads), hooks/post-implement (reads) |

## stories.json Format

Produced by makato-plan/decompose. Minimum shape consumed by makato-build:

```json
[
  {
    "key": "ISSUE-1234",
    "title": "<story title>",
    "description": "<user-story text>",
    "acceptanceCriteria": [
      { "id": "AC-1", "text": "<criterion>" }
    ]
  }
]
```

Additional fields (sprint, labels, components) are allowed and ignored by makato-build.

## plan.md Format

Produced by makato-build/refine. No formal schema — see makato-build's `@references/task-sizing-guide.md` for the template. Minimum required:

- Story key in the header
- Ordered task list with `**Files:**`, `**Mode:**` (tdd|goal), and `**ACs:**` fields per task

## See Also

- `build-jsonl.md` — schema for `build.jsonl`
