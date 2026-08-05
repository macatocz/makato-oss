# Default fix commands (Branch 1 fallback table)

Used when `finding-routes.json` has no entry for `<tool>:<rule>` and
`autofix_available == true`. These are the fallback commands this skill
constructs automatically — not magic the caller supplies.

| tool         | default cmd                           |
|--------------|---------------------------------------|
| ruff         | `ruff check --fix <path>`             |
| ruff-format  | `ruff format <path>`                  |
| prettier     | `prettier --write <path>`             |
| eslint       | `eslint --fix <path>`                 |
| black        | `black <path>`                        |
| isort        | `isort <path>`                        |

All commands are run from `repo_root`.  If the tool is not in this table
and there is no route, `autofix_available: true` cannot be acted on — fall
through to Branch 4 carry-over.
