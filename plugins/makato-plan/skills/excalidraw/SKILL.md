---
name: excalidraw
description: >-
  Generate Excalidraw diagrams from text with Obsidian (.md), Standard
  (.excalidraw), or Animated output. Use when creating flowcharts, architecture
  diagrams, mind maps, or any diagram from a text description.
  Keywords: excalidraw, diagram, flowchart, mindmap, visualization, animate.
version: "1.5.0"
argument-hint: "<diagram description> [obsidian|standard|animated]"
allowed-tools: [Write, Bash]
metadata:
  authors: [makato-plan]
  last_updated: "2026-08-05"
---
# Excalidraw Diagram Generator

Create Excalidraw diagrams from text content with multiple output formats.

## Output Modes

| Trigger Words                                           | Mode                         | Format          | Usage                       |
| ------------------------------------------------------- | ---------------------------- | --------------- | --------------------------- |
| `excalidraw`, `diagram`, `flowchart`, `mindmap` | **Obsidian** (default) | `.md`         | Open in Obsidian            |
| `standard excalidraw`                                 | **Standard**           | `.excalidraw` | Open on excalidraw.com      |
| `excalidraw animation`, `animate`                   | **Animated**           | `.excalidraw` | Use with excalidraw-animate |

## Workflow

1. **Detect output mode** from trigger words (see Mode Disambiguation below for conflicts)
2. **Analyze content** — identify concepts, relationships, hierarchy
3. **Choose diagram type** using the Diagram Type Decision Heuristics below
4. **Generate JSON** — MANDATORY: load [references/excalidraw-schema.md](references/excalidraw-schema.md) at this step (not before)
   - `fontFamily` must be `5` (Excalifont only)
   - Arrow/line elements require a `points` array — never omit it
   - Use `startArrowhead`/`endArrowhead` (not `startArrowType`/`endArrowType`)
   - Omit `frameId`, `index`, `versionNonce`, `rawText` fields
   - Use `boundElements: null` (not `[]`)
   - Text `fontSize` minimum 14px; avoid light gray text on white background
   - Calculate text fit before placing; respect max chars/line from schema reference
   - Phase boxes: max 4 lines — abbreviate content, do not expand the container
   - Set text `height` ≥ `lineCount × fontSize × 1.25`
5. **Save file** to the project root:
   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")
   ```
   Write to `$PROJECT_ROOT/<filename>`. If Write fails, output the full JSON inline so the user can save it manually.
6. **Report** file path and mode-specific opening instructions (and diagram type rationale when the type selection was non-obvious)

## Mode Disambiguation

When trigger words conflict or are absent:

| Situation | Resolution |
|-----------|-----------|
| No trigger word but diagram intent is clear | Default to **Obsidian** mode |
| Both `animate` and `excalidraw` present | **Animated** wins (more specific trigger) |
| `standard` without `excalidraw` | Default to **Obsidian** (insufficient trigger) |
| User specifies `.excalidraw` extension explicitly | **Standard** mode |
| User mentions Obsidian vault or `.md` output | **Obsidian** mode |
| Trigger words conflict and intent is genuinely unclear | Use AskUserQuestion (see below) |

**When to ask the user:** If after applying the table above the mode is still ambiguous (e.g., user says "create an excalidraw" but also asks for Obsidian output AND animation), use AskUserQuestion with selectable options — do not silently default:

```
Which output format do you want?
A) Obsidian (.md) — open in Obsidian vault
B) Standard (.excalidraw) — open on excalidraw.com
C) Animated (.excalidraw) — play with excalidraw-animate
```

## Diagram Type Decision Heuristics

Apply these rules in order. The first match wins.

| Condition in the content | Diagram Type | Non-obvious reason to prefer it |
|--------------------------|--------------|----------------------------------|
| Decision forks (yes/no branches) or state transitions are present | **Flowchart** | Process steps without branching look identical to timelines — the fork is the differentiator |
| Single focal concept with ≥4 radiating sub-topics and no strict sequence | **Mind Map** | Radial layout makes implicit importance hierarchy via proximity; a hierarchy diagram would impose false parent-child ordering |
| Strict parent-child decomposition, depth ≥3 levels, no cross-links | **Hierarchy** | Cross-links make Hierarchy misleading; use Relationship if any node has two parents |
| Two independent classification axes (both rows and columns are meaningful) | **Matrix** | Only valid when the intersection of row+column has semantic content; a list of criteria is not a matrix |
| Comparing 2–4 discrete options against the same set of criteria | **Comparison** | Side-by-side layout prevents false equivalence that a matrix implies |
| Temporal sequence with specific events, dates, or milestones | **Timeline** | Time is the primary ordering axis; use Flowchart if there are also conditional branches |
| Arbitrary cross-cutting dependencies (a node may have ≥2 parents or cycles) | **Relationship** | Graph structure; Hierarchy will silently misrepresent any node with multiple incoming edges |
| Unstructured input, early-stage notes, or whiteboard capture | **Freeform** | No imposed structure; elements float without alignment grid constraints |

**When content fits no canonical type above:** Default to **Freeform** for one ambiguous case. For requests involving two distinct structural patterns (e.g., a temporal roadmap with cross-dependencies), ask the user which structural dimension is primary before generating.

**When a single request contains multiple independent diagrams** (e.g., "draw both the architecture and the data flow"): generate each as a separate file following the naming convention, then report all file paths together.

## Diagram Types Reference

| Type                   | Use Case                             |
| ---------------------- | ------------------------------------ |
| **Flowchart**    | Step-by-step processes, workflows    |
| **Mind Map**     | Concept expansion, brainstorming     |
| **Hierarchy**    | Org structures, system decomposition |
| **Relationship** | Dependencies, interactions           |
| **Comparison**   | Contrasting options side-by-side     |
| **Timeline**     | Event progression, milestones        |
| **Matrix**       | Two-dimensional classification       |
| **Freeform**     | Scattered notes, initial gathering   |

## Output Formats

### Obsidian (Default)

```markdown
---
excalidraw-plugin: parsed
tags: [excalidraw]
---
==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'

