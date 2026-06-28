# Code Discovery Strategies

Patterns for finding affected code in the codebase. Two approaches: guided (user provides paths) vs. exploratory (agent discovers).

## When to Use Each Approach

### Guided Discovery (Option A)

**Use when:**
- User is familiar with the codebase structure
- User knows exactly which files/modules need changes
- Change is localized to a known area
- Speed is prioritized (no exploration overhead)

**Advantages:**
- Fast and direct
- No exploration cost
- User maintains control

**Disadvantages:**
- Relies on user's complete knowledge
- May miss non-obvious dependencies
- Risk of incomplete discovery if user forgets related areas

### Exploratory Discovery (Option B)

**Use when:**
- User is new to this part of the codebase
- Change affects multiple areas and dependencies are unclear
- Feature is spread across many files
- Want comprehensive discovery with dependency mapping

**Advantages:**
- Thorough discovery
- Identifies dependencies automatically
- Finds related test files
- Maps call chains

**Disadvantages:**
- Takes longer (agent execution time)
- May find too much (noise)
- Requires good search terms

## Guided Discovery Process

### Step 1: Ask for File Paths

Prompt the user:
> "Which files need to be modified for this change? Please provide file paths."

Accept formats:
- Absolute paths: `/Users/name/project/src/file.ts`
- Relative from repo root: `src/components/UserProfile.tsx`
- Glob patterns: `src/api/users.*` (all user-related API files)

### Step 2: Ask for Module/Component Names

If the user provides high-level names instead of paths:
> "Got it — changes affect the User Profile component. Let me find the relevant files."

Use grep/find to locate files matching that component/module name.

### Step 3: Ask for Test Files

> "Are there existing test files for these components? If so, what are they?"

If user doesn't know:
> "I'll search for test files matching the component names."

Use patterns:
- `tests/` directory with matching names
- `*.test.ts`, `*.spec.ts` files
- Test files in same directory as source (common in React/JS)

### Step 4: Confirm Understanding

List back what you've gathered:
> "I'll design changes for:
> - `src/components/UserProfile.tsx` — User profile UI component
> - `src/api/userService.ts` — User API service layer
> - `tests/UserProfile.test.tsx` — Component tests
>
> Is that complete, or are there other files involved?"

Wait for user confirmation before proceeding to design.

## Exploratory Discovery Process

### Step 1: Extract Search Terms

From the analysis artifact, extract:
- **Feature names**: exact names from GitHub Issues summary (e.g., "account deletion", "email notifications")
- **Technical terms**: API endpoints, function names, database tables mentioned
- **UI terms**: screen names, button labels, component names

### Step 2: Spawn Explore Agent

Use Agent tool with `subagent_type: Explore`:

**Prompt structure:**
```
Find the code affected by this change request.

**Requirements:** [1-2 sentence summary from analysis]

**Current behavior:** [what the feature does now]

**Requested changes:** [what should change]

**Search terms:**
- [feature-name]
- [technical-term-1]
- [technical-term-2]

**What to find:**
1. Files implementing current behavior
2. Related test files
3. Dependencies (imports, call chains)
4. UI components (if applicable)
5. API endpoints (if applicable)

**Format your response as:**
- **File path** — Role/purpose, key functions/classes
```

### Step 3: Process Agent Results

The agent returns a list of files. Extract:
- **Primary files:** directly implement the feature
- **Secondary files:** dependencies or consumers
- **Test files:** cover the feature

Categorize by role:
- UI components
- Business logic / services
- API handlers
- Data models
- Tests

### Step 4: Validate with User

Present the discovered files to the user:
> "I discovered these affected files:
>
> **Primary:**
> - `src/components/AccountSettings.tsx` — settings UI
> - `src/services/accountService.ts` — account operations
>
> **Tests:**
> - `tests/accountService.test.ts`
>
> **Dependencies:**
> - `src/api/client.ts` — used by accountService
>
> Does this look complete? Any files I missed?"

Allow the user to add or remove files before proceeding.

## Hybrid Approach

Sometimes a combination works best:
1. User provides the main files (guided)
2. Agent discovers dependencies and tests (exploratory)

Example:
> "I know the main change is in `UserProfile.tsx`, but I'm not sure what else it affects. Can you find the dependencies?"

In this case:
- Accept the user-provided file as primary
- Spawn an agent to find: files that import `UserProfile.tsx`, tests that reference it, related API endpoints

## Dependency Mapping

Once files are identified (guided or exploratory), map dependencies:

### Forward Dependencies (What This Code Uses)
- Imports at the top of the file
- Services called
- Components rendered

### Reverse Dependencies (What Uses This Code)
- Search for files that import this one
- Find test files that reference it
- Identify consumers of this API/service

### Example Dependency Map

```
UserProfile.tsx (primary file)
├── imports: userService.ts, Avatar.tsx, Button.tsx
├── used by: Dashboard.tsx, Settings.tsx
└── tested by: UserProfile.test.tsx
```

This map helps understand the blast radius of changes.

## When Discovery Reveals Larger Scope

If discovery finds many more files than expected:
- Re-evaluate scope estimate
- Check if change is actually large (should use makato-plan)
- Confirm with user that all discovered files are truly affected

Don't proceed to design if scope is unexpectedly large. Escalate to makato-plan instead.
