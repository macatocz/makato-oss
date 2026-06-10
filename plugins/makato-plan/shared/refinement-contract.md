# Refinement Contract

> Shared rules for "Refine — update the existing X" mode in `create-prd`, `create-architecture`, `create-prototype`, and `decompose`. When a skill's update-mode step says "preserve unchanged content", this contract defines what that means in practice.

## Why

Each shaping skill detects an existing artifact (`prd.md`, `design.md`, `prototype.html`, `stories.json`) and offers a "Refine" option. Without a shared contract, each skill interprets "preserve unchanged" differently — risking silent rewrites of user-confirmed content during refinement.

## Rules

### 1. Enumerate change candidates before writing

Before generating any content in refinement mode, the skill MUST tell the user which sections it intends to change, based on:
- The user's explicit refinement request (e.g., "update the data model", "add a new component").
- New context the skill loaded that affects existing sections (e.g., a newly resolved Open Question that contradicts a prior decision).

The skill prompts the user to confirm the change list before writing.

### 2. Sections not in the change list are preserved

Sections outside the confirmed change list are written back byte-for-byte (or section-for-section if the artifact is structured like JSON). The skill MUST NOT:
- Re-summarize them.
- "Tighten" wording.
- Reorder them.
- Strip comments / formatting.

### 3. New AI inferences require explicit approval

If the skill identifies a section it thinks should change but the user did NOT request that change, the skill MUST surface the proposed change as a question before writing. Example:

> "Round 2 of the architecture interview revealed the auth flow. The existing PRD doesn't mention auth in Goals. Should I add an auth-related goal, or leave Goals untouched?"

Only proceed once the user confirms.

### 4. Emit a `changes[]` summary

In refinement mode, after writing, present a summary of every modified section. For markdown artifacts, this can be a bullet list:

```
Changes:
- Section "Data Model" — replaced (per refinement request)
- Section "Open Questions" — Q3 resolved (auth flow chosen)
- All other sections unchanged.
```

For `stories.json`, list the modified story sequence numbers and which fields changed.

### 5. Status field handling

If the artifact has a `**Status**: Approved` line and the refinement substantively changes content, prompt the user whether to revert to `Draft` or keep `Approved`. Do not silently revert.

## Skill Touchpoints

Each skill loads this contract at its update-mode detection step:

- `create-prd/SKILL.md` Step 1.4 (Refine option)
- `create-architecture/SKILL.md` Step 1.4 (Refine option)
- `create-prototype/SKILL.md` Step 1.4 (Refine option)
- `decompose/SKILL.md` Step 1.4 (Refine option)

Each skill applies the contract to the artifact it owns (markdown for PRD/design, HTML for prototype, JSON for stories).

## What This Contract Does NOT Cover

- First-time generation (no existing artifact). All content is new — no preservation needed.
- Cross-artifact updates (e.g., decompose touching prd.md). Skills should not edit artifacts outside their own scope.
