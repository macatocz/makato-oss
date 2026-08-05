---
name: frontend-design
description: >-
  Create distinctive, production-grade frontend interfaces — HTML/CSS, React, components,
  pages, dashboards, landing pages, web UI. Use when building or styling any web interface,
  avoiding generic AI aesthetics in favour of bold intentional design. Triggers: frontend,
  UI, design, component, style, CSS, React, HTML, dashboard, landing page, visual design.
version: "1.2.0"
argument-hint: "[brief description of UI surface to build or restyle]"
metadata:
  last_updated: "2026-08-05"
---

# frontend-design

Approach every surface as the design lead at a small studio known for giving each
client a visual identity that could not be mistaken for anyone else's. The people you
build for have already rejected proposals that felt templated — make deliberate,
opinionated choices about palette, typography, and layout that are specific to *this*
brief, and take one real aesthetic risk you can justify.

## When to Use

- Building any web component, page, or application as part of the production UI layer
- Translating specs or design tokens into styled HTML/CSS/React code
- Beautifying or restyling an existing UI surface
- Creating dashboards, landing pages, or component libraries

## When NOT to Use

- Exploratory UI validation or stakeholder mockups — use `makato-plan/create-prototype`
- Backend logic, API endpoints, or database work — use `makato-build`
- Writing E2E or browser tests — use `webapp-testing`

---

## Audit Emission (MANDATORY)

This skill runs inside the makato-ux plugin, which requires JSONL audit entries at every
major boundary. Emit to the session log at:

- **Session start**: `{"event":"skill_start","skill":"frontend-design","step":0}`
- **After Step 1** (context locked): `{"event":"step_complete","skill":"frontend-design","step":1,"context_subject":"<subject>"}`
- **After Step 2** (design system scanned): `{"event":"step_complete","skill":"frontend-design","step":2,"tokens_found":<true|false>}`
- **After Step 3** (plan approved): `{"event":"step_complete","skill":"frontend-design","step":3,"clustering_check":"pass|revised"}`
- **After Step 4** (implementation done): `{"event":"step_complete","skill":"frontend-design","step":4}`
- **Session end**: `{"event":"skill_end","skill":"frontend-design","outcome":"complete|halted"}`

These are appended to the JSONL audit stream (stdout or the active session log file);
they are not written to the project source tree.

---

## Anti-Patterns

### NEVER use warm cream + terracotta as a default palette
WHY: This is the single most common AI-generated look (~#F4F1EA background, terracotta
accent, high-contrast serif display). It appears regardless of subject because it is
the statistical mean of "warm, elevated, editorial" — not a response to any specific
brief. A fintech dashboard, a developer tool, and a recipe app receive the same
treatment. It signals the design was not thought about. Exception: the brief uses the
word "warm," "earthy," or "rustic," or the product is literally in a craft or food
category and the brief explicitly asks for this direction.

