# Team-Repository Mapping

## Usage

During decomposition, stories are assigned to teams based on which repositories
they touch. This file holds the mapping for the current project.

**This file is project-specific** — update it with the actual teams and repositories
for the project you are working on. The entries below are examples only.

## Example Mapping

| Team | Repositories | Focus |
|------|-------------|-------|
| Platform | platform-core, shared-libs | Shared infrastructure and utilities |
| Frontend | web-app, mobile-app | User-facing interfaces |
| Backend | api-service, data-service | Business logic and data access |

## Mapping Logic

1. Identify repositories from `repositories.yml`
2. Match to teams using the table above
3. Present proposed mapping to user for confirmation
4. If a story touches repos from multiple teams → assign all relevant teams
5. If a story is pure integration (no single repo owns it) → assign the team closest to the user-facing outcome

## When Mapping Fails

If the user identifies a repository or team not in this table:

- Accept their input as authoritative
- Note: this reference should be updated with new mappings for future sessions

## teams Field in stories.json

`stories[].teams` is a free-text string array. Enter team names exactly as your
project uses them. There is no fixed allowlist.
