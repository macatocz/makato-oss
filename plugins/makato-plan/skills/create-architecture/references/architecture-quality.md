# Architecture Quality Standards

Quality rules applied when writing and reviewing the architecture design document. Load during Step 5 (design document generation).

---

## Technical Decision Format

Every technical decision must include all four elements:

| Element | Purpose | Example |
|---------|---------|---------|
| **Options considered** | Shows the decision was deliberate | "REST, GraphQL, gRPC" |
| **Chosen approach** | The actual decision | "REST" |
| **Rationale** | Why this option won | "Team expertise + simple API surface + better caching" |
| **Trade-offs accepted** | What we're giving up | "No real-time subscriptions without polling" |

Reject decisions without rationale. "We chose X" is incomplete — "We chose X because Y, accepting Z" is valid.

---

## NFR Implementation Mapping

Every PRD non-functional requirement (the "what") must map to a concrete technical approach (the "how"):

| PRD NFR (what) | Design Approach (how) |
|----------------|----------------------|
| "Page loads in <2s" | CDN for static assets + edge caching + lazy loading below fold + preconnect hints |
| "99.9% uptime" | Multi-AZ deployment + health checks + auto-scaling + circuit breakers on dependencies |
| "Handles 10x current load" | Horizontal scaling at API layer + read replicas + connection pooling + async processing for heavy operations |
| "WCAG 2.1 AA" | Component library with built-in a11y + automated axe testing in CI + screen reader testing in QA |

If an NFR exists in the PRD but has no implementation approach in the design doc, the document is incomplete.

---

## Anti-Patterns

Reject vague architecture. Push back on:

| Vague | Push-back question |
|-------|-------------------|
| "We'll use microservices" | "What are the service boundaries? What drives the split? How do services communicate?" |
| "We'll add a cache" | "What type (Redis/CDN/in-memory)? What's the invalidation strategy? What's the TTL? What's the cache-miss path?" |
| "It'll be scalable" | "What's the scaling dimension (users/data/requests)? Horizontal or vertical? What's the bottleneck at 10x?" |
| "Standard security" | "Which auth mechanism specifically? What's the authorization model? What data is sensitive?" |
| "We'll figure it out later" | "Is this a critical path? If yes, it needs a decision now or a High-priority open question." |

---

## Required Sections

Every architecture design doc must include:

1. **Overview** — summary of what's being designed and which PRD it implements
2. **System Context** — boundaries, external systems, data exchanges
3. **Component Design** — breakdown, communication patterns, responsibilities
4. **Technical Decisions** — options/rationale table for each key decision
5. **Data Model** — entities, relationships, storage technology
6. **API Design** — endpoints/operations, auth, errors, versioning
7. **Security** — authn, authz, data classification, encryption, compliance
8. **Performance & Caching** — NFR implementation mapping with specific techniques
9. **Deployment & Operations** — strategy, environments, rollback plan
10. **Observability** — monitoring, alerting, logging, tracing
11. **Test Strategy** — types, coverage targets, critical scenarios

Optional (based on feature):
- **Migration & Rollback** — include if data migration or breaking changes involved
- **Open Questions** — include if any questions were parked

---

## Decision References

Same convention as PRD: reference `decisions.md` entries by ID. Never duplicate:

```markdown
<!-- WRONG -->
We chose PostgreSQL because the team has experience with it and
the data is relational with strong consistency requirements.

<!-- RIGHT -->
Storage uses PostgreSQL (per D7: team expertise + relational data + strong consistency).
```

---

## Boundary Rule

The design doc implements PRD requirements — it does not restate them:

- PRD says "page loads in <2s" → Design says "CDN + edge caching + lazy loading"
- PRD says "supports 1000 concurrent users" → Design says "horizontal scaling + connection pooling + async queue"
- PRD says "accessible to screen readers" → Design says "semantic HTML + ARIA landmarks + component library with a11y built-in"

If you find yourself writing a requirement in the design doc, it belongs in the PRD. If you find implementation details in the PRD, they belong here.
