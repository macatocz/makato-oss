# UX Design Document Template

## Table of Contents
- [Header](#header)
- [User Analysis](#user-analysis)
- [Information Architecture](#information-architecture)
- [Wireframes](#wireframes)
- [Interaction Patterns](#interaction-patterns)
- [Accessibility](#accessibility)

---

## Header

```markdown
# UX Design: {Feature Name}

**Feature**: {Feature ID} - {Feature Name}
**PRD**: [prd.md](./prd.md)
**Design**: [design.md](./design.md)
**Created**: {Date}
**Status**: Draft | Review | Approved
```

---

## User Analysis

### User Stories with UI Interactions
```markdown
## User Stories

| ID | Story | UI Touchpoints |
|----|-------|----------------|
| US-01 | As a {persona}, I want to {action} | Screen: {name}, Components: {list} |
```

### User Personas
```markdown
## Personas

### Primary: {Name}
- **Role**: {role}
- **Goals**: {goals}
- **Pain Points**: {pain points}
- **Tech Comfort**: Low | Medium | High

### Secondary: {Name}
...
```

### Key User Journeys
```markdown
## User Journeys

### Journey: {Name}
1. **Entry Point**: {where user starts}
2. **Steps**: {numbered steps}
3. **Exit Point**: {where user ends}
4. **Success Criteria**: {what indicates success}
```

---

## Information Architecture

### Screen Inventory
```markdown
## Screens

| Screen | Purpose | Entry Points | Exit Points |
|--------|---------|--------------|-------------|
| Dashboard | Overview of... | Login, Nav | Settings, Detail |
```

### Navigation Structure
```markdown
## Navigation

```
├── Home
├── Feature Area
│   ├── List View
│   ├── Detail View
│   └── Edit View
├── Settings
└── Profile
```
```

### Content Hierarchy
```markdown
## Content Hierarchy

### {Screen Name}
1. Primary: {most important element}
2. Secondary: {supporting elements}
3. Tertiary: {additional info}
```

---

## Wireframes

### ASCII Wireframe Template
```
┌─────────────────────────────────────────────────────┐
│  Logo          Navigation              [User Menu]  │
├─────────────────────────────────────────────────────┤
│ ┌─────────────┐  ┌─────────────────────────────────┐│
│ │             │  │                                 ││
│ │  Sidebar    │  │      Main Content Area          ││
│ │             │  │                                 ││
│ │  - Item 1   │  │  ┌─────────┐  ┌─────────┐      ││
│ │  - Item 2   │  │  │  Card   │  │  Card   │      ││
│ │  - Item 3   │  │  └─────────┘  └─────────┘      ││
│ │             │  │                                 ││
│ └─────────────┘  └─────────────────────────────────┘│
├─────────────────────────────────────────────────────┤
│  Footer: Links | Copyright | Version               │
└─────────────────────────────────────────────────────┘
```

### Mobile Layout Template
```
┌───────────────────┐
│  ☰  Logo    [👤]  │
├───────────────────┤
│                   │
│   Main Content    │
│                   │
│  ┌─────────────┐  │
│  │    Card     │  │
│  └─────────────┘  │
│                   │
├───────────────────┤
│ [🏠] [📋] [⚙️]   │
└───────────────────┘
```

### Form Layout Template
```
┌─────────────────────────────────────┐
│  Form Title                         │
├─────────────────────────────────────┤
│                                     │
│  Label                              │
│  ┌─────────────────────────────┐    │
│  │  Input field                │    │
│  └─────────────────────────────┘    │
│  Helper text or validation          │
│                                     │
│  Label                              │
│  ┌─────────────────────────────┐    │
│  │  Dropdown          [▼]     │    │
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────┐  ┌─────────────────┐   │
│  │ Cancel  │  │  Save [Primary] │   │
│  └─────────┘  └─────────────────┘   │
│                                     │
└─────────────────────────────────────┘
```

---

## Interaction Patterns

### State Documentation Template
```markdown
## States for {Component/Screen}

### Default State
- Initial appearance when component loads
- [wireframe]

### Loading State
- Skeleton/spinner while data fetches
- [wireframe]

### Empty State
- When no data exists
- Message: "{helpful message}"
- CTA: "{action to populate}"
- [wireframe]

### Error State
- When operation fails
- Message: "{error message}"
- Recovery: "{how to fix}"
- [wireframe]

### Success State
- After successful operation
- Feedback: "{confirmation}"
- Next action: "{what happens next}"
```

### Form Behaviors
```markdown
## Form: {Name}

### Validation
| Field | Rules | Error Message |
|-------|-------|---------------|
| Email | Required, format | "Enter valid email" |

### Submission
- On submit: {behavior}
- On success: {navigation/feedback}
- On failure: {error handling}
```

---

## Accessibility

### WCAG Checklist
```markdown
## Accessibility Notes

### Perceivable
- [ ] Color contrast meets AA (4.5:1 text, 3:1 UI)
- [ ] Text alternatives for images
- [ ] Captions for media

### Operable
- [ ] Keyboard navigable (Tab order)
- [ ] Focus indicators visible
- [ ] No keyboard traps

### Understandable
- [ ] Labels for inputs
- [ ] Error identification clear
- [ ] Consistent navigation

### Robust
- [ ] Valid HTML
- [ ] ARIA where needed
- [ ] Screen reader tested
```

### Keyboard Navigation Map
```markdown
## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Tab | Move focus forward |
| Shift+Tab | Move focus backward |
| Enter | Activate button/link |
| Escape | Close modal/cancel |
| Arrow keys | Navigate within component |
```

---

## Component Specifications

### Component Template
```markdown
## Component: {Name}

**Purpose**: {why it exists}
**Used in**: {screens list}

### Props/Inputs
| Name | Type | Required | Default |
|------|------|----------|---------|
| title | string | yes | - |

### States
- Default, Hover, Focus, Active, Disabled

### Responsive Behavior
- Desktop: {behavior}
- Tablet: {behavior}
- Mobile: {behavior}
```
