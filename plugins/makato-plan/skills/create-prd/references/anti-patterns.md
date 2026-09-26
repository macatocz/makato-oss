# Create-PRD Anti-Patterns

**NEVER generate content for a PRD section without explicit user input or confirmed brainstorm content.**
WHY: PRDs shape every downstream artifact — architecture, decomposition, acceptance tests, GitHub issues. AI-assumed content silently bakes in wrong scope, phantom user needs, or unmeasured success criteria that teams discover only after sprint work is done. Step 6 exists to catch this, but prevention (tracing every section back to a user answer or confirmed brainstorm) eliminates the failure class entirely.

**NEVER allow vague success metrics ("fast", "easy to use", "intuitive") to survive into the PRD.**
WHY: Vague metrics make the Definition of Done untestable. QA cannot write acceptance tests against "fast"; product cannot sign off a release against "intuitive". The PRD gates all downstream QA work — a vague metric propagates into Gherkin scenarios that cannot be automated, acceptance tests that fail peer review, and sprint demos where "done" is permanently disputed.

**NEVER use time-based phases ("Sprint 1", "Q3", "next quarter") in the phased rollout.**
WHY: Time-based phases divorce the roadmap from technical dependencies. A "Sprint 2" label carries no semantic content about what must be true before Sprint 2 can start. Dependency-based phases with explicit exit criteria are what decompose and build-refine use to gate story ordering. Time phases produce sprint-split artifacts — stories that can't be independently shipped because a hidden predecessor wasn't named.

**NEVER slice stories by technical layer (UI, middle tier, DB) in the story sketches.**
WHY: Layer slices produce zero user-observable value until the final slice ships. A UI-only story can't be demoed end-to-end; a DB-only story can't be tested by the PO. Horizontally-sliced PRDs reach decompose and produce unshippable tasks masquerading as stories, which then fail the "independently deployable" check in build-verify. Every story sketch must be a vertical cut through all layers the feature scope requires.

**NEVER duplicate decision content from decisions.md into the PRD body.**
WHY: When a decision changes, duplicate content produces contradictory artifacts. Architecture, decompose, and build-refine all read both files; a stale PRD copy overrides the updated decisions.md record silently. Reference decisions by ID only (e.g., "per D3") — the PRD stays current whenever decisions.md is updated without a separate PRD edit.

**NEVER skip the Step 5.0 slot-consolidation checkpoint before sketching stories.**
WHY: Later interview answers routinely contradict earlier ones in the same slot. A late Round 2 answer may narrow scope that was established in Round 1 or a grill may add a new phase that changes persona coverage. Sketching stories directly from un-consolidated interview state produces slices derived from stale inputs. The slot table is an internal-only pass — it is never written to disk, but it MUST be built before story sketching reads from interview state.

**Do NOT Load `references/vertical-slicing.md` or `references/prd-quality.md` before their designated steps (5.1 and 5.2 respectively).**
WHY: Front-loading these references consumes context budget before the interview rounds that generate the input they need to evaluate. Load them at the point of use — they are contextual quality checks, not framing material.
