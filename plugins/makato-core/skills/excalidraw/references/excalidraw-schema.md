# Excalidraw JSON Schema Reference

## Full JSON Structure

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [...],
  "appState": {
    "gridSize": null,
    "viewBackgroundColor": "#ffffff"
  },
  "files": {}
}
```

**Source values:**
- Obsidian mode: `"https://github.com/zsviczian/obsidian-excalidraw-plugin"`
- Standard/Animated mode: `"https://excalidraw.com"`

---

## Base Element Template

All elements require these fields. Do NOT add `frameId`, `index`, `versionNonce`, or `rawText` - they cause parsing errors.

```json
{
  "id": "unique-id",
  "type": "rectangle",
  "x": 100,
  "y": 100,
  "width": 200,
  "height": 50,
  "angle": 0,
  "strokeColor": "#1e1e1e",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 1,
  "opacity": 100,
  "groupIds": [],
  "roundness": {"type": 3},
  "seed": 123456789,
  "version": 1,
  "isDeleted": false,
  "boundElements": null,
  "updated": 1,
  "link": null,
  "locked": false
}
```

**Critical rules:**
- `boundElements`: Must be `null`, NOT `[]`
- `updated`: Must be `1`, NOT timestamps

---

## Element Types

### Rectangle
```json
{
  "type": "rectangle",
  "id": "unique-id",
  "x": 100, "y": 100,
  "width": 200, "height": 80,
  "strokeColor": "#1e40af",
  "backgroundColor": "#dbeafe",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "roughness": 1,
  "opacity": 100,
  "roundness": {"type": 3}
}
```

### Ellipse
```json
{
  "type": "ellipse",
  "id": "unique-id",
  "x": 100, "y": 100,
  "width": 120, "height": 120,
  "strokeColor": "#10b981",
  "backgroundColor": "#d1fae5",
  "fillStyle": "solid"
}
```

### Diamond
```json
{
  "type": "diamond",
  "id": "unique-id",
  "x": 100, "y": 100,
  "width": 150, "height": 100,
  "strokeColor": "#f59e0b",
  "backgroundColor": "#fef3c7",
  "fillStyle": "solid"
}
```

### Text

Additional properties for text (do NOT include `rawText`):

```json
{
  "type": "text",
  "id": "unique-id",
  "x": 150, "y": 130,
  "width": 100, "height": 25,
  "text": "Display text",
  "fontSize": 20,
  "fontFamily": 5,
  "textAlign": "center",
  "verticalAlign": "middle",
  "strokeColor": "#1e40af",
  "backgroundColor": "transparent",
  "containerId": null,
  "originalText": "Display text",
  "autoResize": true,
  "lineHeight": 1.25
}
```

### Arrow (CRITICAL - requires points array)

**Arrows MUST include `points` array or they won't render:**

```json
{
  "type": "arrow",
  "id": "unique-id",
  "x": 300,
  "y": 140,
  "width": 100,
  "height": 80,
  "angle": 0,
  "strokeColor": "#3b82f6",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 1,
  "opacity": 100,
  "groupIds": [],
  "roundness": {"type": 2},
  "seed": 123456789,
  "version": 1,
  "isDeleted": false,
  "boundElements": null,
  "updated": 1,
  "link": null,
  "locked": false,
  "points": [[0, 0], [100, 80]],
  "startBinding": null,
  "endBinding": null,
  "lastCommittedPoint": null,
  "startArrowhead": null,
  "endArrowhead": "arrow"
}
```

**Arrow-specific requirements:**
- `points`: REQUIRED - `[[0, 0], [width, height]]` relative to element origin
- `startArrowhead`: `null` or `"arrow"`
- `endArrowhead`: `null` or `"arrow"`
- `roundness`: Use `{"type": 2}` for arrows
- Do NOT use `startArrowType`/`endArrowType` (wrong property names)

### Line (also requires points array)

```json
{
  "type": "line",
  "id": "unique-id",
  "x": 100, "y": 100,
  "width": 200, "height": 100,
  "points": [[0, 0], [200, 100]],
  "strokeColor": "#374151",
  "strokeWidth": 2
}
```

---

## Element Binding

### Text to Container
```json
// Container
{
  "type": "rectangle",
  "id": "container-id",
  "boundElements": [{"id": "text-id", "type": "text"}]
}

