---
name: context7
description: >-
  Retrieve live, version-specific documentation for software libraries,
  frameworks, and components via the Context7 MCP server. Use when writing
  code that touches any library, framework, SDK, or API; verifying API syntax,
  function signatures, or configuration options; checking current import paths
  or constructor signatures; or debugging library-specific errors. Triggers:
  "library docs", "API reference", "how do I use X", "latest version",
  "check docs for", "current syntax", "framework docs", "SDK reference".
version: "1.2.0"
metadata:
  Authors: makato-doc contributors
  last_updated: "2026-08-05"
argument-hint: "<library-name> <topic>"
mcp_server: plugin:context7:context7
allowed-tools:
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
---

# Context7

## Overview

Context7 retrieves real-time, version-specific library documentation via the
Context7 MCP server. **Training data is frozen at cutoff; library APIs change
across releases.** Even well-known APIs (React hooks, Next.js App Router,
Tailwind config schema, TanStack signatures) differ across major versions.

**Suite-wide obligation**: Per AGENTS.md (§ Documentation skills), every
code-creating agent must use this skill before writing code that touches a
library — not after finding an error.

## Mindset: When Live Docs Override Training Knowledge

Use live docs (this skill) when:
- Library has multiple major versions in training data — which version applies is ambiguous
- Query involves constructor signatures, import paths, or config file schema
- Library is rapidly-iterated (Next.js, TanStack, shadcn/ui ship breaking changes on short cycles)
- You cannot trace a pattern you recall to a specific version

Training knowledge is sufficient when:
- Question is a pure programming concept (closures, recursion) with no library dependency
- Library is stable standard with no meaningful version variance (Python `os.path`, Node `fs`)

## Workflow

### Step 1 — Check library-registry.md (MANDATORY for listed libraries)

**MANDATORY TRIGGER**: When the target library matches any entry in
`library-registry.md` — Drizzle ORM, Prisma, Better Auth, NextAuth.js, Clerk,
Next.js, React, TanStack Query/Router/Start, Cloudflare Workers, AWS Lambda,
Vercel, Shadcn/ui, Radix UI, Tailwind CSS, Zustand, Jotai, Zod, React Hook
Form, Vitest, or Playwright — **load `library-registry.md` before calling
`query-docs`** and substitute the pre-optimized query string for the matching
user intent. Do NOT construct a freeform query for these libraries; the
pre-optimized strings encode which term combinations surface version-specific,
actionable snippets vs generic overview prose.

**Do NOT load `library-registry.md`** when the target library is not in the
list above; the file covers only its documented libraries and provides no
benefit for others.

**Do NOT load `navigation.md` or `README.md`** — those are human orientation
aids, not agent decision aids. `navigation.md` duplicates the structure summary
already in SKILL.md; loading it wastes context budget with no additional signal.

### Step 2 — Resolve the Library ID

Call `resolve-library-id` with the library name and a brief topic:

```
resolve-library-id(libraryName="react", query="useState hook")
```

**Selection decision tree** (apply in order — stop at first decisive criterion):

1. **Name match** — exact or canonical alias wins, regardless of reputation
2. **Source reputation** — High > Medium > Low > Unknown when names tie
3. **Benchmark score** — higher = better curated index when reputation ties
4. **Code snippet count** — higher = more actionable when all else ties

If no result matches the library name after one retry with an alternate alias
(e.g., `"@tanstack/react-query"` instead of `"tanstack query"`), proceed with
training data and state version uncertainty to the user.

### Step 3 — Fetch Documentation

Call `query-docs` with the resolved library ID and a query built from
`+`-joined specific terms:

```
query-docs(libraryId="/vercel/next.js", query="App+Router+file+conventions+layouts+pages")
```

**Query construction rule**: The Context7 index is term-frequency ranked, not
semantic. `+`-joined nouns outperform natural-language sentences because stop
words ("how", "do", "I", "with") dilute term weight without adding signal.

**Good**: `"Drizzle+adapter+PostgreSQL+schema+generation+configuration"`
**Poor**: `"how do I set up Drizzle adapter with PostgreSQL"`

## Result Quality Evaluation

Assess quality before using the returned content:

