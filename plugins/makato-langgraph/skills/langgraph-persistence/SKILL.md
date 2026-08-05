---
name: langgraph-persistence
description: >-
  INVOKE THIS SKILL when your LangGraph needs to persist state, remember
  conversations, travel through history, use the in-memory or Postgres
  checkpointer, or compose subgraphs with persistence. Covers checkpointers,
  thread_id, time travel, Store, subgraph composition, subgraph persistence
  modes (False/None/True), namespace isolation, Overwrite reducer bypass, and
  async saver variants. Python-only.
version: "1.0.2"
metadata:
  last_updated: "2026-08-05"
---

## Persistence Design — Entry Decision Tree

Start here before writing any code. The answers determine which checkpointer mode, subgraph scoping, and memory type to use.

```
Do you need to pause graph execution for human input (interrupts)?
├── No  → Does the subgraph need memory across invocations (multi-turn)?
│         ├── No  → compile subgraph with checkpointer=False  (cheapest)
│         └── Yes → compile subgraph with checkpointer=True  (+namespace warning below)
└── Yes → Does the subgraph need memory across invocations?
          ├── No  → compile subgraph with checkpointer omitted / None  (interrupts only)
          └── Yes → compile subgraph with checkpointer=True  (+namespace warning below)

Do you need memory shared across different threads (user preferences, facts)?
└── Yes → add a Store alongside the checkpointer (orthogonal — both can coexist)

Deploying to production?
└── Yes → load references/production.md  (PostgresSaver, AsyncPostgresSaver, connection pooling)

User is new to LangGraph persistence (first checkpointer setup)?
└── Yes → load references/basics.md  (InMemorySaver setup, thread isolation demo)
```

---

## Two Memory Types

- **Short-term (checkpointer)**: Thread-scoped conversation history — each `thread_id` is an isolated checkpoint sequence.
- **Long-term (Store)**: Cross-thread memory — user preferences and facts that survive thread changes. Orthogonal to checkpointer; compile graph with both.

---

## PostgreSQL Checkpointer (Production)

```python
from langgraph.checkpoint.postgres import PostgresSaver

with PostgresSaver.from_conn_string(
    "postgresql://user:pass@localhost/db"
) as checkpointer:
    checkpointer.setup()  # idempotent — safe on every startup
    graph = builder.compile(checkpointer=checkpointer)
```

MANDATORY: Load `references/production.md` when the user asks about async graphs, connection pooling, AsyncPostgresSaver, AsyncInMemoryStore, schema migration, or multi-tenant thread isolation.

---

## State History & Time Travel

```python
config = {"configurable": {"thread_id": "session-1"}}
result = graph.invoke({"messages": ["start"]}, config)

# Browse checkpoint history
states = list(graph.get_state_history(config))

# Replay from a past checkpoint
past = states[-2]
result = graph.invoke(None, past.config)  # None = resume from checkpoint

# Fork: update state at a past checkpoint, then resume
fork_config = graph.update_state(past.config, {"messages": ["edited"]})
result = graph.invoke(None, fork_config)
```

Key distinction: `graph.invoke(None, config)` resumes from checkpoint. `graph.invoke({...}, config)` starts a **new run** on the same thread, appending to history.

---

## Subgraph Composition

Subgraphs are compiled graphs added as nodes to a parent graph. They enable hierarchical organization, parallel processing, and modular design. Parent and subgraph communicate through **overlapping state keys** — keys present in both schemas are automatically passed down and merged back up.

