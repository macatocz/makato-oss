---
name: langgraph-fundamentals
description: >-
  INVOKE THIS SKILL when writing ANY LangGraph code — StateGraph, reducers,
  nodes, edges, Command, Send, parallel execution, map-reduce, message
  trimming, invoke, streaming, or error handling. Python-only. Trigger keywords:
  StateGraph, reducer, Annotated state, add_node, add_edge, Command, Send,
  fan-out, fan-in, interrupt, compile.
version: "1.2.0"
argument-hint: "what LangGraph task are you working on?"
metadata:
  authors: ["makato-langgraph"]
  last_updated: "2026-08-05"
---

## LangGraph Design Framework

Answer these questions in order before writing any code — each answer constrains the next.

**1. State schema — which type?**

| Condition | Schema |
|---|---|
| Messages only | `MessagesState` (built-in; `add_messages` reducer already included) |
| Typed data, no defaults, no validation | `TypedDict` (most common; `total=False` for optional fields) |
| Typed data with field defaults or `__post_init__` logic | `dataclass` (`field(default_factory=...)`) |
| Runtime validation, strict contracts, or external-input coercion | `Pydantic BaseModel` (costs: `arbitrary_types_allowed=True` required for LangChain types; validators re-run on every partial update) |

**2. Which fields need reducers?**
- Any field written by ≥2 nodes (parallel static edges OR `Send` workers) → `Annotated[T, reducer]`
- Fields written only in sequence → default overwrite is correct; no reducer needed

**3. How many nodes?**
- One distinct responsibility → one node; do not split for structure alone
- Multiple LLM calls or tool calls → one node each (enables per-node `RetryPolicy`, per-node streaming, per-node observability)

**4. Routing type?**
- Same next node always → `add_edge()` (compile-time static)
- Branch at runtime on state → `add_conditional_edges()` with router returning `Literal` node name(s)
- Update state AND route in one return → `Command` (eliminates the separate router function)
- Parallel workers with distinct per-worker inputs → `Send` (not static fan-out — each worker gets its own state snapshot)

**5. Fan-in aggregation?**
- Workers produce partial results → reducer on the aggregation field + synthesizer node after workers
- Workers only cause side effects → no aggregation needed; no synthesizer required

---

## State Management

<state-update-strategies>

| Need            | Solution                         | Example                     |
|-----------------|----------------------------------|-----------------------------|
| Overwrite value | No reducer (default)             | Simple fields like counters |
| Append to list  | Reducer (`operator.add`)         | Message history, logs       |
| Custom logic    | Custom reducer function          | Per-key metric aggregation  |

</state-update-strategies>

<ex-state-with-reducer>

```python
from typing_extensions import TypedDict, Annotated
import operator

class State(TypedDict):
    name: str                                 # Default: overwrites on update
    messages: Annotated[list, operator.add]   # Appends to list
    total: Annotated[int, operator.add]       # Sums integers
```

</ex-state-with-reducer>

<fix-forgot-reducer-for-list>

```python
# WRONG: List will be OVERWRITTEN — data silently lost, no error raised
class State(TypedDict):
    messages: list  # No reducer!

# Node 1 returns: {"messages": ["A"]}
# Node 2 returns: {"messages": ["B"]}
# Final: {"messages": ["B"]}  # "A" is LOST — silent data loss

# CORRECT
class State(TypedDict):
    messages: Annotated[list, operator.add]
# Final: {"messages": ["A", "B"]}
```

</fix-forgot-reducer-for-list>

<fix-parallel-no-reducer>

```python
# WRONG: Two parallel nodes both write to "items" — runtime ERROR
class State(TypedDict):
    items: list  # No reducer!

graph.add_edge(START, "task_a")  # task_a returns {"items": ["A"]}
graph.add_edge(START, "task_b")  # task_b returns {"items": ["B"]}
# ERROR: Cannot resolve conflicting updates!

# CORRECT: Add a reducer
class State(TypedDict):
    items: Annotated[list, operator.add]
```

</fix-parallel-no-reducer>

<fix-state-must-return-dict>

```python
# WRONG: Returning entire state object
def my_node(state: State) -> State:
    state["field"] = "updated"
    return state  # Mutates and returns — causes unexpected behaviour

# CORRECT: Return dict with only the updates
def my_node(state: State) -> dict:
    return {"field": "updated"}
```

</fix-state-must-return-dict>

---

## State Schema Examples

<ex-state-schema-typeddict>

```python
from typing import Any, Literal, TypedDict

class State(TypedDict, total=False):
    name: str
    age: int
    mood: Literal["happy", "sad", "excited"]
    interests: list[str]
    result: dict[str, Any]
```

</ex-state-schema-typeddict>

<ex-state-schema-dataclass>

```python
from dataclasses import dataclass, field
from typing_extensions import Annotated
import operator

@dataclass
class State:
    name: str = ""
    messages: Annotated[list, operator.add] = field(default_factory=list)
    count: int = 0
    # Annotated reducers work on dataclass fields exactly as with TypedDict
```

</ex-state-schema-dataclass>

<ex-state-schema-pydantic>

