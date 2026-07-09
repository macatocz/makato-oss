# Master Spec Format

Master specs accumulate validated domain knowledge from completed features.
One file per domain under `specs/master/`.

## File Structure

```markdown
# Master Spec: {DOMAIN}

**Last Updated**: {YYYY-MM-DD}
**Features Merged**: {count}

---

## Current Requirements

### {Requirement Name}

The system MUST/SHALL/SHOULD {behavior}.

*Source: {feature-folder} · {YYYY-MM-DD}*

---

## Evolution Log

| Date | Feature | Change Type | Summary | Rationale |
|------|---------|-------------|---------|-----------|

---

## Superseded Requirements

| Requirement | Superseded By | Date | Feature | Reason |
|-------------|---------------|------|---------|--------|
```

## Domain Resolution

Determine domain from (in order):

1. `domain:` field in `plan.md` or `spec.md` frontmatter
2. Keyword detection from PRD titles and user stories:
   - `authentication` → login, auth, password, session, token
   - `workflows` → workflow, task, spec, archive, phase
   - `integrations` → github, api, webhook, mcp, external
   - `ui-components` → ui, component, screen, modal, form, dashboard
   - `reporting` → report, metric, analytics, audit
3. Default: `general`

## Merge Rules

- **ADDED**: append under `## Current Requirements` with source annotation
- **MODIFIED**: replace the existing requirement; move old version to Superseded with reason
- **REMOVED**: move to Superseded with reason "explicitly dropped"
- Always append one row to `## Evolution Log`
- Never delete from Superseded — it is an audit trail

## Conflict Handling

If an incoming requirement overlaps an existing one:

1. Show both to the user with a diff
2. Options: supersede (replace), merge (combine), skip (don't add)
3. Record the decision in Evolution Log rationale column
