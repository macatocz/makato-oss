# Design System Extraction Guide

Instructions for the context-scout when searching repositories for design system artifacts. Load this reference when dispatching the scout for prototype-related research.

---

## What to Search For

### Design Tokens (Priority: Critical)

| Pattern | What it indicates |
|---------|------------------|
| `tokens.json`, `design-tokens.json`, `tokens.yml` | Token definition files |
| `variables.scss`, `variables.css`, `_variables.less` | CSS/preprocessor token files |
| `:root { --` or `$` variable declarations | Inline token definitions |
| `theme.ts`, `theme.js`, `theme.config.*` | JS/TS theme configuration |
| `tailwind.config.*` | Tailwind customization (extends section = tokens) |

Extract: colors (primary, secondary, semantic), spacing scale, typography (font families, sizes, weights, line-heights), border-radii, shadows, z-index scale, breakpoints.

### Component Patterns (Priority: High)

| Pattern | What it indicates |
|---------|------------------|
| `components/`, `src/components/`, `lib/components/` | Component library |
| `*.stories.ts`, `*.stories.tsx`, `.storybook/` | Storybook configuration |
| `Button.*`, `Modal.*`, `Form.*`, `Table.*` | Individual component files |
| `index.scss`, `styles.module.css` alongside components | Component-scoped styles |

Extract: button variants (primary, secondary, danger), form field styles, modal/dialog patterns, navigation patterns (sidebar, topbar, tabs), table/list layouts, card patterns.

### Layout Conventions (Priority: High)

| Pattern | What it indicates |
|---------|------------------|
| `layout/`, `layouts/`, `templates/` | Layout definitions |
| `grid`, `flex`, `container` in CSS | Layout system |
| `@media` queries | Responsive breakpoints |
| `sidebar`, `nav`, `header`, `footer` | Page structure |

Extract: grid column count, max-width/container sizes, responsive breakpoints, sidebar width, header height, page padding.

### External Design System References (Priority: Critical)

| Pattern | What it indicates |
|---------|------------------|
| `@anthropic/design-system`, `@glow/*`, `@fundamental-styles/*` | Package dependency on shared DS |
| `import ... from '@glow/`  or similar | Direct DS imports |
| `angular.json` → `styles` array with DS paths | Angular DS integration |
| `stylePreprocessorOptions` → `includePaths` | SCSS include paths pointing to DS |
| `.npmrc` with registry URLs | Private registry hosting DS packages |

When found: note the package name, version (from package.json/lock file), and any configuration. The design system may define all tokens — the repo just consumes them.

---

## Search Strategy

1. Start with `package.json` (or `angular.json`, `vue.config.*`, `next.config.*`) to identify framework and design system dependencies
2. If external DS found → note name/version, look for local overrides or extensions
3. If no external DS → scan for local token files (CSS variables, SCSS variables, theme configs)
4. Always check for Storybook (`.storybook/`) — richest source of component patterns
5. Look at 2-3 existing page components to understand real layout patterns in use

---

## Output Format

Return findings as a structured design context:

```markdown
## Design System Context

**Source**: {local tokens | external DS name + version | both}

### Tokens
- Colors: {primary: #xxx, secondary: #xxx, ...}
- Typography: {font-family, size scale}
- Spacing: {scale or values}
- Radii: {values}
- Shadows: {values}

### Components Found
- Buttons: {variants and styles}
- Forms: {input patterns}
- Navigation: {pattern}
- Modals: {pattern}
- Tables: {pattern}

### Layout
- Grid: {system}
- Breakpoints: {values}
- Page structure: {description}

### External DS
- Name: {if found}
- Version: {if found}
- Local overrides: {if any}
```
