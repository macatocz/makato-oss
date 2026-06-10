# makato Design System — DESIGN.md

A reusable design system for the makato framework.
Dark-first, tech-utility posture. Terminal-inspired chrome with a single saturated blue accent.

---

## 1. Color tokens

All colors are defined as CSS custom properties on `:root` and switched via `data-theme`.

### Base palette (theme-aware)

```css
:root {
  /* Accent palette — shared across themes */
  --accent:       #0070F2;
  --accent-light: #00B8F1;
  --accent-glow:  rgba(0, 112, 242, 0.15);
  --green:        #34D399;
  --green-dim:    rgba(52, 211, 153, 0.12);
  --amber:        #FBBF24;
  --amber-dim:    rgba(251, 191, 36, 0.12);
  --purple:       #A78BFA;
  --purple-dim:   rgba(167, 139, 250, 0.12);
  --cyan:         #22D3EE;
}

[data-theme="dark"] {
  --bg:           #0A0E14;
  --surface:      #111820;
  --surface-2:    #1A2230;
  --surface-3:    #222E3E;
  --fg:           #E8EDF5;
  --muted:        #7B8FA6;
  --border:       #1E2A3A;
  --border-light: #2A3A4E;
  --nav-bg:       rgba(10, 14, 20, 0.92);
}

[data-theme="light"] {
  --bg:           #F8FAFC;
  --surface:      #FFFFFF;
  --surface-2:    #F1F5F9;
  --surface-3:    #E2E8F0;
  --fg:           #0F172A;
  --muted:        #64748B;
  --border:       #E2E8F0;
  --border-light: #CBD5E1;
  --nav-bg:       rgba(248, 250, 252, 0.92);
}
```

### Usage rules

- `--accent` is the only saturated color used for interactive elements (links, CTAs, active states, section labels).
- Status colors (`--green`, `--amber`, `--purple`) are used ONLY inside status indicators and category pills — never as decoration.
- `--cyan` is a decorative-only accent for gradient endpoints. Never use it for text or interactive states.
- Card backgrounds are `--surface`. Nested panels use `--surface-2`. Deep nesting may use `--surface-3` sparingly.
- Borders are always `1px solid var(--border)`. Use `--border-light` only for secondary separators within cards.

---

## 2. Typography

### Font stacks

```css
:root {
  --font:      '72 Brand', '72', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  --font-mono: 'SF Mono', 'JetBrains Mono', 'IBM Plex Mono', ui-monospace, Menlo, monospace;
}
```

### Type scale

| Level | Size | Weight | Letter-spacing | Usage |
|-------|------|--------|----------------|-------|
| Display | `clamp(36px, 4vw, 56px)` | 900 (Black) | `-0.03em` | Page hero headlines |
| H1 | `clamp(24px, 3vw, 36px)` | 900 | `-0.02em` | Section titles |
| H2 | `20px` | 700 | — | Card group headers, chart headers |
| H3 | `18px` | 700 | — | Card titles |
| Body | `16px` | 400 | — | Paragraphs, descriptions |
| Body-sm | `14px` | 500 | — | UI text, card body, secondary info |
| Mono-label | `12px` | 500 | `0.06em` | Nav links, metadata, section labels (uppercase) |
| Mono-xs | `11px` | — | `0.05–0.08em` | Status pills, tags (uppercase) |
| Code | `13px` | 400 | — | Terminal blocks, inline code |

### Rules

- `--font` is used for BOTH display and body. This is a tech-utility system — one family, multiple weights.
- `--font-mono` is used for: nav links, metadata, section labels, terminal blocks, status pills, code, chart values.
- Mono text is ALWAYS uppercase with positive letter-spacing (except code blocks and terminal content).
- Display and H1 use negative letter-spacing. Body and smaller never go negative.
- Line height: 1.1 for display/H1, 1.3 for H2/H3, 1.6–1.7 for body.
- Font-variant-numeric: `tabular-nums` on all mono numerics.

---

## 3. Spacing and layout

### Grid

- Max content width: `1680px`, centered
- Section padding: `100px 64px` (desktop), scales down at breakpoints
- Grid gap pattern: `1px` gap with `background: var(--border)` on the grid container = hairline separators between cells
- Card internal padding: `28px` (standard), `36–44px` (feature panels)

### Radius scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | `3px` | Status pills, tags |
| `--radius-md` | `6px` | Buttons, code blocks, inline badges |
| `--radius-lg` | `8px` | Cards, panels |
| `--radius-xl` | `12px` | Feature blocks, hero panels |

### Borders

- Default: `1px solid var(--border)` — no exceptions
- No shadows on cards. Ever.
- Top accent line: `::before` with `height: 1px; background: linear-gradient(90deg, transparent, var(--accent), transparent)`
- Left accent edge: `3px` width, `linear-gradient(180deg, var(--accent), var(--cyan), transparent)`

