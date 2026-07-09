# Capability Extraction Rules

When archiving a completed feature, extract capabilities from PRD user stories and append them to
the `## Current Requirements` section of the master spec. This keeps the master spec current with
what the product can do.

## Extraction Rule

| PRD Format | Extracted Capability |
|------------|----------------------|
| `As a {persona}, I want to {action}, so that {benefit}` | `{Persona} can {action}` |

**Example:**

```
PRD: "As a registered user, I want to submit a claim, so that it can be assessed"
→   "Registered users can submit a claim"
```

## Fallback (No User Story Format)

If the PRD does not use the `As a / I want to` format, use the story title:

```text
### Story 3: Export Assessment Report
→ Capability: "Export Assessment Report"
```

## Edge Cases

| Case | Handling |
|------|----------|
| No PRD exists | Skip capability extraction; log a warning in Evolution Log |
| Story title only (no body) | Use title directly as capability |
| Duplicate capability | Skip if exact text already exists in master spec |
| Very long action text | Truncate to 120 chars; preserve meaning |

## Output Format

Capabilities go under `## Current Requirements` as individual requirements:

```markdown
### {Capability}

{Persona} can {action}.

*Source: {spec-folder} · {YYYY-MM-DD}*
```