### NEVER default to near-black + acid-green or vermilion as a "dark, modern" direction
WHY: This is the second most common AI clustering aesthetic. Near-black with a single
bright accent (acid-green #00FF41 or vermilion) signals "tech startup dark theme" and
has been used so heavily it reads as template, not voice. Exception: the brief names
"hacker aesthetic," "terminal," "gaming," or the product has an established brand that
uses exactly this palette.

### NEVER apply broadsheet layout (hairline rules, zero border-radius, dense columns) as a default "editorial" direction
WHY: Third AI clustering aesthetic. Newspaper-grid treatments appear as the default
response to any brief that mentions "editorial," "publication," or "content-rich" —
regardless of whether the product has any relationship to print media. Exception: the
subject is genuinely print-adjacent (news, long-form journalism, academic publishing)
and the brief names this direction.

### NEVER use Inter, Roboto, or Arial as the display typeface
WHY: These are system utility fonts — optimised for legibility at small sizes in
functional UI, not for creating a visual identity. Using them as the display face
produces the same neutral, unmemorable result on every project. A distinctive typeface
is the highest-leverage branding decision in a design and costs nothing extra.
Exception: the project's design system explicitly mandates one of these as the brand
typeface (e.g., a Google product using Roboto for brand consistency).

### NEVER use numbered markers (01 / 02 / 03) when the content is not actually a sequence
WHY: Numbered decorations encode a claim: "these items have an inherent order and that
order matters." Applying them to a features grid, a team page, or a capabilities list
is a lie in the UI — it says "order matters" when it doesn't. It also reads as a design
cliché: the AI-generated equivalent of bullet-point slides. Use numbers only when the
progression genuinely matters (installation steps, a wizard, an ordered ranking).

### NEVER scatter animation across every element
WHY: Multiple concurrent animations on load, hover, and scroll compete for attention,
fragment the visual hierarchy, and signal that the motion was added for its own sake
rather than to reinforce meaning. More critically, it is now a recognizable AI-
generated tell — the equivalent of Lorem Ipsum in motion. One well-composed moment
(a page-load sequence OR a key micro-interaction, not both everywhere) lands harder
and reads as intentional.

### NEVER use solid flat colours as the primary visual treatment without deliberate reason
WHY: Flat solid fills produce surfaces that look like placeholder wireframes or 2013-era
flat design. Gradient meshes, noise textures, subtle geometric patterns, layered
transparencies, and dramatic shadows create atmosphere and distinguish the surface from
a template. Exception: the brief explicitly asks for "ultra-minimal," "brutalist," or
"stripped-back" — these directions use flat color as a deliberate statement.

### NEVER resolve a conflict between discovered design tokens and the brainstormed palette by silently ignoring the tokens
WHY: The codebase's design system is the single source of truth for a production UI.
Overriding it with a custom palette creates a maintenance fork — two parallel systems
that diverge at every subsequent change. Surface the conflict explicitly: list the
discovered tokens, explain the aesthetic tension, and let the user decide whether to
extend the system or override it for a standalone surface.

---

## Workflow

### Step 1: Understand Context and Ground It in the Subject

Before writing a single line of code, establish:

1. **Purpose** — what problem does this interface solve? Who uses it? What is the
   page's single job?
2. **Subject** — if the brief does not pin down what the product or subject is, pin it
   yourself: name one concrete subject, its audience, and its single job, then state
   your choice. The subject's own world — its materials, instruments, artifacts, and
   vernacular — is where distinctive choices come from. Build with the brief's real
   content and subject matter throughout, not lorem placeholder.
3. **Tone** — commit to a clear aesthetic direction: brutally minimal, maximalist,
   retro-futuristic, organic, luxury, editorial, brutalist, art-deco, soft/pastel,
   industrial. Choose one and execute it with precision.
4. **Constraints** — framework (HTML/CSS, React, Vue), performance requirements,
   accessibility level, design system tokens if available.
5. **Signature** — the single unique element this page will be remembered by, one that
   embodies the brief. Define it upfront; everything else stays quiet around it.

Emit audit entry for Step 1.

### Step 2: Discover Design System

If the target codebase exists, scan for design tokens before writing anything:

- Look for CSS custom properties (`--color-*`, `--spacing-*`, `--font-*`) in global stylesheets
- Check for `tailwind.config.*`, `theme.ts`, or design token files
- Look for component library imports (`@radix-ui`, `shadcn`, `mui`, custom packages)

Use discovered tokens exclusively. Fall back to custom CSS variables only when no design
system exists. Avoid Bootstrap, Material Design defaults unless they are the project standard.

**Token conflict resolution:** if discovered tokens clash aesthetically with the
direction from Step 1, do not silently override them — see the Anti-Patterns section.
Surface the conflict and resolve it explicitly with the user.

Emit audit entry for Step 2.

### Step 3: Brainstorm a Design Plan, Then Critique It

Work in two passes before touching implementation code.

**First, brainstorm a compact token system** derived from the brief:

- **Color** — describe the palette as 4–6 named hex values.
- **Type** — the typefaces for 2+ roles: a characterful display face used with
  restraint, a complementary body face, and a utility face for captions or data if
  needed.
- **Layout** — a layout concept, using one-sentence prose descriptions and ASCII
  wireframes to ideate and compare.
- **Signature** — the one memorable element from Step 1, now made concrete.

**Then run the anti-clustering check.** Ask: does this plan match any of the three
default AI looks in the Anti-Patterns section (warm-cream, near-black+acid-green,
broadsheet)? Does the typeface choice default to Inter/Roboto/Arial? Does the layout
fall into a predictable symmetric grid? If yes on any axis the brief left free, revise
that axis and note what changed and why.

All three aesthetics are legitimate when the brief asks for them. The test is: "Did the
brief create this, or did I produce it because it is the default?" Brief always wins.

Only after passing the clustering check should you start writing code — then follow the
plan exactly.

Emit audit entry for Step 3, recording whether any clustering revision occurred.

### Step 4: Implement

Write production-grade, functional code applying these principles:

**Typography carries the personality.** Pair a distinctive display face with a refined
body face — not the families you reach for on every project. Set a clear type scale with
intentional weights, widths, and spacing. Avoid Inter, Roboto, Arial, and system-font
stacks unless the design explicitly demands them. Make the type treatment itself a
memorable part of the design, not a neutral delivery vehicle.

**Color** — commit to a cohesive palette with CSS variables. Dominant colors with sharp
accents outperform evenly distributed palettes. Consider both dark and light themes.

**Structure is information.** Structural devices — numbering, eyebrows, dividers, labels
— should encode something true about the content, not decorate it. Numbered markers
(01 / 02 / 03) are only appropriate when the content actually is a sequence; question
whether such choices make sense before incorporating them.

**Motion, deliberately.** Use animation where it serves the subject: a page-load
sequence, a scroll-triggered reveal, hover micro-interactions. One well-orchestrated
moment usually lands harder than scattered effects. CSS-only for HTML artifacts; Motion
library for React. But less is often more — excess animation is itself a tell that a
design was AI-generated.

**Spatial composition** — use asymmetry, overlap, diagonal flow, or generous negative
space. Avoid predictable grid-box layouts.

**Depth** — gradient meshes, noise textures, geometric patterns, layered transparencies,
and dramatic shadows create atmosphere. Solid flat colours are rarely the right choice.

**Match complexity to the vision.** Maximalist directions need elaborate execution;
minimal directions need precision in spacing, type, and detail. Elegance is executing
the chosen vision well — not adding more.

Emit audit entry for Step 4.

### Step 5: Write the Copy

MANDATORY: load `@references/copy-and-validation.md` before writing user-visible copy.

Copy writing is required whenever the implementation includes user-visible text that is
not pre-specified in the brief (labels, CTAs, error messages, empty states, onboarding
text). If all copy is provided verbatim in the brief, this step is read-only.

Reference: `references/copy-and-validation.md` — UX copy principles section.

### Step 6: Validate and Critique

MANDATORY: load `@references/copy-and-validation.md` before running the validation checklist.

Reference: `references/copy-and-validation.md` — validation checklist section.

Emit session-end audit entry after Step 6 completes.
