# Vertical Story Slicing

Rules for sketching vertically-sliced user stories in the PRD. Load during Step 5.1 when generating story sketches.

---

## Mental Model: The Burger

A feature is a burger. It has several layers stacked together — UI, middle tier, security, data, integration, whatever the feature actually needs. You can cut it two ways:

- **Horizontal slicing (wrong)**: each slice is a single layer. Sprint 1 = UI, Sprint 2 = middle tier, Sprint 3 = DB. Nothing usable until the last slice. The PO never sees a working burger.
- **Vertical slicing (right)**: each slice cuts through every layer. Slice 1 = a thinner burger; Slice 2 = adds a topping; Slice 3 = the full thing. The PO has a working burger after every slice.

Every story sketch is a vertical cut. It contains every layer the feature touches, not just one.

---

## Core Principle

Each story sketch cuts through ALL technical layers needed to deliver observable value to the user. After each story ships, the user can do something they couldn't do before.

---

## Slicing Rules

1. **Slice by user outcome**, not by technical layer or repository. Each story answers: "What can the user do after this ships that they couldn't before?"

2. **The first story is the MVP** — the thinnest possible end-to-end path that proves the feature works. It touches every layer the feature needs (UI, middle tier, security, data, etc.) but with minimal scope. After story 1 ships, the persona can complete the core flow end-to-end, even if narrow.

3. **Subsequent stories enrich the MVP** — each adds incremental value (more pages, richer data, edge cases, polish). The PO can stop after any story and still have a working feature.

4. **Technical enablers are absorbed, not separate.** Infrastructure work (shared components, API endpoints, DB migrations) is part of the first story that needs it — never a standalone story.

5. **Each story is independently shippable.** If a story can't go to production on its own, it's not a vertical slice — it's a task.

---

## End-to-End Self-Check (after each sketch)

After sketching every story — not just the MVP — the AI MUST explicitly answer:

> **"Does this slice hit every layer in the feature's declared scope?"**

- **Yes** → the slice is end-to-end. Move on.
- **No** → expand the slice to cover the missing layer, or revisit the feature's scope. **Do NOT** push the missing layer into a later story.

A slice that misses a layer in the declared scope isn't vertical — it's a task. The MVP additionally must stand alone (the persona can use the feature end-to-end after only the MVP ships); enrichment slices build on top, but each one still cuts through every layer.

---

## Validation Checklist

For each story sketch, verify:

| Check | Question | Warning if fails |
|-------|----------|-----------------|
| User-facing outcome | Can a stakeholder see the result? | "Story has no user-facing outcome" |
| Independently testable | Can we demo this alone? | "Story may be a horizontal slice" |
| Independently deployable | Can it ship without other stories? | "Story depends on other stories" |
| Covers all layers identified in scope | Does it touch every layer the feature's declared scope requires (per `repositories.yml` + the layer set the feature needs)? | "Story misses {layer} — feature scope requires it" |

The "covers all layers" check is tied to the feature's **declared scope**, not a generic "2+" threshold. If the feature's scope is UI + middle tier + DB, every story must touch UI, middle tier, and DB. If it's a backend-only feature with middle tier + DB, every story must touch both.

---

## Anti-Patterns

```diff
# WRONG — horizontal slices (by technical layer)
- Story 1: Create shared ChatAdvisorComponent in commerce-ui-libs
- Story 2: Update page detection in DcpStorefrontComponent
- Story 3: Add feature toggle for pstore-ui

# RIGHT — vertical slices (by user outcome)
+ Story 1 (MVP): Chat Advisor on configurator pages
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
### Story Sketch 1 (MVP): [User Outcome Title]
**User can**: [what they can do after this ships]
**Layers**: [UI, Middle Tier, Security, DB, Config — every layer the feature's scope requires]
**Coverage**: [repo × layer matrix — which repos touch which layers in this slice]
**Acceptance sketch**:
- [High-level condition 1]
- [High-level condition 2]
- [High-level condition 3]
**Derived from**: [slot refs from Step 5.0 consolidation]
```

Keep acceptance sketches to 2-4 high-level conditions. Detailed acceptance criteria come during the spec/decomposition phase.

---

## Story Count

- **No upper limit.** Sketch as many slices as the feature actually needs — and as few. The MVP slice alone is a valid PRD outcome; small features should not be padded.
- Force enrichment slices only when the **phased rollout explicitly defines multiple phases** or the feature genuinely warrants further cuts. If Phase 1 is the entire feature, one story (the MVP) is correct.
- Do not invent stories to hit a count, and do not cap them to keep the PRD short. Coverage of every layer in scope is what each slice must satisfy — not a target story count.
