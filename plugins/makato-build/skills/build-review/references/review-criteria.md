# Review Criteria

## The Seven Review Categories

Apply all seven to every changed file. Read the diff AND surrounding context — callers, callees, the
file before the change. Never review a diff in isolation.

---

### 1. Correctness

Does the implementation do exactly what the acceptance criteria require?

Check:

- Map every AC to a specific code path. If an expected behavior has no implementing path,
  demonstrate the reachable input and missing/wrong outcome before filing a blocking finding; do not
  infer a critical regression from a missing code reference alone.
- Verify conditional logic covers all branches the AC implies. Off-by-one errors, wrong comparison
  operators, and inverted conditions are classic correctness failures.
- Check that return values and side effects match the contract documented in the plan.

**CRITICAL if:** a reachable behavioral test/reproduction demonstrates an unmet AC, wrong output,
security exposure, or data-integrity failure with consequential impact.

---

### 2. Edge Cases

What happens at boundaries and under unexpected inputs?

Check:

- Null / nil / empty inputs: is the contract explicit, and is it enforced?
- Boundary values: zero, negative numbers, empty collections, single-element collections,
  maximum-size collections.
- Concurrent access: if the code is called from multiple threads or async contexts, are shared
  resources protected?
- Ordering dependencies: does the code assume inputs arrive in a particular order?

**CRITICAL if:** an unhandled edge case will cause data corruption, data loss, or an unhandled
exception visible to the end user. **MAJOR if:** the edge case is reachable on a
real-but-lower-likelihood path and degrades behaviour (wrong-but-recoverable output, a missing guard
masked by a current caller) without corrupting data. **SUGGESTION if:** the edge case is theoretical
only and has no behavioural consequence on any realistically reachable path.

---

### 3. Error Handling

Are all failure paths handled correctly?

Check:

- Every operation that can fail (I/O, network calls, DB queries, external APIs) has an explicit
  error path.
- Errors are handled at the right level — not swallowed silently, not re-thrown raw where a domain
  error is more appropriate.
- Error messages contain enough context to diagnose the issue without exposing sensitive data.
- Resources (connections, file handles, locks) are released in error paths, not just success paths.

**CRITICAL if:** an error is silently swallowed where it changes correctness, or a resource leak
will accumulate under normal error conditions.

---

### 4. Security

Is the code safe against common attack vectors?

Check:

- User-supplied input is validated and sanitized before use in queries, commands, or rendered output
  (SQL injection, command injection, XSS).
- Secrets, credentials, and PII are not written to logs, error messages, or responses.
- Authorization checks happen at the right boundary — not only in the UI layer.
- Deserialization of untrusted data uses safe patterns.

**CRITICAL if:** any of the above is absent where external input reaches a sensitive operation.

---

### 5. Contract Adherence

Does the public interface match what callers expect?

Check:

- Method signatures, return types, and thrown exceptions match the existing callers if this is a
  modification to an existing interface.
- New public methods are documented with their preconditions and postconditions if the codebase has
  a documentation convention.
- Deprecations or breaking changes are flagged explicitly — the reviewer should not silently fix
  them.

**CRITICAL if:** a caller will break due to a changed signature or behavior that the plan did not
account for.

---

### 6. Test Coverage

Does the test suite cover what matters?

Check:

- Every AC has at least one test that would fail if the AC were not implemented.
- The primary error path for each new operation has a test.
- Boundary values from the edge-case category above are exercised in tests where they are CRITICAL.
- Tests assert on observable behavior, not on implementation internals (see
  `post-impl-test-guide.md` in `implement-goal` for the behavioral vs. implementation test
  distinction).

Missing test coverage by itself is not a CRITICAL/MAJOR defect; report the AC verdict as unverified.
File a blocker only when a reachable behavior or real failure path is demonstrated, with the
severity determined by impact and likelihood.

---

### 7. Improvements and Optimizations

Is there a clearly better approach that the author missed?

Check:

- **N+1 queries**: is the code loading related data inside a loop when it could be batch-loaded
  before the loop?
- **Unnecessary allocations**: are objects or collections created inside tight loops when they could
  be created once?
- **Inefficient algorithms**: is there an O(n²) operation where O(n log n) or O(n) is
  straightforward?
