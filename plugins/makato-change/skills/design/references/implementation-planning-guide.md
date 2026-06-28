# Implementation Planning Guide

Breaking a design into logical implementation steps, ordering work, and identifying risks.

## Purpose of Implementation Plan

The implementation plan is NOT an exhaustive task list. It's a high-level roadmap showing:
- **Major phases** of work (what comes first, what comes last)
- **Dependencies** between phases (what must be done before what)
- **Risks** that could derail implementation

The execute skill will use this plan as a guide, not a script.

## Step Breakdown

Break the solution into 3-7 major steps. Each step should be:
- **Atomic:** can be done in one sitting
- **Testable:** has a clear "done" state
- **Ordered:** logically sequenced based on dependencies

### Example (Too Detailed — Avoid This)

❌ Bad (too granular):
1. Create new file `DeleteAccountDialog.tsx`
2. Import React and necessary components
3. Define props interface
4. Write JSX for dialog layout
5. Add title text
6. Add body text
7. Add Cancel button
8. Add Delete button
9. Wire up onClick handlers
10. Export component
...

This is a task checklist, not a plan. Too much detail.

### Example (Right Level of Detail)

✅ Good (high-level phases):
1. **Add validation to backend** — Implement isLastAdmin check, return 403 if blocked
2. **Create confirmation dialog UI** — Build modal component with text and buttons
3. **Wire delete flow** — Connect button → dialog → API call → success/error handling
4. **Add/update tests** — Unit tests for dialog, service, validation; integration test for full flow
5. **Verify end-to-end** — Manual test in local environment

This is a roadmap. Each step is a logical phase.

## Ordering Work

### Common Orderings

**Backend-first:**
1. Update data model/schema (if needed)
2. Implement backend logic
3. Update API endpoints
4. Implement UI
5. Add tests
6. Verify

Use when: UI depends on backend being ready, backend can be tested independently.

**Frontend-first:**
1. Build UI components (with mocked data)
2. Implement backend logic
3. Wire UI to real backend
4. Add tests
5. Verify

Use when: UI design is complex and benefits from early iteration, backend is straightforward.

**Test-first (TDD):**
1. Write failing tests for new behavior
2. Implement backend logic to pass tests
3. Implement UI
4. Write UI tests
5. Verify

Use when: requirements are crystal clear, team practices TDD, behavior is well-defined.

**Incremental (slice by slice):**
1. Implement minimal version (no validation, no error handling)
2. Add validation
3. Add error handling
4. Add edge case handling
5. Add tests
6. Verify

Use when: scope is unclear, want to validate approach early, risk of over-engineering.

### Choosing an Order

Consider:
- **What's riskiest?** Do the uncertain part first to de-risk early.
- **What's blocking?** If UI needs API to exist, do API first.
- **What's easiest to test?** If backend is easy to unit test, do it first and lock in correctness.

Default to **backend-first** for most change requests unless there's a reason to do otherwise.

## Dependency Mapping

Identify what depends on what.

### Example

```
Step 1: Add database field `deleted_at` to users table
  ├─ Blocks: Step 2 (backend logic needs this field)
  └─ Risk: Migration might fail on large table

Step 2: Implement soft-delete logic in userService
  ├─ Depends on: Step 1
  ├─ Blocks: Step 3 (API needs this service method)
  └─ Risk: None

Step 3: Add DELETE /api/users/:id endpoint
  ├─ Depends on: Step 2
  ├─ Blocks: Step 4 (UI calls this endpoint)
  └─ Risk: Auth middleware might block (need to verify permissions)

Step 4: Build Delete button + confirmation dialog in UI
  ├─ Depends on: Step 3
  ├─ Blocks: None
  └─ Risk: None

Step 5: Add tests (unit, integration, E2E)
  ├─ Depends on: All above
  └─ Risk: None
```

If Step 1 fails or takes longer than expected, everything blocks. That's a **critical path dependency**.

## Risk Identification

For each step, ask: **What could go wrong?**

### Types of Risks

**Technical Unknowns:**
- "Not sure if the framework supports this feature"
- "Need to research how to mock this external service in tests"
- "Performance impact is unclear (might need caching)"

**External Dependencies:**
- "Waiting on another team to deploy their API first"
- "Need infrastructure change (new database, new service)"
- "Requires design review or security review before proceeding"

