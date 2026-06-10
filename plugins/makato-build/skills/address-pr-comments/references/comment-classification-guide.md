# Comment Classification Guide

## Four Tiers

### MUST-FIX
The PR cannot merge in its current state because of this comment.

Applies when:
- Correctness bug: the code produces wrong output or wrong behavior
- Security issue: input not validated, credentials exposed, injection risk
- Broken contract: public API, schema, or shared DTO changed in a breaking way
- CI / build failure: the branch does not compile or tests fail in CI
- Security scanner finding (regardless of severity label — scanner findings block merge)
- Reviewer explicitly marks the comment as a blocker ("blocking", "must", "required")

### SHOULD-FIX
A clear, specific improvement that makes the code objectively better. Not a blocker, but leaving it would be a mistake.

Applies when:
- Naming: a name is misleading, inconsistent with surrounding code, or violates conventions
- Readability: a method is too long, nesting is too deep, logic is hard to follow
- Error message quality: an exception message is unhelpful or misleading
- Lint bot error: a configured lint rule is violated (treat as SHOULD-FIX, not MUST-FIX, unless it causes a build failure)
- Reviewer uses language like "should", "please", "this would be better as"

When in doubt between MUST-FIX and SHOULD-FIX: if a future reader would be confused or misled by the current code, it's SHOULD-FIX. If the current code is wrong or unsafe, it's MUST-FIX.

### CONSIDER
A stylistic opinion, speculative improvement, or suggestion where reasonable people disagree. The current code is correct; this is about preference.

Applies when:
- Automated review tool suggestion (Hyperspace, review bots) with no clear correctness implication
- Reviewer uses language like "consider", "maybe", "might be nicer", "personal preference", "nit"
- An alternative design that's equally valid but different from what was implemented
- A future improvement that would require scope expansion

Present to user. Implement only if user agrees.

### OUT-OF-SCOPE
The comment requests something outside the boundaries of this story.

Applies when:
- The request adds a feature not in the acceptance criteria
- The request contradicts a decision in `decisions.md` or an approved ADR
- The request belongs to a different service, component, or team
- The request is about something that was intentionally deferred

Action: reply explaining why it's out of scope. If the request is valid but deferred, note that it will be tracked separately. Never implement.

---

## Structural Escalation

A MUST-FIX is **structural** when fixing it requires changing the implementation approach, not just the code within the approach.

**Structural (escalate to /refine):**
- "The data model is wrong — this needs a separate join table, not a column"
- "This service shouldn't own this logic — it belongs in the domain layer"
- "The API contract is backwards — callers expect X, you return Y"
- "This algorithm is O(n²) and the dataset is 10M rows — needs a different approach"

**Fixable (fix in place):**
- "This method name is wrong"
- "Missing null check on line 42"
- "This test assertion is backwards"
- "The error message says 'user' but should say 'account'"

The test: "Can I fix this by editing lines within the current design?" If yes, fix in place. If the fix requires redesigning what was built, escalate.

---

## Ambiguous Comments

When a comment is unclear about intent:
1. Read the surrounding diff context — does the comment make sense as a correctness concern or a style preference?
2. If still ambiguous, classify conservatively (SHOULD-FIX over CONSIDER; MUST-FIX over SHOULD-FIX)
3. Surface the ambiguity to the user in Step 5 with a note: "Classified as SHOULD-FIX — unclear if blocking; adjust if needed"

---

## Writing OUT-OF-SCOPE Replies

Keep it short and non-defensive. State the scope boundary, not a judgment on the suggestion.

**Good:**
> "This falls outside DCP-1234's scope — adding audit logging to all endpoints would require changes across 12 services. Will track separately."

**Avoid:**
> "I don't think this is a good idea because..."
> "This would take too long to implement..."
