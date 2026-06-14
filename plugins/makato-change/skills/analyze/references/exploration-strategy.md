# Exploration Strategy

Systematic patterns for discovering how a feature currently works in the codebase.

## Start with specs-context Context (if available)

**Primary starting point when working in specs-context repository:**

1. **Check if in specs-context:**
   ```bash
   pwd  # Check if path contains "specs-context"
   ```

2. **If in specs-context, locate service context:**
   - Identify target repository name from GitHub Issues issue
   - Check `context/<repo-name>/` directory
   - Example: `context/dcp-platform/`, `context/dcp-api/`

3. **Read context files to understand:**
   - Service architecture and responsibilities
   - Key components and their interactions
   - Existing patterns and conventions
   - Related documentation and references
   - Technology stack and frameworks used

4. **Use as foundation:**
   - Start with high-level understanding from context
   - Then drill into specific code areas for details
   - Reduces blind exploration and improves accuracy

**If NOT in specs-context:**
- Proceed with code-based exploration below
- Consider suggesting: "specs-context contains service specifications at context/<repo-name>/"

## Start with the GitHub Issues Issue

Extract key terms from:
- Issue summary and description
- Feature names, component names, screen names
- Technical terms (API endpoints, database tables, UI elements)
- User-facing labels (button text, field names, error messages)

## File Discovery Patterns

### 1. Grep for Feature Names

Search for exact feature references:
```bash
grep -r "feature-name" --include="*.ts" --include="*.tsx" --include="*.py"
```

Look in:
- Source code files
- Test files
- Configuration files
- Documentation

### 2. Search for UI Elements

If change affects UI, search for:
- Component names (e.g., `UserProfileForm`, `SettingsPanel`)
- Button labels or text content
- Route paths (e.g., `/settings/profile`)
- CSS class names

### 3. Search for API/Function Names

If change affects backend logic:
- Function/method names
- API endpoint paths
- Database table names
- Service class names

### 4. Follow Imports and References

Once you find a key file:
1. Read the file to understand its role
2. Check imports to find dependencies
3. Search for files that import this one (reverse dependencies)
4. Map the call chain

## Test Discovery

Tests reveal expected behavior and edge cases:

### Find Test Files

```bash
find . -name "*test*" -o -name "*spec*" | grep -i "feature-name"
```

Or search test content:
```bash
grep -r "describe.*feature-name" --include="*.test.*" --include="*.spec.*"
```

### Find E2E Test Files

E2E tests validate end-to-end user workflows. **Use a systematic discovery approach:**

#### Step 1: Check Project Documentation (Primary Source)

1. **Read README.md** (check local package README for monorepos, then workspace root):
   - Look for sections: "Testing", "E2E Tests", "End-to-End Tests", "Integration Tests"
   - Note documented e2e test locations and commands
   - If documented, use the exact paths/commands from README

2. **Check package.json** (Node.js projects):
   - Look for e2e-related scripts: `"test:e2e"`, `"e2e"`, `"cypress:open"`, `"playwright"`, `"e2e:run"`
   - Scripts often reveal test directories and frameworks in use
   - Example: `"test:e2e": "cypress run"` → Cypress framework

3. **Check for e2e config files**:
   - `cypress.config.js`, `cypress.config.ts` → Cypress (check `specPattern` config)
   - `playwright.config.ts`, `playwright.config.js` → Playwright (check `testDir` config)
   - `protractor.conf.js` → Protractor (legacy Angular, check `specs` config)
   - `cucumber.js`, `cucumber.json` → Cucumber (check `features` paths)
   - `wdio.conf.js` → WebdriverIO

#### Step 2: Search File System (Fallback)

**If documentation doesn't specify e2e locations, search for:**

**Common directory patterns:**
- `e2e/`, `tests/e2e/`, `test/e2e/`
- `cypress/e2e/`, `cypress/integration/`
- `playwright/`, `__e2e__/`
- `apps/*/e2e/` (monorepo pattern)
- `e2e/src/` (Angular CLI pattern)
- `features/` (Cucumber/Gherkin)

**Common file naming patterns:**
- `*.e2e.spec.ts`, `*.e2e.spec.js`
- `*.e2e.test.ts`, `*.e2e.test.js`
- `*.e2e-spec.ts` (Angular CLI convention)
- `*.spec.ts` (when inside e2e directories)
- `*.feature` (Cucumber/Gherkin scenarios)

**Search commands:**

```bash
# Find e2e directories
find . -type d -name "*e2e*" -o -name "cypress" -o -name "playwright" -o -name "features" 2>/dev/null

# Find e2e test files by pattern
find . -name "*.e2e.spec.*" -o -name "*.e2e.test.*" -o -name "*.e2e-spec.*" -o -name "*.feature"

# Search for test content in e2e directories
grep -r "describe\|it\|test\|Scenario\|Feature" --include="*.spec.ts" --include="*.spec.js" --include="*.feature" e2e/ 2>/dev/null
```

**Framework-specific locations:**
- **Cypress**: `cypress/e2e/`, `cypress/integration/`
- **Playwright**: `e2e/`, `tests/`, `playwright/`, root `*.spec.ts` files
- **Protractor (legacy Angular)**: `e2e/src/`, `e2e/app.e2e-spec.ts`
- **Cucumber**: `features/`, `test/features/`, `e2e/features/` (`.feature` files)
- **TestCafe**: `tests/`, `testcafe/`

#### Step 3: User Verification (If Nothing Found)

If both documentation and filesystem search find nothing, **use `AskUserQuestion`** to verify (see SKILL.md Step 3 for the question format).

### What Tests Tell You

- **Assertions** → expected outcomes
- **Setup/fixtures** → required state and data
- **Edge cases** → boundary conditions tested
- **Error cases** → expected failures and error messages
- **Missing tests** → implicit behavior not verified
- **E2E scenarios (Gherkin)** → business-readable user workflows and acceptance criteria

## Documentation Review

Check for design intent:
- `README.md` in relevant directories
- Inline comments explaining "why" (especially `// HACK`, `// NOTE`, `// TODO`)
- API documentation (OpenAPI, JSDoc, docstrings)
- ADRs (Architecture Decision Records) if present

## Data Flow Mapping

Trace how data moves through the system:
1. **Entry point** — Where does the request start? (API handler, UI event handler)
2. **Validation** — What rules are checked?
3. **Business logic** — What transformations happen?
4. **Persistence** — What is saved/updated?
5. **Response** — What is returned to the caller?

## Working Notes Structure

As you explore, maintain notes in this structure:

### Current Behavior
- What happens now (user perspective)
- How it works (code perspective)

### Key Files
- File path + role (e.g., `src/api/users.ts` — user API handlers)

### Constraints
- Validation rules
- Permissions/authorization
- Dependencies on other features

### Edge Cases
- Boundary conditions handled
- Error scenarios covered

### Implicit Behavior
- Things that work but aren't explicitly tested
- Undocumented assumptions

## When to Stop

You have enough understanding when you can answer:
1. What does the feature do now?
2. Where is that behavior implemented?
3. What constraints exist?
4. What edge cases are handled?
5. What would break if we change this?

Stop before reading every file exhaustively. Focus on breadth (mapping the feature) before depth (understanding every implementation detail).
