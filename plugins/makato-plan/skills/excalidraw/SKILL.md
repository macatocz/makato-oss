---
name: excalidraw
description: "Generate Excalidraw diagrams from text with Obsidian, Standard, or Animated output. Use when: creating flowcharts, architecture diagrams, mind maps from text descriptions. Keywords: excalidraw, diagram, flowchart, mindmap, visualization, animate."
metadata:
  version: 1.3.0
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

1. **Detect output mode** from trigger words
2. **Analyze content** - identify concepts, relationships, hierarchy
3. **Choose diagram type** (see table below)
4. **Generate JSON** using [references/excalidraw-schema.md](references/excalidraw-schema.md)
5. **Save file** to current working directory
6. **Report** file path and usage instructions

## Diagram Types

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

## User Feedback

After generating, report:

- Save location
- How to open (Obsidian view switch / excalidraw.com / excalidraw-animate)
- Diagram type chosen and why

**Example (Standard mode):**

```
Excalidraw diagram generated!
Saved to: architecture.flowchart.excalidraw

Usage:
1. Open https://excalidraw.com
2. Menu -> Open -> select file (or drag onto page)
```

## Technical Reference

For all JSON schemas, element templates, color palettes, and layout guidelines:

**See [references/excalidraw-schema.md](references/excalidraw-schema.md)**

Key sections:

- Base element template (required fields)
- Arrow elements (CRITICAL: requires `points` array)
- **Text Fitting (CRITICAL)** - width estimation, container sizing, multi-line strategy
- Color palette (text & background colors)
- Layout guidelines (canvas, spacing, font sizes)
- Animation properties (for Animated mode)

## NEVER

- NEVER use `fontFamily` other than `5` (Excalifont)
- NEVER omit `points` array on arrow/line elements
- NEVER use `startArrowType`/`endArrowType` (use `startArrowhead`/`endArrowhead`)
- NEVER include `frameId`, `index`, `versionNonce`, `rawText` fields
- NEVER use `boundElements: []` (must be `null`)
- NEVER set text `fontSize` below 14px
- NEVER use light gray text on white background
- NEVER place text without calculating if it fits the container
- NEVER exceed max characters per line (see Text Fitting in schema reference)
- NEVER exceed 4 lines in a phase box - abbreviate content instead of expanding container
- NEVER set text `height` smaller than `lineCount × fontSize × 1.25`
