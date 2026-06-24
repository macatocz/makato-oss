# Slice Patterns Reference

> Expert patterns for vertical slice decomposition in the To Issues skill.

## Tracer-Bullet Slice Pattern

A tracer-bullet slice cuts end-to-end from input to observable output, touching every layer it must touch exactly once. The four shapes below correspond to the four data-flow topologies the sagibeast architecture relies on. Pick the shape that matches the work; if a feature spans the Brain↔Body boundary, issue separate slices for each side with `blocked_by` linking them (do not bundle).

### Web/API tracer-bullet

1. Route — FastAPI endpoint that accepts the request
2. Handler / orchestrator — translates HTTP to a domain call (auth, validation, response shaping)
3. Domain function — the actual feature logic, decoupled from FastAPI
4. Persistence — pgvector / Postgres read or write (raw SQL per ADR-0002)
5. Outside test — pytest hitting the route via TestClient, asserting observable output (no internal mocking)

**Anti-pattern:** horizontal slices ("all Postgres schema this sprint, all API endpoints next sprint"). Each horizontal layer is dead code until the others land.

### Brain agent / LangGraph node tracer-bullet

1. Trigger — Temporal workflow signal or chat-widget message entering the LangGraph graph
2. Node — the LangGraph state-graph node where work happens (typically wraps a PydanticAI agent)
3. Tool call — agent invokes a tool: skill execution, retrieval, memory read, body-API call
4. State write — Memory Service update (episodic / semantic / procedural per chapter 02) OR LangGraph state edit
5. Outside test — driven from the workflow boundary or node input, asserting state delta + agent response

**Anti-pattern:** implementing tool → node → prompt → trigger separately. Each step is dead code until the chain closes. Cut across all five from day one, even if the agent prompt is initially trivial.

### Pipeline tracer-bullet

1. Input source — file upload (Docling-fed PDF/IFC), batch trigger, or stream message
2. Transform — chunk, embed (BGE-M3), tokenise (PII), or convert (Docling)
3. Persist — pgvector vector store, Postgres table, or MinIO/S3 object
4. Retrievable query — the artifact must be reachable by a downstream query (similarity search, key lookup, presigned URL)
5. Outside test — drives the input, asserts the retrievable query returns the artifact in the expected shape

**Anti-pattern:** writing the ingest half without writing the query half. An artifact you can't retrieve is invisible; the slice isn't done until something can read it back.

### Cross-cutting tracer-bullet

1. Interception point — middleware position, decorator surface, LangGraph node wrapper, or Langfuse instrumentation hook
2. Augmentation — what the wrapper adds (auth claim, span emission, PII mask, sandbox policy)
3. Passthrough — call the wrapped function; the wrapper must not change the inner contract
4. Side effect — emitted span / written log / enforced policy outcome
5. Outside test — exercise a wrapped call, assert (a) inner contract preserved, (b) side effect observable

**Anti-pattern:** building the wrapper without exercising real wrapped calls in the test. Stub-only tests miss interaction bugs. A real call through real middleware is the only way to know the wrap composes correctly.

### Notes for all four shapes

- A slice may use a subset of layers (e.g. read-only slices have no persistence layer — say so explicitly in the issue body).
- Slices that span the Brain↔Body boundary force tracer-bullets on both sides. Issue them separately with `blocked_by` linking, never bundled.
- Config-only work (compose, helm, env wiring) is not tracer-shaped and does not need a 5-layer recipe — slice by environment (dev → staging → prod), validating smallest-possible at each step.
- Lifecycle / governance work (skill registration, project-board transitions, kill-switch toggles) is state-machine-shaped, not data-flow-shaped — represent as labels on the issue rather than forcing into a tracer.

## Issue Body Quality Checklist

A well-formed issue body must include:

1. **Context** — what part of the system this changes and why. For Brain work, name the chapter (e.g. "chapter 02 Memory Service"). For Body work, name the subsystem (ingest / RAG / API client / UI).
2. **What to build** — concrete description of the change. Reference which tracer-bullet shape applies and which of its 5 layers are touched.
3. **Acceptance criteria** — specific, testable conditions. The outside-test layer of the tracer-bullet is what the criteria assert on.
4. **Files** — exact file paths to create or modify, using the expected `src/` layout from sagibeast's `context/codebase/structure.md`.

Missing any of these forces the implementing agent to ask questions mid-session.
