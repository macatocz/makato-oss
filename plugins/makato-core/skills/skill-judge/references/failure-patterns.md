# Common Failure Patterns

## Pattern 1: The Tutorial

```text
Symptom: Explains what PDF is, how Python works, basic library usage
Root cause: Author assumes Skill should "teach" the model
Fix: Claude already knows this. Delete all basic explanations.
     Focus on expert decisions, trade-offs, and anti-patterns.
```

## Pattern 2: The Dump

```text
Symptom: SKILL.md is 800+ lines with everything included
Root cause: No progressive disclosure design
Fix: Core routing and decision trees in SKILL.md (<300 lines ideal)
     Detailed content in references/, loaded on-demand
```

## Pattern 3: The Orphan References

```text
Symptom: References directory exists but files are never loaded
Root cause: No explicit loading triggers
Fix: Add "MANDATORY - READ ENTIRE FILE" at workflow decision points
     Add "Do NOT Load" to prevent over-loading
```

## Pattern 4: The Checkbox Procedure

```text
Symptom: Step 1, Step 2, Step 3... mechanical procedures
Root cause: Author thinks in procedures, not thinking frameworks
Fix: Transform into "Before doing X, ask yourself..."
     Focus on decision principles, not operation sequences
```

## Pattern 5: The Vague Warning

```text
Symptom: "Be careful", "avoid errors", "consider edge cases"
Root cause: Author knows things can go wrong but hasn't articulated specifics
Fix: Specific NEVER list with concrete examples and non-obvious reasons
     "NEVER use X because [specific problem that takes experience to learn]"
```

## Pattern 6: The Invisible Skill

```text
Symptom: Great content but skill rarely gets activated
Root cause: Description is vague, missing keywords, or lacks trigger scenarios
Fix: Description must answer WHAT, WHEN, and include KEYWORDS
     "Use when..." + specific scenarios + searchable terms

Example fix:
BAD:  "Helps with document tasks"
GOOD: "Create, edit, and analyze .docx files. Use when working with
       Word documents, tracked changes, or professional document formatting."
```

## Pattern 7: The Wrong Location

```text
Symptom: "When to use this Skill" section in body, not in description
Root cause: Misunderstanding of three-layer loading
Fix: Move all triggering information to description field
     Body is only loaded AFTER triggering decision is made
```

## Pattern 8: The Over-Engineered

```text
Symptom: README.md, CHANGELOG.md, INSTALLATION_GUIDE.md, CONTRIBUTING.md
Root cause: Treating Skill like a software project
Fix: Delete all auxiliary files. Only include what Agent needs for the task.
     No documentation about the Skill itself.
```

## Pattern 9: The Freedom Mismatch

```text
Symptom: Rigid scripts for creative tasks, vague guidance for fragile operations
Root cause: Not considering task fragility
Fix: High freedom for creative (principles, not steps)
     Low freedom for fragile (exact scripts, no parameters)
```

## Pattern 10: The Unstable Path

```text
Symptom: Skill derives file paths for persistent state using `pwd`
Check: If two sessions invoked this skill from different directories in
       the same repo, would they share the same state file?
Root cause: Project-scoped state is keyed to the working directory, not the repo
Fix: Use `git rev-parse --show-toplevel` instead of `pwd` for repo-stable paths
```

## Pattern 11: The Repeat Questioner

```text
Symptom: Skill asks the same preference every invocation (e.g. "Quick or Full?")
Check: If the user answered this question once, would they answer the same
       way next time? If yes, the skill should persist it — not re-ask.
Root cause: No distinction between session-scoped and durable preferences
Fix: Classify each question's answer by scope before asking:
     - Session: changes per invocation → ask every time
     - Project: same within a repo, differs across repos → project memory
     - User: same everywhere → ~/.config/claude-skills/<skill_name>/settings.json
Signal: If the "right" setting would be the same for every user, the skill's
        defaults are wrong — update the skill, don't add a settings file.
        Settings in the skill's own directory (~/.claude/skills/<name>/) are
        this smell: they indicate the skill should change its defaults, not
        that it needs runtime configuration.
```

## Pattern 12: The Copy-Paste Integration

```text
Symptom: Skill contains step-by-step API commands, authentication flows, or
         host-detection logic for an external system that another skill already owns
Check: Does another skill in the same installation already own these mechanics?
       (e.g. a `github` skill owns GHE detection, a `jira` skill owns Jira API calls)
Root cause: Author embedded the full "how" instead of declaring the "what"
Fix: Trim to intent — state what data is needed and let the owning skill
     handle the mechanics. "Fetch the issue's summary and acceptance criteria"
     not "curl -H 'Authorization: Bearer $JIRA_PAT' https://..."
Signal: If a skill's instructions would break when the owning skill updates
        its API calls, authentication method, or host detection, the coupling
        is a drift risk — the copy will silently go stale.
```
