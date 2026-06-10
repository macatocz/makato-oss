# Vertical Story Slicing

Rules for sketching vertically-sliced user stories in the PRD. Load during Step 5.1 when generating story sketches.

---

## Core Principle

Each story sketch cuts through ALL technical layers needed to deliver observable value to the user. After each story ships, the user can do something they couldn't do before.

---

## Slicing Rules

1. **Slice by user outcome**, not by technical layer or repository. Each story answers: "What can the user do after this ships that they couldn't before?"

2. **The first story is the walking skeleton** — the thinnest possible end-to-end path that proves the feature works. It touches all layers (UI, API, DB, config) but with minimal scope.

3. **Subsequent stories enrich the skeleton** — each adds incremental value (more pages, richer data, edge cases, polish). The PO can stop after any story and still have a working feature.

4. **Technical enablers are absorbed, not separate.** Infrastructure work (shared components, API endpoints, DB migrations) is part of the first story that needs it — never a standalone story.

5. **Each story is independently shippable.** If a story can't go to production on its own, it's not a vertical slice — it's a task.

---

## Validation Checklist

For each story sketch, verify:

| Check | Question | Warning if fails |
|-------|----------|-----------------|
| User-facing outcome | Can a stakeholder see the result? | "Story has no user-facing outcome" |
| Independently testable | Can we demo this alone? | "Story may be a horizontal slice" |
| Independently deployable | Can it ship without other stories? | "Story depends on other stories" |
| Crosses layers | Does it touch 2+ technical boundaries? | "Story touches only {layer}" |

---

## Anti-Patterns

```diff
# WRONG — horizontal slices (by technical layer)
- Story 1: Create shared ChatAdvisorComponent in commerce-ui-libs
- Story 2: Update page detection in DcpStorefrontComponent
- Story 3: Add feature toggle for pstore-ui

# RIGHT — vertical slices (by user outcome)
+ Story 1: Chat Advisor on configurator pages
+   → Creates component, wires it, adds detection — user sees advisor on configurator
+ Story 2: Chat Advisor on checkout pages
+   → Extends detection to checkout — user sees advisor during checkout
+ Story 3: Chat Advisor in Partner Store
+   → Full integration — partners get advisor
```

---

## Story Sketch Format (for PRD)

Story sketches in the PRD are rough ideas, not detailed specs:

```markdown
### Story Sketch 1: [User Outcome Title]
**User can**: [what they can do after this ships]
**Layers**: [UI, API, DB, Config — which boundaries it crosses]
**Acceptance sketch**:
- [High-level condition 1]
- [High-level condition 2]
- [High-level condition 3]
```

Keep acceptance sketches to 2-4 high-level conditions. Detailed acceptance criteria come during the spec/decomposition phase.