**Breaking Changes:**
- "This change might break existing workflows"
- "Migration could fail on production data"
- "Backwards compatibility concern if API contract changes"

**Scope Creep:**
- "Requirements are vague — might discover more complexity during implementation"
- "Edge cases not fully understood yet"

### Risk Documentation Format

```
**Step:** <step number and name>
**Risk:** <what could go wrong>
**Impact:** <what happens if this risk materializes>
**Mitigation:** <how to reduce or handle the risk>
```

### Example

```
**Step:** Add DELETE /api/users/:id endpoint
**Risk:** Auth middleware might not allow users to delete their own accounts (permission model unclear)
**Impact:** Implementation blocked until permissions are clarified
**Mitigation:** Test auth logic early (in Step 3, immediately after implementing endpoint). If blocked, escalate to team lead for permission model decision.

**Step:** Database migration (add deleted_at column)
**Risk:** Migration could timeout on large users table (millions of rows)
**Impact:** Deployment blocked, rollback required
**Mitigation:** Test migration on staging data first. Consider online schema change tool if table is huge.
```

## Scope Validation

As you plan implementation, check if scope is still small/medium:

### Red Flags (Scope Growing)

- More than 7 major steps
- Multiple external dependencies or blockers
- Requires architectural decisions or design reviews
- Touches more than 15 files
- Needs new subsystems (new service, new database, new integration)

If scope is growing, **stop and re-evaluate**:
- Can we simplify? Cut scope?
- Should this be escalated to makato-plan for proper discovery?
- Are we solving the right problem?

### Green Flags (Scope Still Small/Medium)

- 3-7 clear steps
- Few or no external dependencies
- Straightforward work (no prototyping needed)
- Touches 5-12 files
- Extends existing subsystems (no new architecture)

## Implementation Plan Template

Use this structure in the design artifact:

```markdown
## Implementation Plan

### Step 1: <Phase Name>
**What:** <what gets done in this step>
**Output:** <what exists after this step>
**Risk:** <risks, or "None">

### Step 2: <Phase Name>
**What:** <what gets done in this step>
**Depends on:** Step 1 (or "None" if independent)
**Output:** <what exists after this step>
**Risk:** <risks, or "None">

...

### Step N: Verify End-to-End
**What:** Manual testing in local environment
**Output:** Confirmed working implementation
**Risk:** None
```

## Validation Before Finalizing

Before presenting the plan to the user, check:

- [ ] Each step is high-level (not a task checklist)
- [ ] Steps are ordered logically (no dependencies violated)
- [ ] Risks are identified and mitigation is noted
- [ ] Scope still fits small/medium (3-7 steps, not 20+)
- [ ] The plan is actionable (execute skill can follow this)

If any item fails, revise the plan.

## Example: Complete Implementation Plan

```markdown
## Implementation Plan

### Step 1: Implement Backend Validation
**What:** Add `isLastAdmin()` check in `userService.deleteAccount()`. If user is last admin, throw `ValidationError`.
**Output:** Backend prevents deletion of last admin, returns 403 error.
**Risk:** None (straightforward business logic).

### Step 2: Create Confirmation Dialog UI
**What:** Build `DeleteAccountDialog.tsx` component with title, warning text, Cancel and Confirm buttons.
**Output:** Reusable dialog component ready to integrate.
**Risk:** None.

### Step 3: Wire Delete Flow
**What:** Add "Delete Account" button to User Profile. On click, show dialog. On Confirm, call `userService.deleteAccount()`. Handle success (toast + redirect) and error (toast).
**Depends on:** Steps 1 and 2.
**Output:** Full user flow is functional.
**Risk:** Need to verify API permissions allow users to delete their own accounts. Test early in this step.

### Step 4: Add Tests
**What:**
- Unit: `DeleteAccountDialog` interaction tests
- Unit: `userService.deleteAccount()` validation tests
- Integration: Full delete flow (API + DB)
**Depends on:** Step 3.
**Output:** Test coverage for new behavior.
**Risk:** None.

### Step 5: Verify End-to-End
**What:** Manual test in local environment. Create test users, delete as non-admin (should succeed), delete as last admin (should fail).
**Depends on:** Step 4.
**Output:** Confirmed working implementation.
**Risk:** None.
```

This plan is:
- High-level (5 steps, not 50)
- Ordered (backend first, UI next, tests last)
- Testable (each step has clear output)
- Risk-aware (flags auth concern early)