```python
from typing import Annotated
from typing_extensions import TypedDict
from operator import add
from langgraph.graph import StateGraph, START, END

class Log(TypedDict):
    id: str
    question: str
    answer: str
    grade: int | None

class FailureAnalysisState(TypedDict):
    cleaned_logs: list[Log]      # Input from parent (overlapping key)
    failures: list[Log]          # Internal state — will NOT leak to parent
    fa_summary: str              # Output
    processed_logs: list[str]    # Output

class FailureAnalysisOutput(TypedDict):
    fa_summary: str              # Only these keys return to parent
    processed_logs: list[str]

def build_failure_subgraph():
    def get_failures(state: FailureAnalysisState) -> dict:
        failures = [log for log in state["cleaned_logs"] if log.get("grade") is not None]
        return {"failures": failures}

    def summarize(state: FailureAnalysisState) -> dict:
        return {
            "fa_summary": f"Found {len(state['failures'])} issues",
            "processed_logs": [f"fa-{f['id']}" for f in state["failures"]],
        }

    builder = StateGraph(
        state_schema=FailureAnalysisState,
        output_schema=FailureAnalysisOutput,  # Controls what returns to parent
    )
    builder.add_node("get_failures", get_failures)
    builder.add_node("summarize", summarize)
    builder.add_edge(START, "get_failures")
    builder.add_edge("get_failures", "summarize")
    builder.add_edge("summarize", END)
    return builder.compile()

class ParentState(TypedDict):
    raw_logs: list[Log]
    cleaned_logs: list[Log]
    fa_summary: str
    processed_logs: Annotated[list[str], add]  # Reducer required for parallel outputs

builder = StateGraph(ParentState)
builder.add_node("clean", lambda s: {"cleaned_logs": s["raw_logs"]})
builder.add_node("failure_analysis", build_failure_subgraph())
builder.add_edge(START, "clean")
builder.add_edge("clean", "failure_analysis")
builder.add_edge("failure_analysis", END)
graph = builder.compile()
```

---

## Subgraph Checkpointer Scoping

When compiling a subgraph, the `checkpointer` parameter determines its persistence behavior. This is the most non-obvious decision in subgraph composition.

| Feature | `checkpointer=False` | `None` (default/omit) | `checkpointer=True` |
|---|---|---|---|
| Interrupts (HITL) | No | Yes | Yes |
| Multi-turn memory | No | No | Yes |
| Multiple calls (different subgraphs) | Yes | Yes | Warning (namespace conflicts possible) |
| Multiple calls (same subgraph in parallel) | Yes | Yes | **No — namespace conflict** |
| State inspection via `get_state_history` | No | Current invocation only | Yes (full history) |

### When to use each mode

- **`checkpointer=False`** — Subgraph needs neither interrupts nor persistence. Zero checkpoint overhead, safest for parallel calls of the same subgraph.
- **`None` (omit `checkpointer`)** — Subgraph needs `interrupt()` but not multi-turn memory. Each invocation starts fresh but can pause and resume within that invocation.
- **`checkpointer=True`** — Subgraph must remember state across invocations (multi-turn conversations per subgraph). Cannot safely be called multiple times within one parent node for the same subgraph instance.

```python
# No interrupts needed — opt out
subgraph = subgraph_builder.compile(checkpointer=False)

# Need interrupts, not cross-invocation memory (default)
subgraph = subgraph_builder.compile()

# Need cross-invocation memory (stateful subgraph)
subgraph = subgraph_builder.compile(checkpointer=True)
```

---

## Parallel Stateful Subgraphs — Namespace Isolation

When multiple **different** stateful subgraphs (`checkpointer=True`) run in parallel, each must have a **unique node name** to get a stable namespace. Wrap each in its own single-node `StateGraph`:

```python
from langgraph.graph import MessagesState, StateGraph

def create_sub_agent(model, *, name, **kwargs):
    """Wrap an agent with a unique node name for namespace isolation."""
    agent = create_agent(model=model, name=name, **kwargs)
    return (
        StateGraph(MessagesState)
        .add_node(name, agent)   # unique name → stable checkpoint namespace
        .add_edge("__start__", name)
        .compile()
    )

fruit_agent = create_sub_agent("gpt-4.1", name="fruit_agent", tools=[fruit_info], checkpointer=True)
veggie_agent = create_sub_agent("gpt-4.1", name="veggie_agent", tools=[veggie_info], checkpointer=True)
```

Note: subgraphs added via `add_node` already receive name-based namespaces automatically. This wrapper pattern is needed only when passing pre-compiled agent objects.

---

## Long-Term Memory (Store)

