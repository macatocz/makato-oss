# NOTICE

## impeccable-frontend-design

This skill is derived from Anthropic's `frontend-design` skill.

- **Upstream:** `frontend-design` (Anthropic)
- **License:** Apache License 2.0
- **Modifications for makato-ux:**
  - Renamed from `frontend-design` to `impeccable-frontend-design` to avoid a name
    collision with the pre-existing `makato-ux:frontend-design` skill.
  - Updated internal slash-command references from `/frontend-design` to
    `/impeccable-frontend-design`.
  - Added `version` frontmatter and a mandatory JSONL audit-emission section to
    satisfy the makato-ux plugin contract (see `AGENTS.md`).
  - Added a target-stack adaptation note so generated output respects the target
    repository's existing stack (e.g. sagibeast: CSS custom properties, no Tailwind
    or shadcn/ui, no edits to CI-locked token files).

The Apache 2.0 license text governs the original work. This NOTICE file documents the
attribution and the changes made when importing the skill into the makato-ux plugin.