# Excalidraw Data

## Text Elements
%%
## Drawing
\`\`\`json
{JSON data with source: "https://github.com/zsviczian/obsidian-excalidraw-plugin"}
\`\`\`
%%
```

### Standard / Animated

Pure JSON file with `source: "https://excalidraw.com"`. For animated mode, add `customData.animate` to each element (see schema reference).

## File Naming

| Mode     | Format                                | Example                                       |
| -------- | ------------------------------------- | --------------------------------------------- |
| Obsidian | `[topic].[type].md`                 | `architecture.flowchart.md`                 |
| Standard | `[topic].[type].excalidraw`         | `architecture.flowchart.excalidraw`         |
| Animated | `[topic].[type].animate.excalidraw` | `architecture.flowchart.animate.excalidraw` |

## Anti-patterns

**NEVER omit the `points` array on arrow or line elements** — arrows without `points` render as zero-size invisible dots that silently block mouse interaction; no parse error is raised, making the bug impossible to diagnose from the file alone.

**NEVER use `boundElements: []` (empty array)** — Excalidraw's parser treats `[]` as a broken bound state, permanently preventing interactive connections to that element. `null` is the correct sentinel for "no bindings"; `[]` has no valid use in generated output.

**NEVER add `frameId`, `index`, `versionNonce`, or `rawText` to generated JSON** — these are internal runtime fields written by the Excalidraw engine on first save. Injecting them causes version-conflict exceptions when the file is re-saved and corrupts the element history silently.

**NEVER use `startArrowType`/`endArrowType` property names** — these properties do not exist in the Excalidraw schema. The correct names are `startArrowhead`/`endArrowhead`. The wrong names are silently ignored, producing plain lines with no error and no visual indication of the problem.

**NEVER use `fontFamily` other than `5` (Excalifont)** — families 1–4 depend on the user's local font installation. Excalifont (5) is bundled with the Excalidraw plugin and is the only cross-platform safe choice; other families fall back inconsistently across browsers and Obsidian versions, breaking text sizing calculations.

**NEVER expand a container to fit overflowing text** — growing a phase box shifts every downstream element and breaks the layout grid. The content-first rule: abbreviate or combine lines until they fit the defined container, never the reverse. Four lines is the hard cap for a standard phase box.

**NEVER use light gray text on white background** (e.g., `#b0b0b0`, `#999`) — at 14px these fail the WCAG AA requirement of 4.5:1 contrast ratio for normal text, making labels illegible when printed or viewed on low-contrast displays. Minimum safe foreground value on white: `#757575` (achieves exactly 4.5:1).

**NEVER set `updated` to a real Unix timestamp** — the Excalidraw parser normalizes this field to `1` on first save, producing unnecessary diff noise in version-controlled Obsidian vaults and making the file appear perpetually modified.

## Edge Cases and Limits

### Element Count Threshold

Beyond ~150 elements a single Excalidraw diagram becomes difficult to navigate and can degrade rendering performance. When element count would exceed this threshold:

1. Identify natural partition boundaries (e.g., by system layer, by phase, by domain).
2. Generate one file per partition using the same naming convention with a suffix: `architecture.system.excalidraw`, `architecture.data.excalidraw`.
3. Report all file paths and describe the partition logic so the user can navigate between diagrams.

### Obsidian Schema Field Compatibility

The Excalidraw plugin for Obsidian adds schema fields over time (e.g., `autoResize`, `lineHeight`). These newer fields are safe in current plugin versions but produce serialization warnings in older vaults. When the target Obsidian plugin version is unknown, restrict generated elements to the core fields defined in the base element template of the schema reference. Only include newer optional fields when the user explicitly targets a current Obsidian environment.

### Bidirectional Relationships

When two nodes in a Relationship or Flowchart diagram reference each other, use a single arrow element with both `startArrowhead` and `endArrowhead` set rather than two overlapping arrows. Two overlapping arrows are valid JSON but create z-order flicker and make the diagram harder to edit interactively.

## User Feedback

After generating, report:

- Save location (absolute path)
- How to open (Obsidian view switch / excalidraw.com / excalidraw-animate)
- Diagram type chosen and why — especially when the selection was non-obvious or required a heuristic judgment

Keep the report concise. The example below shows the minimum useful content for Standard mode:

```
Excalidraw diagram generated!
Saved to: /path/to/project/architecture.flowchart.excalidraw

Usage:
1. Open https://excalidraw.com
2. Menu -> Open -> select file (or drag onto page)
```

## Technical Reference

**MANDATORY at Step 4 only:** Load [references/excalidraw-schema.md](references/excalidraw-schema.md) when generating the JSON element array.

**Do NOT load** this reference at Steps 1–3 (mode detection, content analysis, diagram type selection) — it is 472 lines of dense schema content that serves no purpose before element generation begins.

**For Animated mode:** Read only the "Animation properties" section of references/excalidraw-schema.md — locate the section heading and read from that point to the next top-level heading. Do not re-read the full file if it was already loaded in Step 4; scan the already-loaded content for the animation section instead.

Key sections in the reference:

- Base element template (required fields)
- Arrow elements (CRITICAL: requires `points` array)
- **Text Fitting (CRITICAL)** — width estimation, container sizing, multi-line strategy
- Color palette (text & background colors)
- Layout guidelines (canvas, spacing, font sizes)
- Animation properties (Animated mode only)