```python
from langgraph.store.memory import InMemoryStore
from langgraph.runtime import Runtime

store = InMemoryStore()

# Save user preference — available across ALL threads for this user
store.put(("alice", "preferences"), "language", {"preference": "short responses"})

# Node accesses store via Runtime — NEVER capture store from outer scope
def respond(state, runtime: Runtime):
    prefs = runtime.store.get((state["user_id"], "preferences"), "language")
    return {"response": f"Using preference: {prefs.value}"}

# Compile with BOTH checkpointer and store
graph = builder.compile(checkpointer=checkpointer, store=store)

# Thread-1 and thread-2 share the same long-term memory for user alice
graph.invoke({"user_id": "alice"}, {"configurable": {"thread_id": "thread-1"}})
graph.invoke({"user_id": "alice"}, {"configurable": {"thread_id": "thread-2"}})
```

Basic store operations:

```python
store.put(("user-123", "facts"), "location", {"city": "San Francisco"})  # Put
item = store.get(("user-123", "facts"), "location")                       # Get
results = store.search(("user-123", "facts"), filter={"city": "San Francisco"})  # Search
store.delete(("user-123", "facts"), "location")                           # Delete
```

---

## Fixes

### thread_id missing → state not persisted

```python
# WRONG: No thread_id — state NOT persisted
graph.invoke({"messages": ["Hello"]})
graph.invoke({"messages": ["What did I say?"]})  # Doesn't remember

# CORRECT: Always provide thread_id
config = {"configurable": {"thread_id": "session-1"}}
graph.invoke({"messages": ["Hello"]}, config)
graph.invoke({"messages": ["What did I say?"]}, config)  # Remembers
```

### update_state passes through reducers — use Overwrite to replace

```python
from langgraph.types import Overwrite

# State: items: Annotated[list, operator.add]
# Current state: {"items": ["A", "B"]}

graph.update_state(config, {"items": ["C"]})              # Result: ["A","B","C"] — appended!
graph.update_state(config, {"items": Overwrite(["C"])})   # Result: ["C"] — replaced
```

### Store not accessible in node without Runtime

```python
# WRONG: outer-scope capture fails when graph is invoked on a different thread
def my_node(state):
    store.put(...)  # NameError or wrong store instance

# CORRECT: inject via Runtime type annotation
from langgraph.runtime import Runtime

def my_node(state, runtime: Runtime):
    runtime.store.put(...)
```

---

## Anti-Patterns

**NEVER use `InMemorySaver` in production.**
WHY: The entire checkpoint store lives in the process heap. Any restart, crash, or horizontal scale-out destroys all thread history. Users lose conversation context silently with no error. Use `PostgresSaver` for any persistent deployment.

**NEVER omit `thread_id` from `config`.**
WHY: Without `thread_id`, LangGraph cannot map the invocation to a checkpoint sequence. State is computed then discarded — the graph appears to work but forgets everything immediately. There is no warning.

**NEVER expect `update_state` to bypass reducers.**
WHY: `update_state` feeds its delta through the same reducer functions as a normal node return. If your field uses `operator.add`, `update_state(config, {"items": ["x"]})` appends, not replaces. The only escape is `Overwrite(value)`.

**NEVER call the same `checkpointer=True` subgraph instance multiple times within one parent node in parallel.**
WHY: All parallel calls share the same checkpoint namespace (derived from the subgraph's node name in the parent). Concurrent writes produce non-deterministic state — the last writer wins, silently discarding other branches' history.

**NEVER access a Store directly in a node via an outer-scope reference.**
WHY: LangGraph may inject a different store instance at runtime (e.g., when running distributed workers). Using `runtime.store` guarantees the correct, request-scoped store. Outer-scope references point to the construction-time object, which may be stale or from a different process.

**NEVER omit `output_schema` on a subgraph that has internal-only state keys.**
WHY: Without `output_schema`, LangGraph merges the subgraph's entire final state back into the parent. Internal fields (e.g., intermediate working state, debug keys) collide with or overwrite parent keys of the same name. `output_schema` is the only gate that controls what crosses the parent boundary.

**NEVER use sync `PostgresSaver` with async graph nodes.**
WHY: Calling a sync blocking I/O operation (psycopg blocking query) from an `async def` node runs inside the event loop and blocks it. This deadlocks any other coroutines waiting in the same loop. Match async graphs with `AsyncPostgresSaver`.
