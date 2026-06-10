# Open Questions: Parking Protocol

Rules for detecting and parking unanswerable questions during brainstorming. Load during Step 4 when a question surfaces that cannot be resolved in-session.

---

## When to Park

Park a question when:
- The user says "I don't know" or "we'd need to check with {person}"
- The answer requires research, data, or stakeholder input not available now
- The question blocks a specific decision but not the overall brainstorm
- Resolving it would derail the current ideation momentum

## When NOT to Park

Do not park when:
- The user can answer with reasonable confidence (push gently)
- The question is central to the brainstorming direction (pause and discuss)
- It's a creative "what if" — those belong in the ideation, not the parking lot

---

## How to Park

1. Acknowledge: "Good question — let's park that for now so we don't lose momentum."
2. Assign a sequential ID: Q1, Q2, Q3...
3. Note the question and minimal context
4. Continue the current technique without dwelling

Keep a running buffer of parked questions during the session.

---

## Startup Check (Step 1.3)

On session start, if `decisions.md` exists with open questions:

1. Read the Open Questions table
2. Present questions with their priority (High/Medium/Low)
3. For each High priority question: ask if the user now has an answer
4. Resolved questions → move to Decision Details in decisions.md
5. Still open → leave in the table, continue to brainstorming

---

## Persistence (Step 8.1)

At the end of the session, all parked questions are written to `decisions.md`:

| # | Question | Raised In | Priority | Notes |
|---|----------|-----------|----------|-------|
| Q1 | {question text} | Discover | {High/Medium/Low} | {any context} |

**Priority assignment:**
- **High**: Blocks the next phase (grill or PRD cannot proceed without this)
- **Medium**: Should resolve during PRD creation
- **Low**: Can defer to architecture or later

**ID numbering**: Continue from the highest existing Q# in decisions.md. If no prior questions exist, start at Q1.
