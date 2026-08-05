# Architecture Interview Rounds — Full Question Bank

Load this file ONLY at the start of Step 3 (Architecture Interview).
Do NOT load during any other step — the question bank is large and contaminates completeness validation.

---

## Round 1 — System Context & Boundaries

Reject vague architecture terms before recording any answer: "microservices" needs service boundaries and justification; "cache" needs type, invalidation strategy, and TTL; "message queue" needs topic design and consumer groups.

- **System context** — "How does this feature interact with external systems? What's the boundary between what we own and what we consume/produce? Draw the picture: our system, external actors, data exchanges."
- **Component breakdown** — "Which components need to change or be created? How do they communicate (sync/async, REST/events/shared DB)? What are the responsibilities of each?"
- **Data flow** — "Trace the data from input to output. Where does it enter the system, how is it transformed, where does it persist, and how does it exit?"
- **Technical constraints** — "What's non-negotiable technically? Language, framework, platform, deployment target, protocols, team capabilities, existing tech debt that constrains us?"
- **Integration points** — "What services, APIs, or systems do we integrate with? Owned or external? Sync or async? What happens when they're unavailable?"

---

## Round 2 — Design Decisions & Data

- **Key technical decisions** — "What are the 3-5 most impactful technical choices we need to make? For each: what options did you consider, what did you choose, why, and what trade-offs are we accepting?"
- **Data model** — "What entities exist? Relationships? Storage technology (SQL/NoSQL/object store)? Schema evolution strategy? Expected data volumes? Retention policy?"
- **API design** — "REST/GraphQL/gRPC/events? Key endpoints or operations? Versioning strategy? Authentication and authorization approach? Error handling patterns? Rate limiting?"
- **Security considerations** — mandatory for every feature. "Authentication mechanism (OAuth/SAML/API keys)? Authorization model (RBAC/ABAC/custom)? Data sensitivity classification? Encryption at rest and in transit? Compliance requirements from PRD NFRs — how do we meet them?"

---

## Round 3 — Operations & Quality

Depth varies by scope — skip sub-topics that are clearly not applicable for the feature.

- **Performance approach** — "How do we meet the NFRs from the PRD? Specific techniques: CDN, caching (what type, invalidation strategy, TTL), pagination, lazy loading, connection pooling, async processing. Where are the likely bottlenecks?"
- **Deployment strategy** — "Blue-green, canary, rolling, feature flags? Rollback plan if it goes wrong? Environment topology (dev/staging/prod)? Infrastructure as code? CI/CD pipeline changes needed?"
- **Observability** — "What do we monitor? Key business and technical metrics, alerting thresholds, logging strategy (structured?), distributed tracing? How do we know the feature is healthy in production?"
- **Test strategy** — "Unit/integration/e2e split? Coverage targets for critical paths? What are the critical test scenarios that must pass? Performance/load testing approach? Contract testing for APIs?"
- **Migration & rollback** — "Data migration needed? Is it backwards-compatible? What are the rollback steps if deployment fails? Feature flag kill switch? Can we deploy incrementally?"
