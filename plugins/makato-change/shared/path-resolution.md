# Path Resolution for repositories.yml

> Shared logic for resolving repository paths from `repositories.yml` across all makato-change skills.

## Purpose

When loading `repositories.yml`, the `path` field contains a repository name (e.g., `dcp-portal-ui`). This document defines the automatic resolution algorithm to locate the repository on the local filesystem.

## Resolution Algorithm

```bash
# Step 1: Read the repo name from repositories.yml
REPO_NAME="<from YAML affected[role=primary].path>"

# Step 2: Determine base search directory
SPECS_DIR="specs/<ISSUE_KEY>"
if [[ -f "$SPECS_DIR/repositories.yml" ]]; then
  SPECS_ROOT=$(cd "$(dirname "$SPECS_DIR")" && cd .. && pwd)
else
  # Fallback: use current directory
  SPECS_ROOT=$(pwd)
fi

# Step 3: Try multiple search strategies
RESOLVED_PATH=""

# Strategy 1: Sibling to dcp-specs
CANDIDATE="$SPECS_ROOT/../$REPO_NAME"
if [[ -d "$CANDIDATE/.git" ]]; then
  RESOLVED_PATH=$(cd "$CANDIDATE" && pwd)
fi

# Strategy 2: Same parent, one level deeper (repos/projects/dcp-portal-ui)
if [[ -z "$RESOLVED_PATH" ]]; then
  for dir in "$SPECS_ROOT"/../*/; do
    CANDIDATE="${dir}${REPO_NAME}"
    if [[ -d "$CANDIDATE/.git" ]]; then
      RESOLVED_PATH=$(cd "$CANDIDATE" && pwd)
      break
    fi
  done
fi

# Strategy 3: Current working directory
if [[ -z "$RESOLVED_PATH" ]]; then
  CWD_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$CWD_ROOT" ]] && [[ "$(basename "$CWD_ROOT")" == "$REPO_NAME" ]]; then
    RESOLVED_PATH="$CWD_ROOT"
  fi
fi

# Strategy 4: specs/ parent directory itself
if [[ -z "$RESOLVED_PATH" ]]; then
  if [[ "$(basename "$SPECS_ROOT")" == "$REPO_NAME" ]] && [[ -d "$SPECS_ROOT/.git" ]]; then
    RESOLVED_PATH="$SPECS_ROOT"
  fi
fi

# Step 4: Validate resolution
if [[ -z "$RESOLVED_PATH" ]]; then
  echo "Error: Cannot locate repository \"$REPO_NAME\""
  echo ""
  echo "Searched locations:"
  echo "  - $SPECS_ROOT/../$REPO_NAME (sibling to dcp-specs)"
  echo "  - $SPECS_ROOT/../*/$REPO_NAME (same parent, one level deeper)"
  echo "  - Current directory: $(pwd)"
  echo "  - specs/ parent: $SPECS_ROOT"
  echo ""
  echo "Please ensure:"
  echo "  - Repository \"$REPO_NAME\" exists locally"
  echo "  - It is in a standard location relative to dcp-specs"
  echo "  - Or invoke from within the target repository itself"
  exit 1
fi

# Step 5: Export for use
REPO_ROOT="$RESOLVED_PATH"
echo "Resolved repository path: $REPO_ROOT"
```

## Implementation in Skills

Each consumer skill (design, execute, resolve-review) should:

1. Load `repositories.yml`
2. Extract `REPO_NAME` from `affected[role=primary].path`
3. Apply resolution algorithm above
4. Validate the resolved path exists and is a git repo
5. Use `REPO_ROOT` for all subsequent operations

## Error Messages

### Repository not found
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

Common layouts that work automatically:
  repos/
  ├── dcp-specs/
  └── dcp-portal-ui/

  repos/
  ├── dcp-specs/
  └── projects/
      └── dcp-portal-ui/
```

## Testing Path Resolution

To test if a repository will resolve correctly:

```bash
REPO_NAME="dcp-portal-ui"
SPECS_ROOT="/Users/username/repos/dcp-specs"

# Try sibling
test -d "$SPECS_ROOT/../$REPO_NAME/.git" && echo "Found as sibling"

# Try one level deeper
for dir in "$SPECS_ROOT"/../*/; do
  test -d "${dir}${REPO_NAME}/.git" && echo "Found at ${dir}${REPO_NAME}"
done

# Try current directory
CWD_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[[ "$(basename "$CWD_ROOT")" == "$REPO_NAME" ]] && echo "Found in current directory"
```