```python
from typing import Any, Literal
from pydantic import BaseModel, field_validator

class State(BaseModel):
    name: str = ""
    age: int = 0
    mood: Literal["happy", "sad", "excited"] = "happy"
    interests: list[str] = []

    @field_validator("age")
    @classmethod
    def validate_age(cls, value):
        if value < 0 or value > 150:
            raise ValueError("Age must be between 0 and 150")
        return value
```

</ex-state-schema-pydantic>

<fix-pydantic-arbitrary-types>

```python
# Pydantic state with LangChain message types requires extra config
from pydantic import ConfigDict

class State(BaseModel):
    model_config = ConfigDict(arbitrary_types_allowed=True)
    messages: list[BaseMessage]  # LangChain types need arbitrary_types_allowed
```

Without `arbitrary_types_allowed=True`, Pydantic raises a validation error at class definition time when it encounters non-standard types like `BaseMessage` — the graph never compiles.

</fix-pydantic-arbitrary-types>

---

## Nodes

Node functions accept these signatures:

| Signature                                              | When to Use                                    |
|--------------------------------------------------------|------------------------------------------------|
| `def node(state: State)`                               | Simple nodes that only need state              |
| `def node(state: State, config: RunnableConfig)`       | Need `thread_id`, tags, or configurable values |
| `def node(state: State, runtime: Runtime[Context])`    | Need runtime context, store, or stream writer  |

```python
from langchain_core.runnables import RunnableConfig
from langgraph.runtime import Runtime

def plain_node(state: State):
    return {"results": "done"}

def node_with_config(state: State, config: RunnableConfig):
    thread_id = config["configurable"]["thread_id"]
    return {"results": f"Thread: {thread_id}"}

def node_with_runtime(state: State, runtime: Runtime[Context]):
    user_id = runtime.context.user_id
    return {"results": f"User: {user_id}"}
```

---

## Edges

| Need                       | Edge Type                    | When to Use                              |
|----------------------------|------------------------------|------------------------------------------|
| Always go to same node     | `add_edge()`                 | Fixed, deterministic flow                |
| Route based on state       | `add_conditional_edges()`    | Dynamic branching                        |
| Update state AND route     | `Command`                    | Combine logic + routing in a single node |
| Fan-out to multiple nodes  | `Send`                       | Parallel with dynamic per-worker inputs  |

---

## Command

`Command` combines state updates and routing in a single return value.

- **`update`**: State updates to apply (same as returning a dict from a node)
- **`goto`**: Node name(s) to navigate to next
- **`resume`**: Value to resume after `interrupt()` — see `langgraph-human-in-the-loop`

```python
from langgraph.types import Command
from typing import Literal

def node_a(state: State) -> Command[Literal["node_b", "node_c"]]:
    new_count = state["count"] + 1
    if new_count > 5:
        return Command(update={"count": new_count}, goto="node_c")
    return Command(update={"count": new_count}, goto="node_b")
```

<warning-command-static-edges>

**Critical**: `Command` only adds **dynamic** edges. Static edges from `add_edge()` still execute unconditionally. If `node_a` returns `Command(goto="node_c")` and you also have `graph.add_edge("node_a", "node_b")`, **both** `node_b` and `node_c` run — this is not a routing choice, it is additive fan-out.

</warning-command-static-edges>

---

## Send API

Fan-out with `Send`: return `[Send("worker", {...})]` from a conditional edge to spawn parallel workers with per-worker state. Requires a reducer on the results field — without one, the last worker's write overwrites all others (no error raised).

```python
from langgraph.types import Send
from typing import Annotated
import operator

class OrchestratorState(TypedDict):
    tasks: list[str]
    results: Annotated[list, operator.add]  # reducer required
    summary: str

def orchestrator(state: OrchestratorState):
    return [Send("worker", {"task": task}) for task in state["tasks"]]

def worker(state: dict) -> dict:
    return {"results": [f"Completed: {state['task']}"]}

def synthesize(state: OrchestratorState) -> dict:
    return {"summary": f"Processed {len(state['results'])} tasks"}

graph = (
    StateGraph(OrchestratorState)
    .add_node("worker", worker)
    .add_node("synthesize", synthesize)
    .add_conditional_edges(START, orchestrator, ["worker"])
    .add_edge("worker", "synthesize")
    .add_edge("synthesize", END)
    .compile()
)
```

---

## Message Trimming

Long conversations exceed LLM context limits. Trim inside the node before invoking the LLM.

| Strategy     | How It Works                                  | Best For                              |
|--------------|-----------------------------------------------|---------------------------------------|
| Count-based  | Keep last N messages                          | Simple limit enforcement              |
| Token-based  | Estimate tokens, trim to budget               | Cost management                       |
| Smart        | Preserve system + early context + recent msgs | Context-sensitive conversations       |
| Summary-based| LLM summarizes old messages, keep recent      | Long sessions with critical early ctx |

**Forcing function**: start with count-based; escalate to token-based only when cost of over-inclusion is measurable; escalate to summary-based only when early context is causally required (user-stated goals or system instructions embedded in conversation history).

