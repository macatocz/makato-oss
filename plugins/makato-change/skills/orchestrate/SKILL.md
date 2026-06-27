---
name: orchestrate
description: Guide users through change request workflow (analyze, design, execute, resolve-review), track progress, coordinate phases
version: "1.0.0"
argument-hint: "[ISSUE-KEY]"
---

# orchestrate

Guide users through the complete change request workflow by coordinating the four phases: analyze requirements, design technical approach, execute implementation, and resolve review feedback.

## When to Use

Use this skill when:
- Starting a new change request implementation
- Resuming work on an existing change request
- Unsure which phase to run next
- Want a guided workflow instead of invoking individual phase skills

**Do NOT use this skill if:**
- You already know exactly which phase skill to invoke (use that skill directly)
- You're working on something other than a change request (use makato-plan for new features; for bugs, route through makato-plan if shaping is needed or makato-build if the fix is well-scoped)

## Workflow

### Step 1: Get GitHub Issues Key

Ask the user: **"What is the GitHub Issues issue key for this change request?"**

The key must be in format: `PROJECT-1234` (e.g., `PROJ-567`, `BDC-1234`)

Store: `ISSUE_KEY`

### Step 2: Detect Current Phase

Check `specs/<ISSUE_KEY>/` directory to determine workflow state:

Load @references/phase-detection.md for detection logic.

Determine:
- Which phases are complete (artifacts exist)
- What the recommended next phase is
- Whether prerequisites are met for later phases

Store the phase status in memory.

### Step 3: Display Phase Status

Show the user a progress summary:

```
Change Request Workflow: <ISSUE_KEY>

✓ Analyze (completed)
✓ Design (completed)
○ Execute (next)
○ Resolve Review (not started)
```

Use:
- ✓ for completed phases
- ● for current/recommended phase
- ○ for not-yet-started phases

### Step 4: Recommend Next Action and Offer Options

**First, state the recommendation clearly:**

Based on phase detection from Step 2, determine the recommended next phase:
- No artifacts → **Recommend: Start with Analyze**
- Analyze complete → **Recommend: Continue to Design**
- Design complete → **Recommend: Continue to Execute**
- Execute complete + PR has comments → **Recommend: Resolve Review**
- All complete → **Workflow finished**

**Present recommendation to user:**

```
🎯 Recommended Next Step: <Phase Name>

<One-sentence explanation of what this phase will do>
```

**Then offer options using `AskUserQuestion`:**

**Primary options** (always show):
1. **[RECOMMENDED] Continue to <next phase>** (if prerequisites met)
2. Re-run a completed phase (specify which)
3. Exit workflow

**Additional options** (show conditionally):
- Skip to execute (only if analyze + design complete, warn about skipping)
- Skip to resolve-review (only if PR exists in GitHub Issues, warn about skipping)

For each option, show:
- What will happen
- Whether prerequisites are met
- Warning if action might overwrite existing work

### Step 5: Invoke Selected Skill

Based on user selection, invoke the appropriate phase skill:

Load @references/skill-invocation-guide.md for invocation patterns.

Use the `Skill` tool to invoke:
- Analyze → `Skill(skill="analyze")`
- Design → `Skill(skill="design")`
- Execute → `Skill(skill="execute")`
- Resolve Review → `Skill(skill="resolve-review")`

Wait for the skill to complete before continuing.

### Step 6: Post-Phase Check

After the invoked skill completes:

1. Re-run phase detection (Step 2) to update progress
2. Check if the phase actually completed:
   - Analyze: `analysis.md` should exist
   - Design: `design.md` should exist
   - Execute: PR link should exist in GitHub Issues
   - Resolve Review: verify comments were addressed

If the phase did not complete (user exited early or error occurred):
- Show current state
- Ask if user wants to retry or move to a different phase

### Step 7: Loop or Exit

Check if all phases are complete:
- Analyze artifact exists
- Design artifact exists
- Execute complete (PR link in GitHub Issues)
- Resolve Review complete (no unresolved comments, or user confirms done)

**If all phases complete**: Auto-exit with final summary:

```
✅ Change Request Workflow Complete: <ISSUE_KEY>

✓ All phases finished
PR: <link>

Next:
- Monitor PR for approval
- Merge when approved
```

**If phases remain**: Re-detect current state (Step 2) and present recommendation:

```
🎯 Recommended Next Step: <Phase Name>

<One-sentence explanation>
```

Then ask the user: **"What would you like to do next?"**

Options:
1. **[RECOMMENDED] Continue to <next phase>** (show which phase is next)
2. **Re-run a phase** (specify which)
3. **Exit workflow**

**If continuing**: Return to Step 3 (display updated status) and loop.

**If exiting before completion**: Present status summary:

```
Change Request Workflow: <ISSUE_KEY>

Current Progress:
✓ Analyze (completed)
✓ Design (completed)
✓ Execute (completed)
○ Resolve Review (not started)

Next Steps:
- Wait for PR review feedback
- Invoke /makato-change:orchestrate again when ready to resolve review comments
```

## Edge Cases

**User wants to skip phases:**
- Warn that artifacts from skipped phases won't exist
- Explain what information will be missing
- Offer to run the prerequisite phase first
- Only allow skip if user explicitly confirms

**Artifacts exist but are incomplete/corrupt:**
- Detect by checking file size or key sections
- Offer to re-run that phase
- Don't auto-delete — let user decide

**Multiple people working on same change request:**
- The orchestrator doesn't lock — assumes one person at a time
- If artifacts change unexpectedly, re-detect and show updated state
- User can see what's been done and pick up where previous person left off

**GitHub Issues issue type is not Story or Activity:**
- Warn the user
- Offer to continue anyway (some orgs use custom types)
- Phase skills will validate and may block if truly incompatible
