# Prototype Quality Standards

Quality rules for the prototype-builder agent. Loaded internally by the agent during generation — NOT by the main skill.

---

## Fidelity Requirements

The prototype must look native to the target application. A stakeholder should not immediately recognize it as a prototype.

| Requirement | Pass | Fail |
|-------------|------|------|
| Uses real design tokens | Colors, spacing, typography match target app | Generic Bootstrap/Material defaults |
| Component patterns match | Buttons, forms, cards look like the real app | Unstyled or differently-styled elements |
| Layout matches | Same grid, sidebar width, header height | Different page structure |
| Realistic data | Names, numbers, dates that could be real | "Lorem ipsum", "Test User", "12345" |
| Correct density | Information density matches the target app | Too sparse or too crowded |

---

## Interactivity Requirements

Every interactive element must respond. Dead UI is worse than no prototype.

| Element | Minimum Interactivity |
|---------|----------------------|
| Buttons | Visual feedback on click (color change, ripple, loading state) |
| Forms | Validation feedback on blur/submit, success/error states |
| Modals/Dialogs | Open on trigger, close on X/overlay/Escape |
| Tabs/Navigation | Switch visible content on click |
| Dropdowns | Open/close, show options, select |
| Toggle/Switch | Visual state change |
| Hover states | Cursor change, subtle visual feedback |

Use JavaScript for state management. Keep it simple — no frameworks, vanilla JS only.

---

## Mock Data Rules

| Rule | Example |
|------|---------|
| Use domain-appropriate names | "Maria Schmidt", "Procurement Order #4721" — not "John Doe", "Item 1" |
| Use realistic numbers | "€ 12,450.00", "47 items" — not "$ 100", "5 items" |
| Match data volume | If the real view shows 10-20 rows, show 8-12 — not 2-3 |
| Include edge cases | One long name, one empty optional field, one error state |
| Dates should be recent | Use dates near the prototype creation date |

Derive mock data from the data model in `design.md`. Entity names, field types, and relationships inform what realistic data looks like.

---

## HTML Structure Rules

| Rule | Reason |
|------|--------|
| Single self-contained file | Easy to share, no broken references |
| All CSS inline in `<style>` | No external stylesheets |
| All JS inline in `<script>` | No external scripts |
| No CDN links | Must work offline |
| No external images | Use CSS plans, SVG inline, or emoji for icons |
| No external fonts | Use system font stack or inline base64 if critical |
| Valid HTML5 doctype | Browser rendering consistency |
| UTF-8 encoding declared | Character rendering |

Maximum file size target: 300KB. Warn if exceeding 500KB.

---

## Review Chrome Pattern

The prototype uses the makato slide-deck review pattern for its wrapper:

| Component | Implementation |
|-----------|---------------|
| Nav bar | Fixed top, feature name, date, theme toggle |
| Step tracker | Numbered circles connected by lines, one per surface |
| Slide container | Full viewport minus nav/bottom bar |
| Slide layout | Prototype content (left/main) + feedback panel (right) |
| Feedback panel | Textarea per surface, section label, placeholder hint |
| Comments strip | Fixed strip above bottom bar showing filled comments |
| Bottom bar | Prev/Next navigation + Copy Feedback button |
| Theme toggle | Dark/Light mode (affects review chrome only, not prototype content) |
| Keyboard nav | Arrow keys navigate between slides |

The review chrome uses makato brand tokens (blue accent, dark surface). The prototype content inside each slide uses the TARGET APP's tokens.

---

## Anti-Patterns

| Anti-Pattern | Why it Fails |
|--------------|-------------|
| Generic gray wireframe | Doesn't answer "how does it feel?" — looks like any other app |
| Lorem ipsum text | Stakeholders can't evaluate information hierarchy with fake content |
| Non-responsive button | User tries to click, nothing happens — breaks trust in the prototype |
| External dependencies | Prototype breaks when opened offline or shared via email |
| Prototyping unchanged UI | Wastes effort — only prototype new/significantly changed surfaces |
| Over-engineering state | Complex state machines — keep it simple, mock the happy path + 1-2 error states |
| Ignoring the design system | Prototype looks different from the real app — feedback becomes about styling not UX |

---

## Assumption Marking

When the prototype includes elements based on assumptions (not confirmed UX decisions):

```html
<div class="assumed" title="ASSUMED: Navigation pattern not confirmed (Q7)">
  <!-- prototype content with assumed pattern -->
</div>
```

Style: dashed amber border + small "ASSUMED" label. Visible but not distracting.

This helps reviewers identify what needs explicit confirmation vs. what was decided.