| Signal | Good — use directly | Poor — retry or fall back |
|--------|---------------------|--------------------------|
| Version tag in snippets | Matches target version | Mixed versions or version absent |
| Code compiles standalone | Yes with stated imports | Missing imports or deprecated API called |
| Snippet density | Multiple code examples | Long prose, few or no examples |
| Topic match | Directly answers query | Adjacent or overview-level topic |

**On poor result**: Narrow the query (add version string or specific method
name) and retry `query-docs` once. If still poor after one retry, fall back
to training data and explicitly caveat the version uncertainty to the user.

## Recovery Paths

**resolve-library-id returns no good name match**
→ Retry with an alternate alias from `library-registry.md` if the library is listed
→ If still no match: use training data, state uncertainty ("based on training data for vX.Y")

**query-docs returns off-topic or empty results**
1. Verify library ID begins with `/` — a truncated ID returns empty silently
2. Simplify: drop terms to the 2 most specific, drop version qualifiers
3. One retry with simplified query; if still off-topic, fall back to training data with caveat

**Resolved ID looks unfamiliar**
→ Trust the tool — IDs are canonical slugs from the Context7 indexing pipeline
→ Do not substitute a guessed path; the tool output is authoritative

## Anti-Patterns

**NEVER hardcode or guess a library ID**
WHY: Library IDs are version-scoped slugs assigned by Context7's indexing pipeline
(`/vercel/next.js` vs `/vercel/next.js/v13`). A hardcoded ID silently 404s or
returns docs for the wrong version, producing code that compiles but fails at runtime
with the actual installed version. Always call `resolve-library-id` to get the current
canonical ID for the deployed version of the library.

**NEVER call `query-docs` more than 3 times per question**
WHY: Each call draws from the same indexed corpus. After 3 calls you exhaust the
high-ranking documents; result sets begin to overlap and the 4th call's marginal
document is typically lower-quality than training data for the same topic. Spend the
budget on improving the query string, not increasing call count.

**NEVER write a natural-language sentence as the `query-docs` query**
WHY: The Context7 index is term-frequency ranked. A sentence like "how do I set up
authentication with the Drizzle adapter" dilutes signal with stop-words. The same
information encoded as `"Drizzle+adapter+PostgreSQL+schema+generation+configuration"`
surfaces version-specific setup snippets instead of introduction prose.

**NEVER skip Step 1 (library-registry.md) for listed libraries**
WHY: The query patterns in `library-registry.md` encode lessons from real retrieval
failures — the exact term combinations that surface actionable snippets rather than
generic overviews. Bypassing them means rediscovering those failures within the 3-call
budget, often leaving the user with low-quality docs or a wasted call allowance.

**NEVER use this skill for non-library topics**
WHY: The Context7 index is a library-documentation corpus. Queries about business
logic, architecture patterns, or code review return random documentation fragments
that happen to contain matching terms — they carry no authority on those topics and
will actively mislead. Use this skill only for library/framework/SDK/API lookups.

## Examples

**React useState:** resolve `react` → query `/websites/react_dev_reference`
for `useState+hook+functional+component+TypeScript`

**Next.js App Router:** resolve `Next.js` → load library-registry.md App Router
pattern → query `/vercel/next.js` for `App+Router+file+conventions+layouts+pages+routing`

**Drizzle ORM migrations:** resolve `drizzle-orm` → load library-registry.md
Drizzle migrations pattern → query `/drizzle-team/drizzle-orm` for
`drizzle-kit+migrations+generate+push+PostgreSQL`

**TanStack Query prefetch:** resolve `@tanstack/react-query` → load
library-registry.md TanStack Query prefetching pattern → query for
`prefetchQuery+Server+Components+hydration+Next.js`

## Reference File

**`library-registry.md`** — pre-optimized `+`-joined query strings and aliases for 22
listed libraries, organized by category (Database, Auth, Frontend, Infrastructure, UI,
State, Validation, Testing). MANDATORY when target library is listed (Step 1).
Covers: Drizzle, Prisma, Better Auth, NextAuth.js, Clerk, Next.js, React,
TanStack Query/Router/Start, Cloudflare Workers, AWS Lambda, Vercel, Shadcn/ui,
Radix UI, Tailwind CSS, Zustand, Jotai, Zod, React Hook Form, Vitest, Playwright.
