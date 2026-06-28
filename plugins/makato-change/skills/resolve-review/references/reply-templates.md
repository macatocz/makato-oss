# Reply Templates

Standard templates for responding to PR review comments. Adapt to context — don't copy verbatim.

## Bug Fix

When fixing a bug identified by reviewer:

```
Fixed in [commit-sha]. Added test coverage for [scenario].
```

**Example:**
```
Fixed in abc1234. Added test coverage for null email case.
```

## Security Fix

When addressing a security concern:

```
Fixed in [commit-sha]. Now using [sanitization/validation method] to prevent [vulnerability type].
```

**Example:**
```
Fixed in def5678. Now using DOMPurify.sanitize() to prevent XSS.
```

## Style/Convention Fix

When fixing a style or convention issue:

```
Fixed in [commit-sha].
```

Short and simple — no need to elaborate.

## Test Added

When adding requested test coverage:

```
Added test in [commit-sha]. Covers [scenario 1] and [scenario 2].
```

**Example:**
```
Added test in ghi9012. Covers empty array and null inputs.
```

## Explaining Approach

When reviewer questions the approach:

```
[Explanation of reasoning]. [Reference to design artifact or requirement if applicable].

Open to changing if you see a better approach.
```

**Example:**
```
We chose polling over WebSockets to avoid infrastructure changes in this phase. Per the design artifact (specs/PROJ-1234/design.md), WebSocket support is planned for phase 2 (tracked in PROJ-5678).

Open to changing if you think it's worth the additional scope.
```

## Acknowledging Good Catch

When reviewer spots an issue you missed:

```
Good catch! Fixed in [commit-sha].
```

Shows appreciation and confirms the fix.

## Agreeing to Change Approach

When adopting reviewer's suggestion:

```
Agreed. Changed to [new approach] in [commit-sha]. [Brief explanation of benefit].
```

**Example:**
```
Agreed. Changed to useMemo in jkl3456. Avoids unnecessary recalculations on every render.
```

## Deferring to Follow-Up

When improvement suggestion is out of scope:

```
Great idea. Created follow-up issue [ISSUE-KEY] to track this for next iteration.
```

Or if not creating an issue:

```
Good suggestion. This is outside the scope of this CR, but worth considering for future enhancements.
```

## Requesting Clarification

When comment is unclear:

```
Can you clarify what you mean by [X]?

I want to make sure I address this correctly.
```

Shows you care about getting it right.

## Referencing Previous Fix

When multiple comments relate to same fix:

```
Addressed in [link to other comment thread].
```

Keeps threads organized without repeating explanations.

## Disagreeing Respectfully

When you disagree with reviewer's suggestion (after discussion with user):

```
I see your point about [X]. However, [reasoning for current approach].

The current approach [benefit 1] and [benefit 2], which aligns with the requirements in [reference].

Happy to discuss further if you feel strongly about this.
```

**Example:**
```
I see your point about using Redux. However, the design artifact specifies Context API to avoid Redux overhead for this small feature (3 components, 1 shared state object).

The current approach keeps the bundle size smaller and reduces boilerplate, which aligns with the performance requirements.

Happy to discuss further if you feel strongly about this.
```

## Performance Optimization

When addressing performance concern:

```
Fixed in [commit-sha]. [What was changed] reduces [metric] from [before] to [after].
```

**Example:**
```
Fixed in mno7890. Memoized the calculation with useMemo, reduces re-renders from 50+ to 2 per state change.
```

## Edge Case Handling

When reviewer identifies edge case:

```
Good catch. Added handling for [edge case] in [commit-sha]. [Brief explanation of solution].
```

**Example:**
```
Good catch. Added handling for undefined values in pqr4567. Now returns early with default state if user object is incomplete.
```

## Batch Reply

When fixing multiple related issues in one commit:

```
Fixed in [commit-sha]:
- [Issue 1 summary]
- [Issue 2 summary]
- [Issue 3 summary]
```

**Example:**
```
Fixed in stu8901:
- Added null check for email field
- Fixed typo in error message
- Updated test to cover both scenarios
```

## Documentation Request

When asked to add documentation:

```
Added documentation in [commit-sha]. [What was documented].
```

**Example:**
```
Added documentation in vwx2345. Added JSDoc comments for all public methods and updated README with usage examples.
```

## No Change Needed

When reviewer's concern is already addressed or not applicable:

```
This is already handled by [existing code/test/validation]. See [file:line] for the implementation.
```

**Example:**
```
This is already handled by the validation middleware. See api/middleware/validateUser.ts:45 for the email format check.
```

## General Structure

All replies should follow this pattern:

1. **Acknowledgment** (if appropriate): "Good catch", "Thanks for the feedback"
2. **Action taken**: "Fixed in [commit]", "Added test", "Changed to X"
3. **Brief explanation** (if needed): Why the change was made or how it works
4. **Openness to discussion** (if appropriate): "Open to changing if...", "Happy to discuss..."

Keep replies concise. Aim for 1-3 sentences for most responses.
