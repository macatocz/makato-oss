# Scope Estimation Criteria

Decision tree for classifying changes as small, medium, or large based on complexity and impact.

## Why Scope Matters

- **Small/Medium** → makato-change workflow (analyze → design → execute)
- **Large** → makato-plan workflow (discovery, architecture, decomposition into multiple stories)

Misclassifying scope leads to rework. A "small change" that turns out to be large will stall in execution. A "large change" forced through makato-change will produce brittle code.

## Estimation Dimensions

Evaluate each dimension independently, then combine:

### 1. File Count

How many files need changes?

| Files | Classification |
|-------|----------------|
| 1-3 | Small indicator |
| 4-8 | Medium indicator |
| 9-15 | Large indicator |
| 16+ | Definitely large |

**Counts:**
- Source files that need edits (not just reads)
- New files created
- Test files changed or added
- Config/schema files updated

**Exclude:**
- Files you read for context but don't change
- Auto-generated files (migrations, compiled assets)

### 2. Architectural Impact

How deeply does the change cut across the system?

| Impact | Description | Classification |
|--------|-------------|----------------|
| **Isolated** | Change is contained within one module/component. No changes to interfaces or contracts. Other parts of the system don't know this changed. | Small |
| **Cross-cutting (shallow)** | Change affects multiple modules, but impact is mechanical (renaming, adding optional param). No new concepts introduced. | Medium |
| **Cross-cutting (deep)** | Change requires modifying core abstractions, shared interfaces, or data models. Ripples through many dependent modules. | Large |
| **New subsystem** | Change introduces entirely new architectural concepts (new service, new data store, new communication pattern). | Large |

**Key question:** If we make this change, how many other parts of the system need to adapt?

### 3. New Components

What new code artifacts are needed?

| What's New | Classification |
|------------|----------------|
| None — only modifying existing code | Small indicator |
| New helper functions, utils, validation rules (supporting existing modules) | Small-Medium |
| New UI components, new API endpoints, new database tables (extending existing subsystems) | Medium |
| New services, new modules, new integrations (creating new subsystems) | Large |

**Test:** If you removed all the changes, would a significant architectural element disappear? If yes → large.

### 4. Test Impact

How much test work is required?

| Test Work | Classification |
|-----------|----------------|
| Adjust existing tests (update assertions, add test cases) | Small |
| Write new tests for new behavior + adjust existing tests | Medium |
| Design new test strategy (new fixtures, mocks, integration test setup) | Large |
| Need new test environments or external service mocks | Large |

### 5. Uncertainty / Discovery Needed

How much is unknown about the implementation?

| Uncertainty Level | Classification |
|-------------------|----------------|
| Straightforward — clear how to do it | Small indicator |
| Some open questions, but approach is clear once answered | Medium indicator |
| Approach unclear — need to prototype or research | Large indicator |
| Multiple unknowns — need discovery phase to even estimate | Definitely large |

**Examples of unknowns:**
- "Not sure if our framework supports this"
- "Need to investigate performance impact"
- "Might require database migration strategy"
- "Unclear which services are affected"

### 6. Coordination Needed

How many people/teams are involved?

| Coordination | Classification |
|--------------|----------------|
| One person, self-contained work | Small indicator |
| One person, but needs input from others (review, clarification) | Small-Medium |
| Two people collaborating (frontend + backend, or pairing) | Medium |
| Multiple people across teams (API + UI + infra) | Large |
| External dependencies (waiting on other teams' work to land first) | Large |

## Combining Dimensions

No single dimension determines scope. Look at the overall pattern:

### Small Change

- 1-3 files
- Isolated impact
- No new components (or trivial helpers)
- Adjust existing tests
- Approach is clear
- One person can do it

**Examples:**
- Add validation rule to existing form field
- Change button label and update one click handler
- Add optional query parameter to existing API endpoint
- Fix edge case in existing function

### Medium Change

- 4-8 files
- Cross-cutting but shallow (mechanical changes across modules)
- New components extend existing subsystems
- Write new tests + adjust existing
- Some questions, but solvable during design
- One-two people, maybe some coordination

**Examples:**
- Add confirmation dialog to existing action (touches handler, UI component, tests)
- Add new field to existing form (touches schema, API, validation, UI, tests)
- Refactor shared util used in multiple places
- Add new status to existing state machine

### Large Change

- 9+ files, or deep architectural impact
- Introduces new concepts or subsystems
- New services, modules, or integrations
- Requires new test strategy
- Significant unknowns or prototyping needed
- Multiple people/teams involved

**Examples:**
- Replace authentication system
- Add real-time collaboration (WebSocket integration)
- Implement data export pipeline (new async job system)
- Split monolith into services
- Introduce caching layer

## Edge Cases

### Seems Small, But Actually Large

Watch for "simple sounding" requests that hide complexity:

- **"Just add pagination"** — If lists are currently unbounded, this affects every query, the API contract, and client-side state management. Likely medium-large.
- **"Make it faster"** — Requires profiling, diagnosing bottlenecks, possibly redesigning data access. Large.
- **"Add undo"** — Requires command pattern, history tracking, state snapshots. Likely large unless undo already exists elsewhere.

### Seems Large, But Actually Small

Sometimes a change touches many files mechanically but has low risk:

- **Renaming a function used in 12 places** — Large file count, but each change is mechanical. Can be small if tooling supports safe refactoring.
- **Adding an optional parameter everywhere** — Touches many callsites, but each is a simple append. Medium.

Use judgment: does this feel like one atomic change applied mechanically, or does each file need careful thought?

## Decision Output

In the analysis artifact, state:

1. **Scope: [Small/Medium/Large]**
2. **Justification:**
   - File count estimate
   - Architectural impact description
   - New components summary
   - Test impact summary
   - Uncertainties (if any)
3. **Recommendation:**
   - Small/Medium → "Proceed with makato-change design skill"
   - Large → "Escalate to makato-plan for proper discovery and decomposition. Reason: [why this needs architecture/discovery phase]"

## When in Doubt

Err on the side of **larger classification**:
- Underestimating scope leads to rushed implementation and technical debt
- Overestimating scope wastes a bit of time, but produces better design

If scope is borderline medium/large, consider: does this benefit from architectural design and decomposition? If yes → large.
