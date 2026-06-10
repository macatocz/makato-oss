# `repositories.yml` Schema

> Shared contract for the `repositories.yml` file written under `specs/{ITDB-key}-{slug}/`. Created by `create-prd`, expanded by `create-architecture`, and consumed by `create-prototype` and `decompose` for codebase research and team mapping.

## File Location

```
specs/{ITDB-key}-{slug}/repositories.yml
```

## plan

```yaml
version: "1.0"
affected:
  - name: <repo-name>             # required, kebab-case repo identifier
    role: primary                  # required, one of: primary | supporting
    description: "..."             # optional, short free-text reason this repo is in scope
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | string | Yes | Schema version. Current: `"1.0"`. |
| `affected` | array | Yes | At least one entry. Repos this feature touches. |
| `affected[].name` | string | Yes | Repository identifier (matches `context/{repo}/` convention). |
| `affected[].role` | enum | Yes | `primary` = direct change target. `supporting` = adjacent repo also touched (shared lib, infra, deployment). |
| `affected[].description` | string | No | Free text explaining why the repo is affected. Helpful when downstream skills can't infer from the name alone. |

## Lifecycle

- **`create-prd`** — first writer. Writes the file at the end of PRD generation if repos were identified during the strategy interview.
- **`create-architecture`** — expander. Always re-asks (architects identify repos the PO may not have known about), merges new entries, may upgrade `supporting` → `primary` if architecture analysis reveals deeper change.
- **`create-prototype`** — reader. Uses the list to identify the target UI repo for design system research.
- **`decompose`** — reader. Uses the list for team mapping and to dispatch `context-scout` agents per repo.

## Update Mode Contract

When a downstream skill expands the file:

- Preserve all existing entries unless the user explicitly requests removal.
- Append new entries with the same plan
- Never silently rewrite a `role` value — surface the proposed change to the user first.

## Missing-File Handling

Each consumer skill defines its own behavior when `repositories.yml` is absent (typically: ask the user, then optionally write it). The schema does not mandate one approach.

## Validation

A consumer should treat the file as invalid if:
- `version` is absent or unsupported.
- `affected` is empty.
- Any entry is missing `name` or `role`.
- Any `role` value is not `primary` or `supporting`.

On invalid input, the consumer should warn the user and either fall back to asking interactively or abort, depending on the skill's needs.
