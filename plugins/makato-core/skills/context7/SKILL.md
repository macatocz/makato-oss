---
name: context7
description: Retrieve up-to-date documentation for software libraries, frameworks, and components via the Context7 API. Use when looking up documentation for any programming library or framework, finding code examples for specific APIs or features, verifying correct usage of library functions, or obtaining current information about library APIs that may have changed since training.
version: "1.0.0"
---

# Context7

## Overview

This skill retrieves current documentation for software libraries and components via the Context7
MCP server. Use it instead of relying on potentially outdated training data.

## When to Use

Use instead of relying on training data when:
- Looking up API syntax, function signatures, or configuration options for any library
- Finding code examples for a specific framework feature
- Verifying correct usage that may have changed since training cutoff
- Debugging library-specific errors where docs might clarify expected behavior

Do NOT use for: refactoring, writing scripts from scratch, debugging business logic, code review,
or general programming concepts that don't depend on a specific library version.

## Workflow

### Step 1: Resolve the Library ID

Call `mcp__plugin_context7_context7__resolve-library-id` with the library name and a query
describing what you need:

```
resolve-library-id(libraryName="react", query="useState hook usage")
```

Pick the result with the best name match, high source reputation, and high benchmark score.
If multiple good matches exist, proceed with the most relevant one.

### Step 2: Fetch Documentation

Call `mcp__plugin_context7_context7__query-docs` with the library ID from Step 1 and a specific
query:

```
query-docs(libraryId="/websites/react_dev_reference", query="useState")
```

Use a specific query — vague queries return less relevant documentation.

## Examples

**React hooks:** resolve `react` → query `/websites/react_dev_reference` for `useState`

**Next.js routing:** resolve `Next.js` → query `/vercel/next.js` for `app router`

**FastAPI dependencies:** resolve `FastAPI` → query `/fastapi/fastapi` for `dependency injection`

## Tips

- Always call `resolve-library-id` first — do not guess or hardcode library IDs
- Be specific with the query parameter to improve relevance
- If the first resolve result is not correct, check additional results in the returned list
- Do not call `query-docs` more than 3 times per question