- **Resource waste**: are connections, streams, or threads created per-request when a pool exists?
- **Missed caching**: is an expensive computation repeated on every call when the result is stable?

Only flag improvements where the better approach is evident and not speculative. Do not suggest
micro-optimizations unless the code is on a known hot path.

**CRITICAL if:** the inefficiency will cause production failures under expected load. **MAJOR if:**
the inefficiency degrades performance on a realistic path (an N+1 on a common code path, an O(n²)
over user-controlled input) without causing outright failure. **SUGGESTION otherwise.**

---

## Classification Summary

| Question                                                                                                                                                                  | Level      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| Is there an actual reachable behavioral regression with consequential wrong output, security exposure, data-integrity loss, or an unmet AC demonstrated by that behavior? | CRITICAL   |
| Is there a concrete reachable correctness/security concern or real failure path with lower impact or likelihood?                                                          | MAJOR      |
| Could this make the code harder to maintain, with no demonstrated behavioral consequence?                                                                                 | SUGGESTION |
| Style, naming, minor clarity — no functional impact                                                                                                                       | NITPICK    |

The MAJOR tier prevents a real correctness concern from being under-rated as SUGGESTION. Missing
audit evidence is classified by the protected invariant and demonstrated impact, not by a blanket
audit rule. SUGGESTION is reserved for pure maintainability; anything that can change reachable
observable behaviour is MAJOR or CRITICAL. A missing test alone leaves an AC unverified; it is not
automatically a blocking finding.

Decision order, applied in sequence:

1. Is there reproducible evidence of an actual reachable behavioral regression with consequential
   wrong output, security exposure, data-integrity loss, or an unmet AC demonstrated by that
   behavior? → **CRITICAL**
2. Else, is there a concrete reachable correctness/security concern or real failure path with lower
   impact or likelihood? → **MAJOR**
3. Else, would a future developer have to work harder to maintain it, with no demonstrated
   behavioral consequence? → **SUGGESTION**
4. Else → **NITPICK**

Both CRITICAL and MAJOR block verify/push in both modes. Severity is based on evidence of impact and
reachability, never on whether a human is present or a reviewer prefers fewer blockers. A missing
test can make an AC unverified, but does not by itself prove a runtime regression.

## Evidence and Confirmation

Classify from observed impact and reachability, not from a category label, wording such as
"security/audit", or a preference to reduce the blocker count. There is no automatic severity
downgrade for audit findings: a missing audit record is MAJOR or CRITICAL according to the protected
invariant, consequences, and reachable paths. Both tiers block.

Every new or unconfirmed blocking constituent is independently checked before repair by a separate
read-only reviewer in a batched confirmation dispatch. For each `finding_id` + `constituent_id`,
return exactly one status: `confirmed`, `rejected`, or `uncertain`, with reachable-path evidence,
impact, introduction status, citations, and a `repair_scope` of `local`, `architectural`,
`cross-boundary`, or `unknown`. A rejection needs evidence that the reported behavior is unreachable
or already prevented by the actual caller/contract; uncertainty, unavailable reproduction, or
disagreement remains blocking. Never use majority voting to suppress a finding. Preserve each raw
constituent and record its rejected disposition with evidence.

`repair_scope` is the safe boundary for a correct fix, not line count or file count. The gate may
authorize local repair only when all active constituents are confirmed `local`; architectural,
cross-boundary, or unknown scope requires a short independently reviewed plan. A second unsuccessful
return of the same invariant also requires redesign. CRITICAL severity alone never requires a plan.

A CRITICAL finding requires evidence of an actual reachable behavioral regression (including a
demonstrated security, data-integrity, or unmet-AC outcome), not a hypothetical risk or missing test
alone. Its repair must add a durable behavioral regression test for a plausible failing scenario. A
MAJOR finding requires a concrete reachable reproduction and a targeted behavioral verification.
Severity may change only when new evidence changes the demonstrated impact or reachability; explain
the evidence and resulting classification.

## The Adversarial Stance

The reviewer actively tests likely failure paths rather than assuming a defect exists. Zero findings
is valid only after complete applicable file/path/constraint coverage and citations are met. Report
evidence-backed issues; do not invent findings to avoid a clean result.

This does not mean being obstructive. It means being thorough. Flag real issues. Do not invent
issues. Do not flag style as CRITICAL. But do look actively, not passively.