---

## 4. Component patterns

### Buttons

```css
.btn-primary {
  background: linear-gradient(135deg, var(--accent), var(--accent-light));
  color: #fff;
  padding: 14px 28px;
  border-radius: 6px;
  font-size: 14px;
  font-weight: 600;
  font-family: var(--font);
  border: none;
}

.btn-ghost {
  color: var(--muted);
  padding: 14px 28px;
  font-size: 14px;
  font-weight: 500;
  border: 1px solid var(--border-light);
  border-radius: 6px;
  background: transparent;
  font-family: var(--font);
}
```

### Cards (hairline grid)

Cards sit inside a grid container with `gap: 1px; background: var(--border)`. Each card has `background: var(--surface)`. On hover: `background: var(--surface-2)`.

### Status pills

```css
.status {
  font-family: var(--font-mono);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 3px 8px;
  border-radius: 3px;
  display: inline-flex;
  align-items: center;
  gap: 5px;
}
.status.live    { color: var(--green);  background: var(--green-dim); }
.status.pilot   { color: var(--amber);  background: var(--amber-dim); }
.status.building { color: var(--purple); background: var(--purple-dim); }
```

Each pill includes a 5px animated dot (`animation: pulse 2s infinite`).

### Navigation

- Fixed, frosted glass: `backdrop-filter: blur(20px)`, `background: var(--nav-bg)`
- Height: `56px`
- Links: `--font-mono`, `12px`, uppercase, `0.06em` spacing, color `--muted` → `--accent` on hover/active
- Active state: 2px bottom accent bar with `box-shadow: 0 0 6px var(--accent)`

### Section headers

```html
<div class="section-label">> Section Name</div>
<h2 class="section-title">The Title</h2>
<p class="section-desc">Description text.</p>
```

The label uses `--font-mono`, uppercase, `--accent` color, prefixed with `>` in `--green`.

---

## 5. Iconography

This system does NOT use an icon library. Visual hierarchy is achieved through:

### Terminal symbols as icons

| Symbol | Color | Usage |
|--------|-------|-------|
| `$` | `--green` | Command prompt |
| `>` | `--green` | Section label prefix |
| `✓` | `--green` | Success / check |
| `→` | `--accent` | Navigation, CTAs |
| `←` | `--muted` | Back navigation |
| `↗` | `--accent` | External links |

### Status indicators

- 5px colored circles with `animation: pulse 2s infinite`
- Colors: green (live), amber (pilot/warning), purple (building/in-progress)
- Always paired with an uppercase mono label

### Decorative patterns

- Animated cursor (`2px` wide, `--accent`, blinking)
- Grid background: `rgba(0,112,242,0.07)` lines at 80px intervals
- Gradient accent lines (horizontal and vertical) for visual hierarchy

---

## 6. Motion

### Timing functions

| Name | Value | Usage |
|------|-------|-------|
| Reveal | `cubic-bezier(.16, 1, .3, 1)` | Scroll-triggered animations |
| Standard | `ease` / `.2s` | Hover states, color transitions |
| Theme | `.3s` | Background/color theme transitions |

### Keyframes

| Name | Behaviour | Duration |
|------|-----------|----------|
| `slideUp` | `translateY(16px) → 0`, `opacity 0 → 1` | 0.4s per item, staggered |
| `pulse` | `opacity 1 → 0.4 → 1` | 2–2.5s, infinite |
| `blink` | `opacity 1 → 0 → 1` (step) | 1s, infinite |
| `shimmer` | `background-position` sweep | 3s, infinite |
| `glow` | `box-shadow` intensity pulse | 3s, infinite |

### Rules

- Stagger children with `animation-delay` increments of `.4s`
- Use `IntersectionObserver` for scroll reveals (add `.visible` class)
- No motion on `prefers-reduced-motion: reduce`

---

## 7. Dark/Light switching

- Default: dark (`data-theme="dark"` on `<html>`)
- Toggle button uses `--font-mono`, border-pill style
- Transition: `.3s` on background and color
- Persist preference to `localStorage`

---

## 8. Responsive breakpoints

| Breakpoint | Behaviour |
|------------|-----------|
| `> 1024px` | Full grid layouts (3-col cards, 2-col hero) |
| `≤ 1024px` | 2-col grids, stacked hero, reduced padding |
| `≤ 768px` | Single column, nav hamburger, 32px padding |

---

## 9. Anti-patterns (never do these)

- ❌ Rounded cards with left colored border accent (our left-edge accent is a 3px gradient, not a colored border)
- ❌ Drop shadows on cards (we use borders only)
- ❌ More than one accent color on a single component
- ❌ Non-mono text in labels, pills, or metadata
- ❌ Gradients as section backgrounds (gradients are for accent lines and buttons only)
- ❌ Generic emoji icons
- ❌ Body text below 14px
- ❌ Serif fonts anywhere