```python
from langchain_core.messages import BaseMessage, SystemMessage

def trim_messages_by_count(messages: list[BaseMessage], max_messages: int = 10) -> list[BaseMessage]:
    if len(messages) <= max_messages:
        return messages
    system_msgs = [m for m in messages if isinstance(m, SystemMessage)]
    other_msgs = [m for m in messages if not isinstance(m, SystemMessage)]
    recent = other_msgs[-(max_messages - len(system_msgs)):]
    return system_msgs + recent

def chat_node(state: MessagesState):
    trimmed = trim_messages_by_count(state["messages"], max_messages=8)
    response = llm.invoke(trimmed)
    return {"messages": [response]}
```

<fix-preserve-system-message>

```python
# WRONG: Naive slicing silently drops the SystemMessage
trimmed = messages[-10:]  # System message at index 0 is gone

# CORRECT: Separate before slicing
system_msgs = [m for m in messages if isinstance(m, SystemMessage)]
other_msgs = [m for m in messages if not isinstance(m, SystemMessage)]
trimmed = system_msgs + other_msgs[-8:]
```

</fix-preserve-system-message>

---

## Anti-Patterns

A dedicated list of non-obvious failures — each with the exact WHY that experience teaches.

**NEVER return the full state object from a node.**
WHY: LangGraph applies the return value as a partial update dict. Returning the full state object causes every field to be "updated" (triggering all reducers), and on Pydantic state it re-runs field validators on unchanged data — silent validator side-effects and corrupted reducer state.

**NEVER use `Command` goto together with a static `add_edge()` from the same source unless you intend both to execute.**
WHY: `Command.goto` does not replace static edges — it is additive. The static edge fan-out runs regardless, so `node_b` and `node_c` both execute. This looks like a routing bug but is correct LangGraph semantics; the only fix is to remove the static edge.

**NEVER define a list field receiving parallel writes without a reducer.**
WHY: For parallel fan-out (static edges), LangGraph raises an explicit conflict error. For `Send` fan-out, no error is raised — the last worker to finish silently overwrites all earlier results. Silent data loss is harder to detect than the error case.

**NEVER apply `RetryPolicy` to non-idempotent side-effecting nodes.**
WHY: `RetryPolicy` restores LangGraph state to the pre-node snapshot but does NOT undo external side effects (database writes, API calls, emails). Retrying a non-idempotent node duplicates those side effects on every retry attempt.

**NEVER route back to `START`.**
WHY: `START` is a virtual entry node injected by LangGraph at compile time — it has no actual function. Routing to it does not re-enter the graph from the beginning; it raises a compile-time or runtime error. Use a named entry node instead.

**NEVER use a custom reducer that does not handle `None` as the left argument.**
WHY: When a reducer field has not yet received any value (first write), LangGraph passes `None` as the `left` argument. A reducer that does `left.copy()` without guarding raises `AttributeError` the first time the field is written.

**NEVER call `get_stream_writer()` outside a running graph node.**
WHY: The stream writer is a contextvar injected by the LangGraph runtime — it does not exist outside `graph.stream()`. Calling it in tests or outside a node raises `RuntimeError: No stream writer in context`.

---

## Common Fixes

```python
# Must compile() before invoke — builder has no invoke() method
graph = builder.compile()
graph.invoke({"input": "test"})  # CORRECT

# Provide an exit path to avoid infinite loops
def should_continue(state):
    return END if state["count"] > 10 else "node_b"
builder.add_conditional_edges("node_a", should_continue)

# Router must return node names that exist in the graph
builder.add_node("my_node", func)  # Add node BEFORE referencing in edges
builder.add_conditional_edges("node_a", router, ["my_node"])

# Reducer expects matching element types
return {"items": ["item"]}   # list for a list reducer — not a bare string

# Command return type annotation declares valid goto targets (Python)
def node_a(state) -> Command[Literal["node_b", "node_c"]]:
    return Command(goto="node_b")

# Inspect the compiled graph structure — useful when routing is wrong
print(graph.get_graph().draw_mermaid())  # Mermaid diagram of all nodes + edges
graph.get_graph().print_ascii()          # Text-mode graph for terminal debugging
```

---

## Reference Files

Load these only when the corresponding task arises. **Do NOT load all references at once.**

### `references/parallel-and-map-reduce.md`

**MANDATORY when**: building fan-out/fan-in graphs, writing a map-reduce pattern, or designing a custom reducer for complex aggregation (e.g., per-key metric summing).

**Do NOT load** for single-path linear graphs or graphs with conditional edges only.

### `references/stream-modes.md`

**MANDATORY when**: implementing token streaming for a chat UI, using `stream_mode="custom"` or `stream_mode="messages"`, or calling `get_stream_writer()` inside a node.

**Do NOT load** when the graph is invoked with `graph.invoke()` only (no streaming).

### `references/error-handling.md`

**MANDATORY when**: attaching `RetryPolicy` to a node, using `ToolNode` with `handle_tool_errors`, or deciding which error type (transient / LLM-recoverable / user-fixable) applies.

**Do NOT load** for graphs with no retry requirements and no tool execution nodes.
