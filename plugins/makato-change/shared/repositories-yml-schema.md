# `repositories.yml` Schema

> Contract for the `repositories.yml` file written under `specs/{jira-key}/`. Created by the `analyze` skill and consumed by `design`, `execute`, and `resolve-review` skills for cross-repository operations.

## File Location

```
specs/{jira-key}/repositories.yml
```

## Shape

```yaml
version: "1.0"
affected:
  - name: <repo-name>             # required, kebab-case repo identifier
    role: primary                  # required, one of: primary | supporting
    path: <repo-name>               # required, repo name for automatic resolution
    description: "..."             # optional, short free-text reason this repo is in scope
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | string | Yes | Schema version. Current: `"1.0"`. |
| `affected` | array | Yes | At least one entry. Repos this change request touches. |
| `affected[].name` | string | Yes | Repository identifier (e.g., "dcp-portal-ui", "dcp-backend-services"). Used as `path` value for automatic resolution. |
| `affected[].role` | enum | Yes | `primary` = direct change target. `supporting` = adjacent repo for context (not currently used by makato-change, reserved for future multi-repo support). |
| `affected[].path` | string | Yes | Repository name (same as `name` field). Will be automatically resolved to local path. |
| `affected[].description` | string | No | Free text explaining why the repo is affected. Helpful for future reference. |

## Path Resolution

The `path` field should contain only the **repository name** (matching the `name` field). Consumer skills automatically resolve this to the local repository path using multiple search strategies.

### Standard Value

```yaml
path: dcp-portal-ui
```

**Resolution**: Skills search for the repository in standard locations automatically. No configuration needed.

### Resolution Algorithm

When loading `repositories.yml`, consumers apply these search strategies in order:

**Strategy 1: Sibling to dcp-specs**
```
repos/
├── dcp-specs/          ← invoked from here
│   └── specs/DCP-1234/repositories.yml
└── dcp-portal-ui/      ← found here
```
Check: `<specs-parent>/../<repo-name>`

**Strategy 2: Same parent directory**
```
repos/
├── dcp-specs/
│   └── specs/DCP-1234/repositories.yml
└── projects/
    └── dcp-portal-ui/  ← found here
```
Check: `<specs-parent>/../*/<repo-name>` (one level deeper)

**Strategy 3: Current working directory**
```
dcp-portal-ui/          ← invoked from here
└── specs/DCP-1234/repositories.yml
```
Check: `git rev-parse --show-toplevel` and verify basename matches `<repo-name>`

**Strategy 4: Parent of specs directory**
```
dcp-portal-ui/          ← found here
└── specs/DCP-1234/repositories.yml
```
Check: `<specs-parent>` and verify basename matches `<repo-name>`

### Path Validation

After resolving the path, verify:
```bash
test -d <RESOLVED_PATH> && test -d <RESOLVED_PATH>/.git
```

If all strategies fail, show error:
```
Error: Cannot locate repository "dcp-portal-ui"

Searched locations:
  - /Users/username/repos/dcp-portal-ui (sibling to dcp-specs)
  - /Users/username/repos/*/dcp-portal-ui (same parent, one level deeper)
  - Current directory: /Users/username/other-repo
  - specs/ parent: /Users/username/other-repo

Please ensure:
  - Repository "dcp-portal-ui" exists locally
  - It is in a standard location relative to dcp-specs
  - Or invoke from within the target repository itself
```

## Lifecycle

- **`analyze` skill** — first writer. Writes the file at the end of Step 1.5 after discovering target repository.
- **`design` skill** — reader. Loads the file to get REPO_ROOT for code exploration agents.
- **`execute` skill** — reader. Loads the file to get REPO_ROOT for file modifications and git operations.
- **`resolve-review` skill** — reader. Loads the file to get REPO_ROOT for PR updates.

## Update Mode

When the file already exists:
- Skills load it and use the stored path
- If path validation fails (repo moved/deleted), inform user and request manual update or re-run analyze

## Missing-File Handling

If `repositories.yml` is missing:
- **analyze skill**: Creates it after prompting user for target repo
- **design/execute/resolve-review skills**: Error and exit with message: "Run analyze skill first to discover target repository"

## Validation

A consumer should treat the file as invalid if:
- `version` is absent or unsupported
- `affected` is empty
- Any entry is missing `name`, `role`, or `path`
- Any `role` value is not `primary` or `supporting`
- Any `path` does not exist on filesystem or is not a git repository

On invalid input, the consumer should warn the user with specific validation failure and suggest:
- Manual correction of `repositories.yml`
- Re-running analyze skill to regenerate

## Example

**Standard format (works for everyone automatically):**
```yaml
version: "1.0"
affected:
  - name: dcp-portal-ui
    role: primary
    path: dcp-portal-ui
    description: "Frontend application requiring validation rule updates"
```

Skills will automatically find the repository in standard locations.

## Future Extensions (v0.3.0+)

- Multiple `affected` entries for multi-repo changes
- `supporting` role for repos that provide context but aren't modified
- Custom search paths via configuration file