// Text
{
  "type": "text",
  "id": "text-id",
  "containerId": "container-id"
}
```

### Arrow to plans
```json
{
  "type": "arrow",
  "startBinding": {
    "elementId": "source-plan-id",
    "focus": 0,
    "gap": 5
  },
  "endBinding": {
    "elementId": "target-plan-id",
    "focus": 0,
    "gap": 5
  }
}
```

---

## Animation (Animated mode only)

Add `customData.animate` to control animation sequence:

```json
{
  "id": "element-1",
  "type": "rectangle",
  "customData": {
    "animate": {
      "order": 1,
      "duration": 500
    }
  }
}
```

- `order`: Playback sequence (1, 2, 3...), lower = earlier
- `duration`: Drawing time in milliseconds (default 500)
- Same `order` = simultaneous appearance
- Recommended: Title(1) -> Framework(2-4) -> Connectors(5-7) -> Details(8+)

---

## Property Values

### Font Family
| Value | Font |
|-------|------|
| 1 | Virgil (hand-drawn) |
| 2 | Helvetica |
| 3 | Cascadia |
| 4 | Assistant |
| **5** | **Excalifont (required)** |

### Stroke Style
- `"solid"` - Default, continuous line
- `"dashed"` - Optional paths, async flows, weak associations
- `"dotted"` - Subtle connections

### Fill Style
- `"solid"` - Solid fill (recommended)
- `"hachure"` - Hatched lines
- `"cross-hatch"` - Cross-hatched
- `"dots"` - Dotted pattern

### Roundness
- `{"type": 1}` - Sharp corners
- `{"type": 2}` - Slight rounding (use for arrows)
- `{"type": 3}` - Full rounding (recommended for plans)

---

## Color Palette

### Text Colors (strokeColor)
| Purpose | Hex | Description |
|---------|-----|-------------|
| Title | `#1e40af` | Deep blue |
| Subtitle/Connectors | `#3b82f6` | Bright blue |
| Body text | `#374151` | Dark gray |
| Emphasis | `#f59e0b` | Gold |
| Success | `#10b981` | Green |
| Warning | `#ef4444` | Red |

### plan Fill Colors (backgroundColor)
| Hex | Semantic | Use Case |
|-----|----------|----------|
| `#a5d8ff` | Light blue | Input, data source, primary nodes |
| `#b2f2bb` | Light green | Success, output, completed |
| `#ffd8a8` | Light orange | Warning, pending, external |
| `#d0bfff` | Light purple | In progress, middleware |
| `#ffc9c9` | Light red | Error, critical, alerts |
| `#fff3bf` | Light yellow | Notes, decisions, planning |
| `#c3fae8` | Light cyan | Storage, data, cache |
| `#eebefa` | Light pink | Analysis, metrics |

### Region Backgrounds (opacity: 30)
| Hex | Semantic |
|-----|----------|
| `#dbe4ff` | Frontend/UI layer |
| `#e5dbff` | Logic/processing layer |
| `#d3f9d8` | Data/tools layer |

### Contrast Rules
- Text on white: minimum `#757575`
- On light fills: use dark variants (e.g., `#15803d` on light green)
- Avoid `#b0b0b0`, `#999` on white

---

## Layout Guidelines

### Canvas & Spacing
- **Canvas bounds**: 0-1200 x 0-800 pixels
- **Padding**: 50-80px from edges
- **Element spacing**: minimum 20-30px gap
- **Minimum plan size**: 120x60px for text containers
- **Coordinate origin**: Top-left (0,0)

### Font Sizes
| Element | Size | Minimum |
|---------|------|---------|
| Title | 20-28px | 20px |
| Subtitle | 18-20px | 18px |
| Body/labels | 16-18px | 16px |
| Annotations | 14px | 14px (absolute min) |

### Text Centering
Standalone text `x` is left edge, not center. Calculate manually:
```
estimatedWidth = text.length * fontSize * 0.5  (use 1.0 for CJK)
x = centerX - estimatedWidth / 2
```

### Text Replacements
- `"` -> `『』`
- `()` -> `「」`

---

## Text Fitting (CRITICAL)

