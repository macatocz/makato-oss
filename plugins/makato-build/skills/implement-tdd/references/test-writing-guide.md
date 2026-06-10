# Test Writing Guide

## Unit Tests vs Integration Tests

### Unit Tests
- Scope: a single class, function, or method in isolation
- Dependencies: mocked or stubbed — no real DB, no real HTTP, no real filesystem
- Speed: must run in milliseconds; the full unit suite must be fast enough to run on every
  GREEN iteration
- Assertion style: assert on return values, state changes, and mock interactions
- File location: follow the existing project convention (e.g., `src/…test.ext`,
  `test/unit/…`, co-located with the source file)

### Integration Tests
- Scope: the boundary between two real components (service ↔ DB, service ↔ external API,
  controller ↔ service)
- Dependencies: real — use real test DB, real in-process services; mock only external
  systems that cannot be run locally (third-party SaaS, payment providers)
- Speed: slower than unit tests; run once per INTEGRATE phase and at VERIFY
- Assertion style: assert on observable outcomes at the boundary (persisted state, HTTP
  response plan, emitted events)
- File location: follow the existing project convention (e.g., `test/integration/…`,
  `src/…it.ext`)

## What to Mock

**Mock:**
- External HTTP services and third-party APIs
- Clocks and random number generators (make tests deterministic)
- Other microservices called over the network
- File system in unit tests (use real files in integration tests if the test is about FS behaviour)

**Do NOT mock:**
- The class under test
- Value objects and pure functions (no behaviour to mock)
- The real database in integration tests — use a test schema or transaction rollback instead
- Internal collaborators that are trivially constructable

## Naming Conventions

Follow what already exists in the codebase. If no convention is established, use:

```
<ClassName>Test           — unit test class
<ClassName>IT             — integration test class (Java convention)
test_<function_name>      — unit test function (Python/Go convention)
describe('<ClassName>')   — unit test block (JS/TS convention)
```

Test method names should read as sentences:
- `should_throw_when_amount_is_negative`
- `returns_empty_list_when_no_orders_exist`
- `cancels_deal_and_emits_event`

## Assertion Style

- One logical assertion per test where practical (multiple asserts on the same return value
  are fine; asserts on unrelated concerns belong in separate tests)
- Assert on the most specific observable outcome, not on implementation details
- Prefer positive assertions (`expect(x).toBe(y)`) over negated ones where both are valid
- For exceptions: assert the exception type AND message; do not assert only that any
  exception was thrown

## Test Boundary for Integration Tests

The boundary to test is the one specified in the plan's **Integration Test** field for
each task. Do not widen the scope beyond what the plan specifies — a test that crosses
three real boundaries belongs in an end-to-end suite, not an integration suite.
