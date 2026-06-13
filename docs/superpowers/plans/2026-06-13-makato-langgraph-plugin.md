# makato-langgraph Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `makato-langgraph` plugin, move the 5 LangGraph reference skills into it, and remove them from `makato-build`.

**Architecture:** One new plugin directory with standard governance files (`plugin.json`, `AGENTS.md`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`); 5 skills moved via `git mv` to preserve history; validation scripts run before committing.

**Tech Stack:** Bash, git, makato plugin conventions

---

### Task 1: Create plugin scaffold

**Files:**
- Create: `plugins/makato-langgraph/.claude-plugin/plugin.json`
- Create: `plugins/makato-langgraph/AGENTS.md`
- Create: `plugins/makato-langgraph/CLAUDE.md`
- Create: `plugins/makato-langgraph/README.md`
- Create: `plugins/makato-langgraph/CHANGELOG.md`

- [ ] **Step 1: Create plugin.json**

```bash
mkdir -p plugins/makato-langgraph/.claude-plugin
```

Write `plugins/makato-langgraph/.claude-plugin/plugin.json`:
```json
{
  "name": "makato-langgraph",
  "description": "Provide LangGraph-specific reference skills and patterns for building Python AI agents with the LangGraph framework.",
  "author": {
    "name": "makato Team"
  }
}
```

- [ ] **Step 2: Create AGENTS.md**

Write `plugins/makato-langgraph/AGENTS.md`:
```markdown
# makato-langgraph — Contributor Guide

## Goal

Provide LangGraph-specific reference skills and patterns for building Python AI agents with the LangGraph framework.

**How:** Delivers self-contained reference skills covering the LangGraph API, agent patterns, and advanced features (persistence, human-in-the-loop, reflexion).

**Why:** LangGraph skills are technology-specific and only relevant on projects using the framework — keeping them separate from `makato-build` lets that plugin stay technology-agnostic.

## What Belongs Here

- LangGraph API reference skills (StateGraph, nodes, edges, reducers, checkpointers)
- LangGraph agent pattern guides (ReAct, human-in-the-loop, reflexion, persistence)
- LangGraph-specific debugging or testing guidance
- Python-only LangGraph utilities and code patterns

## What Does NOT Belong Here

- General Python skills not specific to LangGraph
- Technology-agnostic build workflow steps (those stay in `makato-build`)
- Non-LangGraph AI framework patterns (LlamaIndex, CrewAI, AutoGen, etc.)
- Project management, planning, or shaping skills

## Decision Test

"Does this skill help a developer write correct LangGraph code?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`

## File Structure

```
plugins/makato-langgraph/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── langgraph-fundamentals/
│   ├── langgraph-agent-patterns/
│   ├── langgraph-human-in-the-loop/
│   ├── langgraph-persistence/
│   └── langgraph-reflexion/
├── AGENTS.md
├── CLAUDE.md
├── README.md
└── CHANGELOG.md
```
```

- [ ] **Step 3: Create CLAUDE.md**

Write `plugins/makato-langgraph/CLAUDE.md` with exactly this content (it is a documentation pointer, not a symlink — the plugin system handles symlinking at install time):
```markdown
@AGENTS.md
```

- [ ] **Step 4: Create README.md**

Write `plugins/makato-langgraph/README.md`:
```markdown
# makato-langgraph

**Goal**: Provide LangGraph-specific reference skills and patterns for building Python AI agents with the LangGraph framework.

**How**: Delivers self-contained reference skills covering the LangGraph API, agent patterns, and advanced features.

**Why**: LangGraph skills are technology-specific — keeping them in a dedicated plugin lets `makato-build` stay technology-agnostic and lets users opt in only when working on LangGraph projects.

## What Belongs Here

- LangGraph API reference (StateGraph, nodes, edges, reducers, checkpointers)
- LangGraph agent patterns (ReAct, human-in-the-loop, reflexion, persistence)
- LangGraph-specific debugging or testing guidance

## What Does NOT Belong Here

- General Python skills not specific to LangGraph
- Technology-agnostic build workflow steps (`makato-build`)
- Non-LangGraph AI framework patterns

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `langgraph-fundamentals` | Core LangGraph concepts: StateGraph, state schemas, reducers, nodes, edges, streaming | `1.0.0` |
| `langgraph-agent-patterns` | LLM agent patterns: ReAct loop, multi-step planning, ToolNode, MCP integration | `1.0.0` |
| `langgraph-human-in-the-loop` | Human-in-the-loop: interrupt(), breakpoints, update_state, approval workflows | `1.0.0` |
| `langgraph-persistence` | Persistence: checkpointers, thread_id, time travel, Store, subgraph composition | `1.0.0` |
| `langgraph-reflexion` | Reflexion pattern: iterative self-improvement with human feedback and lesson persistence | `1.0.0` |

## Prerequisites

None — pure reference skills, no MCP servers required.
```

- [ ] **Step 5: Create CHANGELOG.md**

Write `plugins/makato-langgraph/CHANGELOG.md`:
```markdown
# Changelog — makato-langgraph

## [0.1.0] — 2026-06-13

### Added
- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- 5 LangGraph reference skills extracted from `makato-build`:
  - `langgraph-fundamentals`
  - `langgraph-agent-patterns`
  - `langgraph-human-in-the-loop`
  - `langgraph-persistence`
  - `langgraph-reflexion`
```

- [ ] **Step 6: Verify scaffold exists**

```bash
find plugins/makato-langgraph -type f | sort
```
Expected output:
```
plugins/makato-langgraph/.claude-plugin/plugin.json
plugins/makato-langgraph/AGENTS.md
plugins/makato-langgraph/CHANGELOG.md
plugins/makato-langgraph/CLAUDE.md
plugins/makato-langgraph/README.md
```

---

### Task 2: Move LangGraph skills from makato-build

**Files:**
- Move: `plugins/makato-build/skills/langgraph-fundamentals/` → `plugins/makato-langgraph/skills/langgraph-fundamentals/`
- Move: `plugins/makato-build/skills/langgraph-agent-patterns/` → `plugins/makato-langgraph/skills/langgraph-agent-patterns/`
- Move: `plugins/makato-build/skills/langgraph-human-in-the-loop/` → `plugins/makato-langgraph/skills/langgraph-human-in-the-loop/`
- Move: `plugins/makato-build/skills/langgraph-persistence/` → `plugins/makato-langgraph/skills/langgraph-persistence/`
- Move: `plugins/makato-build/skills/langgraph-reflexion/` → `plugins/makato-langgraph/skills/langgraph-reflexion/`

- [ ] **Step 1: Create skills destination directory**

```bash
mkdir -p plugins/makato-langgraph/skills
```

- [ ] **Step 2: Move all 5 skills with git mv**

```bash
git mv plugins/makato-build/skills/langgraph-fundamentals \
       plugins/makato-langgraph/skills/langgraph-fundamentals

git mv plugins/makato-build/skills/langgraph-agent-patterns \
       plugins/makato-langgraph/skills/langgraph-agent-patterns

git mv plugins/makato-build/skills/langgraph-human-in-the-loop \
       plugins/makato-langgraph/skills/langgraph-human-in-the-loop

git mv plugins/makato-build/skills/langgraph-persistence \
       plugins/makato-langgraph/skills/langgraph-persistence

git mv plugins/makato-build/skills/langgraph-reflexion \
       plugins/makato-langgraph/skills/langgraph-reflexion
```

- [ ] **Step 3: Verify moves**

```bash
ls plugins/makato-langgraph/skills/
```
Expected:
```
langgraph-agent-patterns
langgraph-fundamentals
langgraph-human-in-the-loop
langgraph-persistence
langgraph-reflexion
```

```bash
ls plugins/makato-build/skills/ | grep langgraph
```
Expected: no output (all langgraph skills are gone from makato-build).

---

### Task 3: Run validation and commit

- [ ] **Step 1: Run plugin structure check**

```bash
bash scripts/check-plugin-structure.sh plugins/makato-langgraph/
bash scripts/check-plugin-structure.sh plugins/makato-build/
```
Expected: `Plugin structure [makato-langgraph]: OK` and `Plugin structure [makato-build]: OK`

- [ ] **Step 2: Run skill frontmatter check for all moved skills**

```bash
for s in plugins/makato-langgraph/skills/*/; do
  bash scripts/check-skill-frontmatter.sh "$s"
done
```
Expected: `Skill frontmatter [makato-langgraph/<skill>]: OK` for all 5 skills.

- [ ] **Step 3: Run naming conventions check**

```bash
bash scripts/check-naming.sh
```
Expected: `Naming conventions: OK`

- [ ] **Step 4: Run self-containment check**

```bash
for s in plugins/makato-langgraph/skills/*/; do
  bash scripts/check-self-contained.sh "$s"
done
```
Expected: `Self-containment [makato-langgraph/<skill>]: OK` for all 5 skills.

- [ ] **Step 5: Stage and commit**

```bash
git add plugins/makato-langgraph/ plugins/makato-build/
git status --short
```
Confirm: 5 renames shown as `R  plugins/makato-build/skills/langgraph-*/SKILL.md -> plugins/makato-langgraph/skills/langgraph-*/SKILL.md`, plus new governance files as `A`.

```bash
git commit -m "feat(makato-langgraph): extract LangGraph skills into dedicated plugin

Moves 5 LangGraph reference skills out of makato-build (where they
failed the decision test) into a new opt-in plugin. makato-build
is now fully technology-agnostic."
```

- [ ] **Step 6: Verify final state**

```bash
git log --oneline -3
git show --stat HEAD | head -20
```
Expected: commit shows 5 renames + 5 new governance files.
