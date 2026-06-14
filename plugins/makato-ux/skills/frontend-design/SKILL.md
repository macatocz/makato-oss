---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces — HTML/CSS, React, components, pages, dashboards, landing pages, web UI. Use when building or styling any web interface, avoiding generic AI aesthetics in favour of bold intentional design.
version: "1.0.0"
---

# frontend-design

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

### Step 1: Understand Context

Before writing a single line of code, establish:

1. **Purpose** — what problem does this interface solve? Who uses it?
2. **Tone** — commit to a clear aesthetic direction: brutally minimal, maximalist,
   retro-futuristic, organic, luxury, editorial, brutalist, art-deco, soft/pastel,
   industrial. Choose one and execute it with precision.
3. **Constraints** — framework (HTML/CSS, React, Vue), performance requirements,
   accessibility level, design system tokens if available
4. **Differentiation** — what makes this interface memorable? Define it upfront.

### Step 2: Discover Design System

If the target codebase exists, scan for design tokens before writing anything:

- Look for CSS custom properties (`--color-*`, `--spacing-*`, `--font-*`) in global stylesheets
- Check for `tailwind.config.*`, `theme.ts`, or design token files
- Look for component library imports (`@radix-ui`, `shadcn`, `mui`, custom packages)

Use discovered tokens exclusively. Fall back to custom CSS variables only when no design
system exists. Avoid Bootstrap, Material Design defaults unless they are the project standard.

### Step 3: Implement

Write production-grade, functional code applying these principles:

**Typography** — choose fonts that are distinctive. Avoid Inter, Roboto, Arial, and
system-font stacks unless the design explicitly demands them. Pair a display font with a
refined body font.

**Color** — commit to a cohesive palette with CSS variables. Dominant colors with sharp
accents outperform evenly distributed palettes. Consider both dark and light themes.

**Motion** — use animations for micro-interactions and page load. CSS-only for HTML
artifacts; Motion library for React. One well-orchestrated page-load staggered reveal
creates more delight than scattered hover effects.

**Spatial composition** — use asymmetry, overlap, diagonal flow, or generous negative
space. Avoid predictable grid-box layouts.

**Depth** — gradient meshes, noise textures, geometric patterns, layered transparencies,
and dramatic shadows create atmosphere. Solid flat colours are rarely the right choice.

Write code that matches the aesthetic ambition: maximalist designs need elaborate
animations and effects; minimalist designs need precision in spacing and typography.

### Step 4: Validate

Before declaring complete:

1. Verify all interactive elements have visible focus states (keyboard navigation)
2. Check colour contrast ratios meet WCAG AA for all text
3. Confirm responsive behaviour at mobile (375px), tablet (768px), and desktop (1280px)
4. Confirm no external CDN dependencies — code must run self-contained
