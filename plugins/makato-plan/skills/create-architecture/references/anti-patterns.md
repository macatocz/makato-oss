# Create-Architecture Anti-Patterns

These failure modes are non-obvious and only experience teaches them. Claude MUST NOT do any of the following.

**NEVER accept "we'll figure it out later" for core architectural paths.**
WHY: service boundaries, auth mechanisms, and data models are the decisions that force rework late in delivery. An unanswered question on a critical path is not deferred risk — it is hidden cost. Push back explicitly: "Is this a critical path? If yes, decide now or park as a High-priority Q# that blocks decompose." Defer only peripherals (e.g., exact alerting thresholds, log retention policies).

**NEVER write a design.md section using AI-inferred content without flagging it.**
WHY: design.md is the authoritative technical contract consumed by build-refine. A plausible-sounding but inferred technology choice (e.g., "Redis for caching") that contradicts the team's actual infrastructure creates a false contract — developers implement against a fiction and discover the mismatch during integration, not shaping. Every section must trace to interview answer, PRD requirement, or context-scout finding. If no source exists, mark `[PENDING: Q#]`.

**NEVER accept vague architecture vocabulary without demanding concrete specifics.**
WHY: "microservices", "cache", "event-driven", and "scalable" each describe at least a dozen incompatible designs. Accepting them produces a design doc that reads coherent but makes no real decisions. The doc-writer agent will then fabricate specifics to fill the void, compounding the problem. Push back on every vague term — see `references/architecture-quality.md` for the push-back question per pattern.

**NEVER duplicate PRD requirements in the design doc.**
WHY: any PRD content copied into design.md creates two canonical sources. When the PRD is updated (common during refinement), the design doc silently drifts. The design doc's job is to say HOW — it references PRD requirements by implication ("NFR: page load <2s → CDN + edge caching + lazy loading"). If you're writing a requirement, it belongs in the PRD; if you find implementation detail in the PRD, move it here.

**NEVER approve a design with critical sections still `[PENDING: Q#]`.**
WHY: security, data model, and component design are the three sections that every downstream story depends on. Approving with a pending auth mechanism means every security story is blocked the moment development starts. Step 9 enforces this gate — it is not advisory.

**NEVER re-run all interview rounds when in Refine mode.**
WHY: re-interviewing on an update erases the user's existing answers and creates a full replacement instead of a delta. In Refine mode (Step 1.4), enter with the existing design loaded, ask only "what changed", and preserve untouched sections byte-for-byte per `shared/refinement-contract.md`. A refinement that inadvertently reverts a prior decision is harder to detect than a gap in a fresh document.

**NEVER downgrade this skill's model to sonnet to save tokens.**
WHY: the architecture interview drives multi-round synthesis across all three interview rounds plus grill output. Sonnet produces shallower follow-ups and misses coupling concerns that only emerge from connecting answers across rounds. The model selection is governed by AGENTS.md — change it only via a quality experiment.
