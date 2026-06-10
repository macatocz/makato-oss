# ADR-0011: Integrated HTML Review Pattern

## Status

Accepted

## Date

2026-05-13

## Context

Shaping skills produce artifacts (PRD, architecture, prototype) that require stakeholder review before proceeding to the next pipeline phase. Traditional review approaches — sharing markdown files, pasting into Confluence, or asking users to read raw documents — create friction and lose structural context.

Skills need a review mechanism that:

- Works offline (no server, no login)
- Preserves the artifact's logical sections
- Collects structured feedback per section (not a single freeform comment)
- Is self-contained (one file, openable from disk)

## Decision

Every skill that produces a reviewable artifact also generates a self-contained HTML review file with a standardized "slide-deck" pattern:

| Component                | Purpose                                                                   |
| ------------------------ | ------------------------------------------------------------------------- |
| Step tracker (top)       | Shows which section is active, enables non-linear navigation              |
| Slide content (main)     | One artifact section per slide, rendered for reading                      |
| Feedback panel (sidebar) | Per-section textarea for structured comments                              |
| Bottom bar               | Prev/next navigation, "Copy Feedback" button that aggregates all comments |

The HTML file uses the makato brand for review chrome (nav, step tracker, feedback panels) and preserves the artifact's own styling within slides.

Generation is handled by subagents (doc-writer or prototype-builder per ADR-0010), not the orchestrating skill. The dispatching skill passes structured content; the agent produces the HTML.

Review artifacts:

- `create-prd` → `prd-review.html`
- `create-architecture` → `design-review.html`
- `create-prototype` → `prototype.html` (review chrome wraps interactive prototype slides)

## Consequences

- Stakeholders can review in their browser with zero setup — no tools, accounts, or network required
- Feedback is structured by section, making it actionable (vs. a wall of freeform text)
- The "Copy Feedback" button produces a structured text block the skill can parse to drive revisions
- All review HTMLs share the same interaction model, reducing cognitive load across pipeline phases
- HTML files are larger than markdown but remain under 500KB (acceptable for disk artifacts)
- The pattern is owned by agents, not templates — allows creative variation per skill while maintaining consistent UX
