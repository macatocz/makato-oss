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
