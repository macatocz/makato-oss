# Review Feedback Patterns

Common patterns in PR review feedback and how to address them effectively.

## Feedback Categories

### 1. Bug or Correctness Issue

**Pattern:**
- "This will fail when X is null"
- "Edge case not handled: Y"
- "Off-by-one error here"
- "This breaks when Z happens"

**Response:**
- Fix the code immediately
- Add test coverage for the edge case
- Reply: "Fixed in [commit-sha]. Added test for [scenario]."

**Example:**
```
Reviewer: "This will crash if user.email is undefined"
Response: Fix code + add test → Reply: "Fixed in abc1234. Added test for undefined email case."
```

### 2. Security or Safety Concern

**Pattern:**
- "SQL injection risk here"
- "XSS vulnerability"
- "Need input validation"
- "This exposes sensitive data"

**Response:**
- Fix immediately (highest priority)
- Add validation/sanitization
- Add security test
- Reply: "Fixed. Added [validation/sanitization] and security test."

**Example:**
```
Reviewer: "User input not sanitized before rendering"
Response: Add sanitization → Reply: "Fixed in abc1234. Now using DOMPurify.sanitize() before rendering."
```

### 3. Question About Approach

**Pattern:**
- "Why did you choose X over Y?"
- "Can you explain this logic?"
- "Is there a reason for Z?"

**Response:**
- Explain the reasoning clearly
- Reference design artifact if relevant
- If approach is suboptimal, acknowledge and offer to change

**Example:**
```
Reviewer: "Why use polling instead of WebSockets?"
Response: "Per the design artifact, we chose polling to avoid infrastructure changes in this phase. WebSocket support is planned for phase 2 (tracked in PROJ-5678)."
```

### 4. Style or Convention

**Pattern:**
- "Use camelCase here"
- "Missing type annotation"
- "Prefer const over let"
- "Add JSDoc comment"

**Response:**
- Fix if it matches project conventions
- Reply: "Fixed in [commit-sha]."
- If linter should catch it, note that for follow-up

**Example:**
```
Reviewer: "Use const instead of let here"
Response: Fix → Reply: "Fixed in abc1234."
```

### 5. Performance Concern

**Pattern:**
- "This loops N times unnecessarily"
- "Could cache this result"
- "O(n²) complexity issue"

**Response:**
- Evaluate severity
- If real issue: fix and add benchmark/test
- If premature optimization: explain current approach, offer to optimize if needed
- Reply with rationale

**Example:**
```
Reviewer: "This loops through all users on every render"
Response: Add memoization → Reply: "Fixed in abc1234. Now memoized with useMemo, only recalculates when userList changes."
```

### 6. Test Coverage Request

**Pattern:**
- "Add test for X scenario"
- "Missing test coverage"
- "What about edge case Y?"

**Response:**
- Add the requested test
- Reply: "Added test in [commit-sha]."

**Example:**
```
Reviewer: "Add test for empty array case"
Response: Add test → Reply: "Added test in abc1234. Covers both empty array and null inputs."
```

### 7. Design Disagreement

**Pattern:**
- "Should use pattern X instead"
- "This violates principle Y"
- "Consider refactoring to Z"

**Response:**
- Discuss with user first
- Options:
  1. Adopt suggestion (if better)
  2. Explain current approach rationale (if valid)
  3. Compromise (hybrid approach)
- Reply with chosen path

**Example:**
```
Reviewer: "Should use Redux instead of Context API"
Response (after discussion): "The design artifact specifies Context API to avoid Redux overhead for this small feature. Open to revisiting if state complexity grows."
```

### 8. Improvement Suggestion

**Pattern:**
- "Nice to have: X"
- "Consider adding Y in the future"
- "Could also support Z"

**Response:**
- Acknowledge the suggestion
- Decide: implement now, or defer to follow-up
- If defer: optionally create follow-up GitHub Issues issue
- Reply: "Good idea. [Implemented now / Created follow-up issue PROJ-9999]."

**Example:**
```
Reviewer: "Could add keyboard shortcut support"
Response: "Great idea. Created PROJ-6789 to track this for next iteration."
```

## Response Tone

### Do:
- Be professional and respectful
- Acknowledge good catches: "Good catch!", "Thanks for spotting this"
- Explain reasoning clearly
- Take responsibility for mistakes
- Be concise

### Don't:
- Be defensive or dismissive
- Over-explain or ramble
- Blame others or external factors
- Use passive voice excessively
- Leave questions unanswered

## Multi-Comment Threads

If multiple comments relate to the same issue:

1. Address the root cause once
2. Reply to the primary comment with the fix
3. Reply to related comments: "Addressed in [link to primary comment]"

This keeps the thread organized and avoids repeating the same explanation.

## Batch vs. Individual Responses

**Individual:** Use for distinct, unrelated comments
**Batch:** Use when multiple comments require the same fix

For batch:
```
Fixed in abc1234:
- Addressed null check issue (Comment #1)
- Added validation (Comment #3)
- Fixed typo (Comment #7)
```

## When to Ask for Clarification

If a comment is unclear:
- Reply: "Can you clarify what you mean by X?"
- Don't guess and implement the wrong thing

## Resolving Threads

After addressing a comment:
- Make the code change + commit + push
- Reply explaining what was done
- Don't manually mark as resolved — let the reviewer do that after verifying
