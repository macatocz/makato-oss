# makato-langgraph

**Goal**: Equip developers with the LangGraph-specific reference skills and code patterns needed
to build correct, production-ready Python AI agents with the LangGraph framework.

**How**: Delivers five self-contained reference skills that cover the LangGraph API surface in
layers — from core graph construction through agent topologies, persistence, human-in-the-loop
controls, and iterative reflexion — each with ready-to-use code patterns.

**Why**: LangGraph is a specific framework with its own API contracts and mental model. Bundling
these skills inside `makato-build` would pollute a technology-agnostic workflow with
framework-specific knowledge. Keeping them in a dedicated plugin lets teams opt in only on
projects that use LangGraph and keeps both plugins easier to maintain independently.

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

## Workflow

All five skills are reference-only. Read them in dependency order — each layer assumes the
previous one is understood.

```
┌─────────────────────────────────────────────────────────────────────┐
│  langgraph-fundamentals                                             │
│  In: intent to build a LangGraph graph; Python project context      │
│  Out: StateGraph, state schema, node/edge, streaming patterns       │
└──────────────┬──────────────────────────────────────────────────────┘
               │
       ┌───────┴──────────────────────┐
       │                              │
       ▼                              ▼
┌─────────────────────┐   ┌────────────────────────┐
│ langgraph-agent-    │   │ langgraph-persistence   │
│ patterns            │   │ In: graph needing       │
│ In: project needing │   │     durable state       │
│     an LLM agent    │   │ Out: checkpointer,      │
│ Out: ReAct/planning │   │ thread, Store patterns  │
│ agent topology code │   └──────────┬─────────────┘
└─────────────────────┘              │
                                     │
                            ┌────────┴────────────────────────┐
                            │                                 │
                            ▼                                 ▼
             ┌──────────────────────────┐   ┌───────────────────────────┐
             │ langgraph-human-in-the-  │   │ langgraph-reflexion        │
             │ loop                     │   │ In: project needing        │
             │ In: graph needing        │   │     iterative improvement  │
             │     pause-for-approval   │   │     + human feedback       │
             │ Out: interrupt(),        │   │ Out: reflexion loop,       │
             │ breakpoint, update_state │   │ lesson reducer, Postgres   │
             └──────────────────────────┘   └───────────────────────────┘
```

- **langgraph-fundamentals** — always the starting point; every other skill assumes this one.
- **langgraph-agent-patterns** — read after fundamentals when building an agent with tools.
- **langgraph-persistence** — read when the graph needs durable state across sessions.
- **langgraph-human-in-the-loop** — read after persistence (requires a checkpointer).
- **langgraph-reflexion** — read after persistence; co-invoke both for lesson-backed loops.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`langgraph-fundamentals`](skills/langgraph-fundamentals/SKILL.md) | Core LangGraph: StateGraph, state schemas (TypedDict/dataclass/Pydantic), reducers, nodes, edges, Command, Send, parallel execution, map-reduce, message trimming, invoke, streaming, and error handling. Invoke before writing any LangGraph code. | Developer intent to build a LangGraph graph; existing Python project context | Code patterns and reference examples for StateGraph construction, state management, and streaming | 1.0.1 |
| [`langgraph-agent-patterns`](skills/langgraph-agent-patterns/SKILL.md) | LLM agent patterns in LangGraph: ReAct loop (manual and prebuilt), multi-step planning, conditional branching, MessagesState, ToolNode, tools_condition, and MCP integration. Python-only. | LangGraph project requiring an LLM agent with tools; goal or task description | Agent topology code (minimal single-node, multi-step planning, conditional branching, ReAct, MCP integration) | 1.0.1 |
| [`langgraph-human-in-the-loop`](skills/langgraph-human-in-the-loop/SKILL.md) | Human-in-the-loop patterns: interrupt(), Command(resume=...), interrupt_before breakpoints, update_state, approval/validation workflows, and idempotency. Python-only. | LangGraph graph requiring pause-for-approval or user input; checkpointer already configured | Code patterns for interrupt(), Command(resume=...), breakpoints, and update_state with idempotency guidance | 1.0.1 |
| [`langgraph-persistence`](skills/langgraph-persistence/SKILL.md) | Persistence in LangGraph: checkpointers (InMemorySaver, PostgresSaver), thread_id, time travel, Store for cross-thread memory, subgraph composition, and subgraph persistence modes. Python-only. | LangGraph graph requiring durable state across sessions or across subgraphs | Code patterns for checkpointer setup, thread management, time travel, Store usage, and subgraph composition | 1.0.1 |
| [`langgraph-reflexion`](skills/langgraph-reflexion/SKILL.md) | Reflexion pattern: iterative self-improvement loop (act-tools-feedback-reflect-finalize) with human feedback, custom unique-lesson reducers, and Postgres-backed lesson persistence. Python-only. | LangGraph project requiring iterative quality improvement with human feedback; checkpointer configured (co-invoke langgraph-persistence) | Complete reflexion loop implementation including state schema with lesson reducers, node definitions, and Postgres lesson persistence | 1.1.0 |

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-langgraph/AGENTS.md` | Contributor routing guide: goal, how, why, what belongs, what does not belong, skill authoring rules, file structure, versioning, and PR checklist |
| `plugins/makato-langgraph/README.md` | User-facing documentation: skill dependency order, skills table with descriptions and versions, plugin connections, and installation instructions |
| `plugins/makato-langgraph/CHANGELOG.md` | Per-PR changelog tracking skill version bumps and feature additions |
| `plugins/makato-langgraph/CLAUDE.md` | Delegates to AGENTS.md via @AGENTS.md include for in-session routing |
| `plugins/makato-langgraph/.claude-plugin/plugin.json` | Plugin manifest declaring name, description, and author; no version field (versioned via release-please git tags) |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Complements | `makato-build` | LangGraph skills are used alongside build-refine and build-implement-tdd when the story involves building LangGraph agents |
| Complements | `makato-observability` | LangGraph graphs authored with these skills are instrumented using the langfuse-instrument skill from makato-observability |

## Prerequisites / MCP Servers

None — pure reference skills, no MCP servers required.

## Installation

```bash
claude --plugin-dir ./plugins/makato-langgraph
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
