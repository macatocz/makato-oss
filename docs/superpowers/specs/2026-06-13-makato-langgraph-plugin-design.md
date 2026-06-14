# makato-langgraph Plugin — Design Spec

**Date:** 2026-06-13
**Status:** Approved

## Problem

The 5 LangGraph skills currently in `makato-build` fail its decision test: *"Does this skill help transform a decomposed, vertically-sliced story into tested, reviewed, merged code?"* They are Python/LangGraph API reference material — useful only on projects that use LangGraph, and technology-specific rather than workflow-generic. Leaving them in `makato-build` violates the suite's principle that each plugin has a single, coherent goal.

## Solution

Extract the 5 skills into a new dedicated plugin: `makato-langgraph`.

## Plugin Identity

| Field | Value |
|---|---|
| **Name** | `makato-langgraph` |
| **Goal** | Provide LangGraph-specific reference skills and patterns for building Python AI agents with the LangGraph framework. |
| **Decision test** | "Does this skill help a developer write correct LangGraph code?" |
| **Author** | `makato Team` |

**What belongs:**
- LangGraph API reference skills (StateGraph, nodes, edges, checkpointers, etc.)
- LangGraph agent patterns (ReAct, human-in-the-loop, reflexion, persistence)
- LangGraph-specific debugging or testing guidance

**What does NOT belong:**
- General Python skills (not LangGraph-specific)
- Technology-agnostic build workflow steps (those stay in `makato-build`)
- Non-LangGraph AI framework patterns (LlamaIndex, CrewAI, etc.)

## File Layout

```
plugins/makato-langgraph/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── langgraph-fundamentals/SKILL.md
│   ├── langgraph-agent-patterns/SKILL.md
│   ├── langgraph-human-in-the-loop/SKILL.md
│   ├── langgraph-persistence/SKILL.md
│   └── langgraph-reflexion/SKILL.md
├── AGENTS.md
├── CLAUDE.md
├── README.md
└── CHANGELOG.md
```

## Migration

1. Create `plugins/makato-langgraph/` with all governance files (`plugin.json`, `AGENTS.md`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`)
2. `git mv` each of the 5 `langgraph-*` skill directories from `makato-build/skills/` to `makato-langgraph/skills/`
3. All 5 skills already have valid frontmatter (`name`, `description`, `version`) — no edits needed
4. Run validation scripts locally before committing
5. Single commit: `feat(makato-langgraph): extract LangGraph skills into dedicated plugin`

## Impact

- `makato-build` becomes fully technology-agnostic — all remaining skills are workflow steps usable on any project
- Users who need LangGraph reference install `makato-langgraph` as an opt-in plugin
- No cross-plugin reference updates required — LangGraph skill descriptions are self-contained
