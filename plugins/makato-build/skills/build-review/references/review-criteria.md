# Review Criteria

## The Seven Review Categories

Apply all seven to every changed file. Read the diff AND surrounding context — callers,
callees, the file before the change. Never review a diff in isolation.

---

### 1. Correctness

Does the implementation do exactly what the acceptance criteria require?

Check:
- Map every AC to a specific code path. If an AC has no corresponding code path, that is
  a CRITICAL finding — missing implementation.
- Verify conditional logic covers all branches the AC implies. Off-by-one errors, wrong
  comparison operators, and inverted conditions are classic correctness failures.
- Check that return values and side effects match the contract documented in the plan.

**CRITICAL if:** an AC is not implemented, a condition is inverted, or an output is wrong.

---

### 2. Edge Cases

What happens at boundaries and under unexpected inputs?

Check:
- Null / nil / empty inputs: is the contract explicit, and is it enforced?
- Boundary values: zero, negative numbers, empty collections, single-element collections,
  maximum-size collections.
- Concurrent access: if the code is called from multiple threads or async contexts, are
  shared resources protected?
- Ordering dependencies: does the code assume inputs arrive in a particular order?

**CRITICAL if:** an unhandled edge case will cause data corruption, data loss, or an
unhandled exception visible to the end user.
**MAJOR if:** the edge case is reachable on a real-but-lower-likelihood path and degrades
behaviour (wrong-but-recoverable output, a missing guard masked by a current caller)
without corrupting data.
**SUGGESTION if:** the edge case is theoretical only and has no behavioural consequence
on any realistically reachable path.

---

### 3. Error Handling

Are all failure paths handled correctly?

Check:
- Every operation that can fail (I/O, network calls, DB queries, external APIs) has an
  explicit error path.
- Errors are handled at the right level — not swallowed silently, not re-thrown raw where
  a domain error is more appropriate.
- Error messages contain enough context to diagnose the issue without exposing sensitive
  data.
- Resources (connections, file handles, locks) are released in error paths, not just
  success paths.

**CRITICAL if:** an error is silently swallowed where it changes correctness, or a
resource leak will accumulate under normal error conditions.

---

### 4. Security

Is the code safe against common attack vectors?

Check:
- User-supplied input is validated and sanitized before use in queries, commands, or
  rendered output (SQL injection, command injection, XSS).
- Secrets, credentials, and PII are not written to logs, error messages, or responses.
- Authorization checks happen at the right boundary — not only in the UI layer.
- Deserialization of untrusted data uses safe patterns.

**CRITICAL if:** any of the above is absent where external input reaches a sensitive
operation.

---

### 5. Contract Adherence

Does the public interface match what callers expect?

Check:
- Method signatures, return types, and thrown exceptions match the existing callers if
  this is a modification to an existing interface.
- New public methods are documented with their preconditions and postconditions if the
  codebase has a documentation convention.
- Deprecations or breaking changes are flagged explicitly — the reviewer should not
  silently fix them.

**CRITICAL if:** a caller will break due to a changed signature or behavior that the
plan did not account for.

---

### 6. Test Coverage

Does the test suite cover what matters?

Check:
- Every AC has at least one test that would fail if the AC were not implemented.
- The primary error path for each new operation has a test.
- Boundary values from the edge-case category above are exercised in tests where they
  are CRITICAL.
- Tests assert on observable behavior, not on implementation internals (see
  `post-impl-test-guide.md` in `implement-goal` for the behavioral vs. implementation
  test distinction).

**CRITICAL if:** an AC has no test, or a CRITICAL edge case has no test.

---

### 7. Improvements and Optimizations

Is there a clearly better approach that the author missed?

Check:
- **N+1 queries**: is the code loading related data inside a loop when it could be
  batch-loaded before the loop?
- **Unnecessary allocations**: are objects or collections created inside tight loops when
  they could be created once?
- **Inefficient algorithms**: is there an O(n²) operation where O(n log n) or O(n) is
  straightforward?
- **Resource waste**: are connections, streams, or threads created per-request when a
  pool exists?
- **Missed caching**: is an expensive computation repeated on every call when the result
  is stable?

Only flag improvements where the better approach is evident and not speculative. Do not
suggest micro-optimizations unless the code is on a known hot path.

**CRITICAL if:** the inefficiency will cause production failures under expected load.
**MAJOR if:** the inefficiency degrades performance on a realistic path (an N+1 on a
common code path, an O(n²) over user-controlled input) without causing outright failure.
**SUGGESTION otherwise.**

---

## Classification Summary

| Question | Level |
|---|---|
| Will this cause data loss, corruption, or an unmet AC in production? | CRITICAL |
| Is this a real correctness/security concern below the CRITICAL bar — a lower-likelihood bug, a missing guard currently masked by a caller, an unhandled edge case that degrades behaviour, or an untested failure path? | MAJOR |
| Could this make the code harder to maintain, with no behavioural consequence? | SUGGESTION |
| Style, naming, minor clarity — no functional impact | NITPICK |

The MAJOR tier exists to stop correctness concerns from being under-rated as SUGGESTION. If a finding touches correctness, security, or a real failure path but does not clear the CRITICAL bar, it is **MAJOR**, not SUGGESTION. SUGGESTION is reserved for pure maintainability — anything that could change observable behaviour on some path is MAJOR or CRITICAL.

Decision order, applied in sequence:

1. Would a user experience a wrong result or security exposure? → **CRITICAL**
2. Else, is it correctness-adjacent (real but lower-likelihood bug, missing guard, untested failure path)? → **MAJOR**
3. Else, would a future developer have to work harder to maintain it? → **SUGGESTION**
4. Else → **NITPICK**

Distinguish CRITICAL from MAJOR by the impact and reachability described above, not
by whether a human is present: **both block verify/push in both modes**. Between
MAJOR and SUGGESTION, ask whether correctness, security, or a real failure path is
involved. If yes, use MAJOR or CRITICAL, never SUGGESTION because it is "unlikely".

## The Adversarial Stance

The default assumption is: the author made at least one mistake. The reviewer's job is
to find it. A review that finds nothing has not proven the code is correct — it has
proven the reviewer was not looking hard enough.

This does not mean being obstructive. It means being thorough. Flag real issues. Do not
invent issues. Do not flag style as CRITICAL. But do look actively, not passively.
