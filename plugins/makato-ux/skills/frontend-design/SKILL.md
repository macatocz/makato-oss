---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces — HTML/CSS, React, components, pages, dashboards, landing pages, web UI. Use when building or styling any web interface, avoiding generic AI aesthetics in favour of bold intentional design.
version: "1.1.0"
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

### Step 2: Discover Design System

If the target codebase exists, scan for design tokens before writing anything:

- Look for CSS custom properties (`--color-*`, `--spacing-*`, `--font-*`) in global stylesheets
- Check for `tailwind.config.*`, `theme.ts`, or design token files
- Look for component library imports (`@radix-ui`, `shadcn`, `mui`, custom packages)

Use discovered tokens exclusively. Fall back to custom CSS variables only when no design
system exists. Avoid Bootstrap, Material Design defaults unless they are the project standard.

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

**Then review that plan against the brief.** AI-generated design right now clusters
around three looks that appear regardless of subject:

1. Warm cream background (near `#F4F1EA`), high-contrast serif display, terracotta accent.
2. Near-black background with a single bright acid-green or vermilion accent.
3. Broadsheet layout — hairline rules, zero border-radius, dense newspaper columns.

All three are legitimate *when the brief asks for them* — the brief's own words always
win. But where the brief leaves an axis free, don't spend that freedom on a default. If
any part of your plan reads like the generic answer you would produce for any similar
page, revise it, and note what you changed and why. Only after confirming the plan's
relative uniqueness should you start writing code — then follow the plan exactly.

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

### Step 5: Write the Copy

Words appear in a design for one reason: to make it easier to understand, and therefore
easier to use. They are design material, not decoration — bring the same intentionality
to copy you bring to spacing and color. Generic copy makes a design feel as templated as
generic layout does.

- **Write from the end user's side of the screen.** Name things by what people control
  and recognize, never by how the system is built. A person manages notifications, not
  webhook config. Be specific rather than clever.
- **Use active voice.** A control says exactly what happens when used: "Save changes,"
  not "Submit." An action keeps the same name through the whole flow — the button that
  says "Publish" produces a toast that says "Published."
- **Treat failure and emptiness as direction, not mood.** Errors explain what went wrong
  and how to fix it, in the interface's voice; they don't apologize and are never vague.
  An empty screen is an invitation to act.
- **Keep the register conversational and tuned** — plain verbs, sentence case, no filler,
  tone matched to brand and audience. Each element does one job: a label labels, an
  example demonstrates.

### Step 6: Validate and Critique

Before declaring complete, confirm the quality floor:

1. Verify all interactive elements have visible focus states (keyboard navigation).
2. Check colour contrast ratios meet WCAG AA for all text.
3. Confirm responsive behaviour at mobile (375px), tablet (768px), and desktop (1280px).
4. Confirm reduced-motion is respected.
5. Confirm no external CDN dependencies — code must run self-contained.

Then critique your own work. Spend your boldness in one place: let the signature element
be the one memorable thing and keep everything around it disciplined. Cut any decoration
that does not serve the brief. Consider Chanel's advice — before leaving the house, look
in the mirror and remove one accessory.