Text overflow is the #1 cause of broken diagrams. Follow these rules strictly.

### Width Estimation Formula

```
textWidth = characterCount * fontSize * charWidthFactor
textHeight = lineCount * fontSize * lineHeight

charWidthFactor:
- Latin letters: 0.5
- Numbers: 0.5
- Spaces: 0.3
- CJK characters: 1.0
- Symbols (|, -, +): 0.4
```

### Container Sizing Rules

**Always size container AFTER calculating text dimensions:**

```
containerWidth = textWidth + (2 * horizontalPadding)
containerHeight = textHeight + (2 * verticalPadding)

Minimum padding: 15px each side
Recommended padding: 20-30px each side
```

**Example calculation:**
```
Text: "Success Metrics: Lead Time 2-3 days"
Characters: 36
fontSize: 16
textWidth = 36 * 16 * 0.5 = 288px
containerWidth = 288 + (2 * 20) = 328px minimum
```

### Multi-line Text Strategy

When text is too long for available width:

1. **Break into multiple lines** using `\n`
2. **Recalculate height**: `height = lineCount * fontSize * 1.25`
3. **Keep lines balanced**: aim for similar character counts per line
4. **CRITICAL: Set text element `height` to match calculated value** - Excalidraw clips text that exceeds the element's height dimension
5. **Prefer reducing content over expanding containers** - if text doesn't fit, abbreviate or combine lines rather than growing the box

**Example - fitting content to container:**
```
// BAD: 5 lines doesn't fit in standard phase box (90px height)
"Phase 3: Development\n30-60 min\nSmart Context\nAI Pair Program\nQuality Gates"

// GOOD: Combine to 4 lines (fits 70px text height + padding)
"Phase 3: Development\n30-60 min\nAI Pair + Smart Context\nQuality Gates"
```

### Maximum Characters Per Line

| fontSize | Max chars (Latin) | Max chars (CJK) |
|----------|-------------------|-----------------|
| 28px | 35 chars | 17 chars |
| 20px | 50 chars | 25 chars |
| 16px | 60 chars | 30 chars |
| 14px | 70 chars | 35 chars |

**Rule**: If text exceeds max chars, split into multiple lines.

### Annotation Text Guidelines

For small annotations (like "QA prep can start while Dev codes"):

1. Use smaller fontSize (12-14px)
2. Position OUTSIDE main flow elements
3. Keep under 30 characters per line
4. Use muted colors (`#6b7280` or `#f59e0b`)

### Container Width Checklist

Before finalizing any text element:

1. Count characters (including spaces and symbols)
2. Calculate estimated width using formula
3. Compare to container/canvas bounds
4. If overflow: split lines OR reduce font size OR abbreviate text
5. Re-verify after changes

### Common Text Fitting Mistakes

| Mistake | Example | Fix |
|---------|---------|-----|
| Long metrics in narrow box | "Lead Time 2-3 days \| Cycle..." cut off | Break into bullet points or multiple lines |
| Title wider than diagram | 50-char title over 400px diagram | Shorten title or use subtitle |
| Dense text in small box | 5 lines in 70px tall box | **Reduce content to 4 lines**, don't expand box |
| Annotation overlapping elements | Note text crosses into next box | Reposition with proper spacing |
| Text height mismatch | 4 lines but height: 50 | Set height = 4 × 14 × 1.25 = 70px |

### Content-First Sizing Rule

**Always fit content to container, not container to content:**

1. Define container size first based on layout constraints
2. Calculate max lines: `maxLines = floor(containerHeight / (fontSize × 1.25))`
3. If content exceeds max lines, abbreviate or combine text
4. Never exceed 4 lines in a standard phase box (90px height)

### Safe Defaults

When in doubt, use these conservative values:

| Element Type | Box Size | Text Height | Max Lines | fontSize |
|--------------|----------|-------------|-----------|----------|
| Title | 800×40px | 35px | 1 | 28px |
| Phase box | 180×90px | 70px | 4 | 14px |
| Annotation | 180×40px | 35px | 2 | 14px |
| Metrics row | 750×60px | 35px | 2 | 14px |
| Lane label | 60×30px | 25px | 1 | 18px |

**Phase box calculation:** 4 lines × 14px × 1.25 = 70px text height + 20px padding = 90px box
