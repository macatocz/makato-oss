# ADR-0001: Goal-Driven Toolkit Design

## Status

Accepted

## Date

2026-05-11

## Context

Plugin suites tend to accumulate skills that don't clearly belong anywhere, leading to sprawl and confusion about what each plugin is for. Category-based organization (e.g., "git tools", "documentation tools") creates ambiguous boundaries because many skills span categories.

## Decision

Every plugin has a single Goal Statement — one sentence describing what it transforms or provides. The goal is the primary gatekeeper: everything in the plugin must demonstrably serve it.

- Goal statements take the form: "Transform X into Y" or "Provide X for Y"
- PR descriptions must include goal alignment justification for new skills
- Reviewers ask: "Does this serve the stated goal?"
- The goal is the boundary — not a skill count, not a category

## Consequences

- Clear admission criteria for every plugin
- Contributors know where new skills belong (match the goal)
- Scope creep is detectable: if you can't articulate how a skill serves the goal, it doesn't belong
- Goals can evolve via ADR (not silently)
- Requires discipline in writing precise goal statements
