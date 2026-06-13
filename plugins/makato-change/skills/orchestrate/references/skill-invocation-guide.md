# Skill Invocation Guide

How to invoke each of the four makato-change phase skills from the orchestrate skill using the Skill tool.

## Skill Tool Usage

The `Skill` tool invokes other skills within the same plugin. For makato-change skills:

```
Skill(skill="<skill-name>")
```

Since the orchestrate skill is already within the makato-change plugin, you don't need the `makato-change:` prefix when invoking sibling skills.

## Phase Skills

### 1. Analyze (Requirements Refinement)

**When to invoke:**
- Starting a new change request
- User wants to refine or update requirements
- `analysis.md` doesn't exist or user wants to re-analyze

**Invocation:**
```
Skill(skill="analyze")
```

**What it does:**
- Fetches Jira issue details
- Compares current behavior vs requested behavior
- Identifies questions and inconsistencies
- Updates Jira with refined requirements
- Produces `specs/<ISSUE_KEY>/analysis.md`

**Prerequisites:** None (can run at any time)

---

### 2. Design (Technical Approach)

**When to invoke:**
- `analysis.md` exists (analyze complete)
- User is ready to plan technical approach
- User wants to update/revise design

**Invocation:**
```
Skill(skill="design")
```

**What it does:**
- Reads `analysis.md` for context
- Discovers affected code (guided or exploratory)
- Plans solution approach
- Updates Jira with design summary
- Produces `specs/<ISSUE_KEY>/design.md`

**Prerequisites:**
- `analysis.md` must exist
- If missing, warn user and offer to run analyze first

---

### 3. Execute (Implementation + PR)

**When to invoke:**
- `design.md` exists (design complete)
- User is ready to implement changes
- User wants to create or update PR

**Invocation:**
```
Skill(skill="execute")
```

**What it does:**
- Reads `analysis.md` and `design.md` for context
- Implements code changes following design
- Updates/adds tests
- Runs verification (tests + dev server if needed)
- Creates PR with structured description
- Links PR back to Jira
- Produces commits and PR

**Prerequisites:**
- `design.md` must exist
- If missing, warn user and offer to run design first

---

### 4. Resolve Review (Review Feedback)

**When to invoke:**
- PR exists (execute complete)
- PR has review comments that need addressing
- User wants to respond to reviewer feedback

**Invocation:**
```
Skill(skill="resolve-review")
```

**What it does:**
- Identifies PR from Jira or PR number
- Fetches review comments
- Addresses each comment (code fix or reply)
- Runs tests after changes
- Commits and pushes fixes
- Posts replies to reviewers
- Updates Jira with summary

**Prerequisites:**
- PR must exist
- If no PR, error and recommend running execute first

---

## Error Handling

If a skill fails during invocation:

1. **Check the error message**
   - May indicate missing prerequisites
   - May indicate configuration issue (MCP server not available)

2. **Inform the user**
   - Explain what failed
   - Show the error message
   - Offer options: retry, skip to different phase, exit

3. **Don't auto-retry**
   - User may need to fix something first
   - Let user decide whether to retry

## Passing Context

Phase skills read artifacts from `specs/<ISSUE_KEY>/`:
- Analyze produces `analysis.md`
- Design reads `analysis.md`, produces `design.md`
- Execute reads both, produces PR
- Resolve Review reads both, updates PR

You don't need to pass context explicitly — the skills know where to find artifacts based on the Jira key the user provided.

## Invocation Patterns

**Sequential (most common):**
```
Skill(skill="analyze")
# Wait for completion, then:
Skill(skill="design")
# Wait for completion, then:
Skill(skill="execute")
# Wait for completion, then:
Skill(skill="resolve-review")
```

**Re-running a phase:**
```
# User wants to update design
Skill(skill="design")
# This overwrites existing design.md
```

**Skipping phases (not recommended, but allowed):**
```
# User says "I already analyzed this, go straight to design"
# Warn about missing analysis.md, then:
Skill(skill="design")
```

## Validation After Invocation

After invoking a skill, check that it completed successfully:

- Analyze: `analysis.md` should exist
- Design: `design.md` should exist
- Execute: PR link should be in Jira remote links
- Resolve Review: PR should have replies or new commits

If artifact doesn't appear, the skill may have exited early or failed. Ask user if they want to retry.
