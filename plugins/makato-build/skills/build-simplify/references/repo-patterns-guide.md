# Repo Patterns Guide

## Purpose

This guide describes how to discover and apply repository-specific code conventions
when evaluating simplification findings. The goal is to ensure that simplified code
aligns with what already exists in the codebase — not just with generic best practices.

## Where to Look

Check these sources in order. Stop when you have enough signal.

**1. `glossary.md` in the resolved spec folder** (if it exists)
Written by `/daff-shape:grill` and enriched by `/grill-with-docs` with `_Code_:` annotations where codebase naming differs from spec language. Use it to verify naming in simplified code matches both the domain language and the expected codebase symbols.

**2. Existing code in the same module/package as the changed files**
Read 2–3 representative files in the same directory as each changed file. Look for:
- How classes/functions are structured (method order, grouping of concerns)
- How errors are handled (exceptions vs. result types vs. error codes)
- How dependencies are injected (constructor, field, method parameter)
- How similar logic is named (what is a "Service" vs. a "Manager" vs. a "Handler")
- What level of abstraction is normal for a method of this type

**3. Existing tests for the same module**
Test files reveal expected behavior contracts and often show the intended usage patterns
of the production code. If the test uses the class directly, a wrapper is likely
unnecessary.

## What to Extract

Capture these specific signals. Each is actionable during simplification review:

| Signal | Where it shows | How to use it |
|---|---|---|
| Naming convention | Class/method names in the module | Flag divergent names in changed code |
| Abstraction level | Method sizes, helper usage | Flag extractions that are finer-grained than the norm |
| Error handling style | Catch blocks, return types | Flag changed code that uses a different style |
| Dependency pattern | Constructors, annotations, field declarations | Flag changed code that injects differently |
| DTO usage | Boundary classes, API endpoints | Flag internal DTOs where the module doesn't use them |

## How to Use Findings

Apply discovered patterns as an additional pass after the anti-pattern scan:

1. For each SIMPLIFY finding: verify the proposed simplification produces code that
   matches local patterns. If it would produce a *different* pattern than the
   surrounding module, reconsider the simplification or note the divergence.

2. For the changed code overall: scan for any constructs that do not appear in the
   surrounding module. These are pattern divergences even if they don't match an
   anti-pattern from the catalog. Add them as SIMPLIFY candidates with the rationale
   "diverges from local pattern: \<observed pattern\>."

3. Do not invent conventions. If the module has no clear pattern for something, do not
   impose one. Only flag genuine divergence from observable existing code.

## Limits

- Only read existing code in the *same module or package* as the changed files.
  Cross-module patterns are not necessarily applicable.
- If the codebase has no clear pattern for the construct in question, skip it.
  Absence of a pattern is not a reason to simplify.
- Never use this guide to impose the *best* pattern from another language or framework.
  The question is: "Does this match the codebase?" not "Is this idiomatic?"
