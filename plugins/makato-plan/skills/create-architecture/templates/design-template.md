# <Feature Name> — Architecture Design

**Status**: Draft
**Feature**: <slug>
**Created**: <YYYY-MM-DD>
**Author**: <user>
**PRD**: <link to prd.md or "specs/{folder}/prd.md">
**Repositories**: <repo1 (primary), repo2, repo3>

---

## Overview

### Summary
<2-3 sentences: What are we designing? What's the technical challenge?>

### Goals (from PRD)
<Reference PRD goals — do not duplicate. State which PRD goals this design addresses.>

### Non-Goals (from PRD)
<Reference PRD non-goals that bound the architecture. "We are NOT designing for X.">

---

## System Context

### Boundary Diagram (textual)

<Describe the system boundary: our system in the center, external actors/systems around it, data flows between them. Use a structured format:>

**Our System**: <name/scope of what we're building>

| External Actor/System | Direction | Data Exchanged | Protocol | Notes |
|----------------------|-----------|----------------|----------|-------|
| <actor/system> | <inbound/outbound/bidirectional> | <what data> | <REST/events/file/etc.> | <ownership, SLA, failure mode> |

### Data Flow

<Trace the primary data path from input to output:>

1. <Entry point — how data enters the system>
2. <Transformation/processing step>
3. <Persistence — where and how data is stored>
4. <Output — how data exits or is consumed>

**Alternative paths**: <error paths, async paths, batch paths if relevant>

---

## Component Design

### Component Breakdown

| Component | Responsibility | Technology | Communication |
|-----------|---------------|------------|---------------|
| <component> | <what it does> | <language/framework> | <how it talks to others> |

### Communication Patterns

<Describe how components interact: sync (REST/gRPC), async (events/queues), shared state. Include failure handling between components.>

---

## Technical Decisions

> Each decision references decisions.md by ID. Only the summary and architectural makato are repeated here.

### Decision 1: <Title>

| Aspect | Detail |
|--------|--------|
| **Options** | <Option A, Option B, Option C> |
| **Chosen** | <Selected option> |
| **Rationale** | <Why — per D#: brief reason> |
| **Trade-offs** | <What we're giving up> |
| **makato** | <How this plans the rest of the architecture> |

### Decision 2: <Title>

| Aspect | Detail |
|--------|--------|
| **Options** | <options> |
| **Chosen** | <selected> |
| **Rationale** | <per D#: reason> |
| **Trade-offs** | <accepted costs> |
| **makato** | <architectural consequence> |

---

## Data Model

### Entities

| Entity | Description | Storage | Estimated Volume |
|--------|-------------|---------|-----------------|
| <entity> | <what it represents> | <PostgreSQL/Redis/S3/etc.> | <rows/documents/objects expected> |

### Relationships

<Describe key relationships between entities. Include cardinality (1:1, 1:N, M:N) and how they're implemented (FK, reference, embedded).>

### Schema Evolution

<Strategy for schema changes: migrations, backwards compatibility, versioning. Tools used (Flyway, Liquibase, manual SQL).>

---

## API Design

### Endpoints / Operations

| Method | Path / Operation | Purpose | Auth |
|--------|-----------------|---------|------|
| <GET/POST/etc.> | <path or operation name> | <what it does> | <required scope/role> |

### Authentication & Authorization

- **Mechanism**: <OAuth 2.0 / SAML / API Key / JWT / etc.>
- **Authorization model**: <RBAC / ABAC / custom>
- **Scopes/Roles**: <what roles exist, what they can access>

### Error Handling

<Error response format, HTTP status codes used, error categorization (client/server/transient).>

### Versioning Strategy

<How API versions are managed: URL path, header, no versioning with backwards compat, etc.>

---

## Security

### Authentication
<Mechanism, token format, session management, refresh strategy.>

### Authorization
<Model (RBAC/ABAC), permission granularity, where enforcement happens.>

### Data Classification

| Data Type | Classification | Encryption at Rest | Encryption in Transit | Retention |
|-----------|---------------|-------------------|----------------------|-----------|
| <data type> | <public/internal/confidential/restricted> | <yes/no — method> | <TLS 1.2+/mTLS> | <policy> |

### Compliance Mapping

<Map PRD compliance requirements to specific technical controls. Reference NFRs by requirement.>

---

## Performance & Caching

### NFR Implementation

| PRD Requirement | Technical Approach | Measurement |
|----------------|-------------------|-------------|
| <NFR from PRD — the "what"> | <implementation — the "how"> | <how we verify it meets the target> |

### Caching Strategy

| Cache Layer | Technology | Scope | TTL | Invalidation |
|-------------|-----------|-------|-----|-------------|
| <layer> | <Redis/CDN/in-memory/etc.> | <what's cached> | <duration> | <strategy: event-driven/TTL/manual> |

### Bottleneck Mitigation

<Identified bottlenecks and how they're addressed: connection pooling, async processing, pagination, lazy loading, etc.>

---

## Deployment & Operations

### Deployment Strategy
<Blue-green / Canary / Rolling / Feature flags. Which one and why.>

### Environment Topology

| Environment | Purpose | Infrastructure | Data |
|-------------|---------|---------------|------|
| <dev/staging/prod> | <what it's used for> | <how it's provisioned> | <data characteristics> |

### Rollback Plan
<Steps to roll back if deployment fails. Maximum acceptable rollback time. Data rollback considerations.>

### Infrastructure Changes
<New infrastructure needed: databases, queues, caches, storage. IaC approach (Terraform/CloudFormation/etc.).>

---

## Observability

### Key Metrics

| Metric | Type | Threshold | Alert |
|--------|------|-----------|-------|
| <metric name> | <business/technical> | <warning/critical levels> | <who gets paged> |

### Logging Strategy
<Structured logging format, log levels, what to log at each level, PII considerations.>

### Distributed Tracing
<Tracing approach, correlation IDs, span boundaries, sampling strategy.>

### Health Checks
<Liveness vs. readiness probes, dependency health, degradation modes.>

---

## Test Strategy

### Test Pyramid

| Level | Scope | Coverage Target | Framework |
|-------|-------|----------------|-----------|
| Unit | <what's unit tested> | <target %> | <framework> |
| Integration | <what's integration tested> | <target %> | <framework> |
| E2E | <critical paths> | <target scenarios> | <framework> |

### Critical Test Scenarios
<List the 3-5 most important test scenarios that MUST pass before shipping.>

### Performance Testing
<Load testing approach, tools, target metrics, when it runs.>

### Contract Testing
<API contract testing approach for service boundaries (if applicable).>

---

<!-- CONDITIONAL: Include if data migration or breaking changes are involved -->
## Migration & Rollback

### Data Migration
<Migration steps, tool, estimated duration, rollback path for data.>

### Backwards Compatibility
<Is the change backwards-compatible? If not, what's the migration window? Feature flag strategy?>

### Incremental Deployment
<Can this be deployed incrementally? What's the order? Dependencies between deployment steps?>

---

## Key Decisions Referenced

| ID | Decision | Architectural makato |
|----|----------|---------------------|
| <D#> | <decision summary> | <how it plans this design> |

---

## Open Questions

- [ ] <Question — parked during architecture design>
- [ ] <Question>

> Full question details with priority and context are in decisions.md.

---

*Architecture design focuses on HOW we build it. The WHAT and WHY are in the PRD.*
