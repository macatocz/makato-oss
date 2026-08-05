---
name: langgraph-agent-patterns
description: >-
  INVOKE THIS SKILL when building LLM agents with tools in LangGraph. Covers
  ReAct loop (manual and prebuilt), multi-step planning, conditional branching,
  MessagesState, ToolNode, tools_condition, parallel tool_calls, recursion
  guards, and MCP integration. Python-only. Trigger keywords: ReAct, ToolNode,
  tools_condition, MessagesState, tool-calling agent, LangGraph agent, MCP
  tools, create_react_agent, bind_tools, StateGraph.
version: "1.2.0"
metadata:
  authors: [makato-langgraph]
  last_updated: "2026-08-05"
argument-hint: "[pattern: react|multi-step|conditional|mcp] [--manual]"
---

<overview>
Agent patterns are graph topologies for LLM-driven decision making. Each pattern solves a specific
class of problems — pick the simplest one that fits your task.

**Do NOT load** `references/mcp-advanced.md` unless the task involves multiple MCP servers, MCP
connection errors, or mixing MCP tools with native tools. See the MANDATORY trigger in the MCP
section below.

**Do NOT load** `references/patterns-full.md` unless the user explicitly needs a complete,
runnable boilerplate implementation. See the MANDATORY trigger below.
</overview>

---

## Diagnostic Framework

Before reaching for a pattern, answer these three questions in order. They map directly to the
pattern selection table below.

```
1. Does the task require dynamic, repeated tool calls driven by LLM reasoning?
   NO  → Minimal (single-node) or Multi-step planning. Stop here.
   YES → ReAct or MCP. Continue.

2. Do I need custom per-tool logic — logging, filtering, selective retry, or pre/post-processing?
   NO  → ReAct prebuilt (ToolNode + tools_condition). Stop here.
   YES → ReAct manual. Continue.

3. Does the tool source come from an external MCP server?
   NO  → Use the manual ReAct pattern with @tool functions.
   YES → MCP integration (single server) or multi-server.
       MANDATORY: load references/mcp-advanced.md if multi-server or connection errors arise.
```

If the pattern choice is still ambiguous after this tree (e.g., unclear whether task decomposes
into stages or calls tools dynamically), surface the decision to the user with a concrete question:
"Does this task need to call different tools at each step based on intermediate results, or does it
always follow a fixed sequence of stages?" Route ReAct for the former, multi-step for the latter.

---

## Pattern Selection

| Pattern | When to Use | Complexity |
|---------|-------------|------------|
| Minimal single-node | Simple LLM call, structured JSON output, no tool calls | Low |
| Multi-step planning | Decompose into fixed plan + execute stages | Low-Medium |
| Conditional branching | Route to specialist nodes based on LLM classification | Medium |
| ReAct prebuilt | Standard tool-calling loop — **default choice** | Medium |
| ReAct manual | Custom tool routing logic, per-tool logging or filtering | Medium |
| MCP integration | Tools loaded from external MCP server(s) | Medium |

**Default choice**: Use **ReAct (prebuilt)** for tool-calling agents. Only use manual ReAct when
you need custom routing logic such as per-tool logging, result filtering, or selective retry.

**Compose patterns**: Multi-step planning + ReAct is the standard pattern for complex tasks —
planning decomposes the task, ReAct executes each step with tools. Both share `MessagesState`.

**MANDATORY: Load `references/patterns-full.md`** when the user asks for a complete, runnable
boilerplate ("show me the full example", "copy-paste implementation", "complete code for X agent").

---

## Non-Obvious Practitioner Gotchas

These are the failure modes most commonly encountered after the basic pattern is working.

### Parallel Tool Calls (LLM emits multiple tool_calls in one response)

Modern LLMs (GPT-4, Claude 3+) can emit **multiple tool calls in a single assistant message**.
`ToolNode` handles this automatically — it iterates `message.tool_calls` (plural) and returns one
`ToolMessage` per call. A manual `tool_executor` that only processes `tool_calls[0]` silently
drops all but the first tool call:

```python
# WRONG — silently drops parallel calls after the first
def tool_executor(state: MessagesState):
    call = state["messages"][-1].tool_calls[0]   # only the first!
    result = tools_by_name[call["name"]].invoke(call["args"])
    return {"messages": [ToolMessage(content=str(result), tool_call_id=call["id"])]}

# CORRECT — iterate the full list
def tool_executor(state: MessagesState):
    results = []
    for call in state["messages"][-1].tool_calls:
        result = tools_by_name[call["name"]].invoke(call["args"])
        results.append(ToolMessage(content=str(result), tool_call_id=call["id"]))
    return {"messages": results}
```

Use `ToolNode` (prebuilt) whenever possible — it handles parallel calls, error surfacing, and
metadata preservation.

### Infinite Loop Guard via recursion_limit

A ReAct graph with no termination condition will loop indefinitely if the LLM always emits tool
calls (e.g., a buggy tool that always returns an error the LLM retries). Set `recursion_limit`
at compile time — LangGraph raises `GraphRecursionError` instead of looping forever:

```python
app = graph.compile(recursion_limit=25)   # default is 25; lower for tighter budgets
```

`recursion_limit` counts **node invocations**, not LLM calls. A single assistant→tools→assistant
round trip consumes 3 invocations. Budget accordingly:
`recursion_limit = (max_expected_rounds * 2) + 5`.

**When `GraphRecursionError` fires in production**: it means either (a) the tool has a bug
returning persistent errors, (b) the LLM is looping on an unsolvable sub-problem, or (c) the
budget is set too low. Diagnosis: inspect `state["messages"][-5:]` for the last few tool
results — repeated identical errors point to (a)/(b); a legitimate deep workflow points to (c).
Raise the limit only after confirming the task genuinely requires more rounds.

### tools_condition Returns END on Empty tool_calls

`tools_condition` checks `last_message.tool_calls` (a list). When the list is empty **or**
missing, it routes to `END`. Some LLMs return `tool_calls=None` (not `[]`) on their last
response — `tools_condition` handles both cases. If you write a custom routing function, guard
both:

```python
def should_continue(state: MessagesState) -> str:
    last = state["messages"][-1]
    calls = getattr(last, "tool_calls", None) or []
    return "tools" if calls else END
```

### async ainvoke vs sync invoke

`app.invoke()` internally calls `asyncio.run()` which creates a **new** event loop. Inside an
existing `async` context (e.g., an `async with` MCP session block), this raises
`RuntimeError: This event loop is already running`. Rule: if the surrounding code is async,
always use `await app.ainvoke(...)`.

---

## Pattern Skeletons

Each section below shows only the non-obvious structural choices — the parts Claude would not
generate correctly from training data alone. For full, copy-paste runnable implementations,
**load `references/patterns-full.md`** (MANDATORY trigger: user asks for complete example).

### Minimal Single-Node Agent

Single graph node. Useful for structured JSON output without tool calling. Custom `TypedDict`
state is safe here because there are no `tool_calls` to preserve.

Key structural choice: `JsonOutputParser` is chained outside the graph, not inside — it has no
state access and is pure output transformation.

```
StateGraph(State)
  call_model → END
```

### Multi-Step Planning

Two-node fixed pipeline. Key difference from ReAct: the execution path is **known at graph
build time** (plan → answer edge). No `tools_condition` needed — no dynamic routing.

```
StateGraph(State)    # custom TypedDict: question, plan, final
  plan → answer → END
```

The `plan_node` must write to a state key that `answer_node` reads. The state reducer for these
keys is last-write-wins (not list-append like `MessagesState`) — custom TypedDict is appropriate.

### Conditional Branching

Router node + specialist nodes. The routing function `route()` is a plain Python function that
reads state — it is **not** a graph node. Pass it as the second argument to
`add_conditional_edges`.

Non-obvious: the third argument (mapping dict) is required when the routing function returns
values that differ from node names; omitting it silently breaks routing.

```
StateGraph(State)    # custom TypedDict: input, intent, result
  classify → (route fn) → {informational|creative} → END
```

**Edge case**: LLM classification can return padded/cased variants. Always `lower().strip()`
the intent before branching, and always define a default branch in the route function.

### ReAct — Prebuilt (Recommended)

```python
# Key wiring — the parts that must be exactly right
graph.add_node("tools", ToolNode(tools=tools, handle_tool_errors=True))
graph.add_conditional_edges("assistant", tools_condition)   # no mapping dict needed
graph.add_edge("tools", "assistant")                        # loop back
app = graph.compile(recursion_limit=25)
```

`tools_condition` does not need an explicit mapping dict — its return values (`"tools"` and
`END`) are registered as edge targets automatically. Adding a mapping dict with wrong keys
causes a `ValueError` at compile time.

### ReAct — Manual Routing

Use only when prebuilt is insufficient. Structural difference from prebuilt: replace
`tools_condition` with a custom routing function and replace `ToolNode` with a hand-written
executor. Both must handle the parallel-calls case (iterate full `tool_calls` list).

```python
# Minimal delta from prebuilt
graph.add_conditional_edges("assistant", should_continue, {"tools": "tools", END: END})
# mapping dict IS required for manual routing — END must be in the dict
```

Note: the mapping dict is required here (unlike `tools_condition`) because a custom function's
return values are not pre-registered.

### MCP Integration

```python
# Non-obvious: graph must be built INSIDE the async with block
# — tools list from load_mcp_tools() is only valid while the session is open
async with ClientSession(read, write) as session:
    await session.initialize()
    tools = await load_mcp_tools(session)
    # ... build and compile graph here ...
    return await app.ainvoke(...)   # ainvoke is MANDATORY inside async context
```

**MANDATORY: Load `references/mcp-advanced.md`** when the task involves multiple MCP servers,
MCP connection errors, or mixing MCP tools with native `@tool` functions.

---

## Anti-Patterns

Each item below is a non-obvious failure mode that only experience teaches.

**NEVER use `create_react_agent` from `langchain.agents`** (WHY: it wraps the graph with a
callback interface incompatible with LangGraph's `MessagesState` reducer. On multi-turn loops
the message list grows correctly on the first turn, then silently resets on subsequent
invocations because the callback wrapper re-initialises state from scratch. Use the LangGraph
`StateGraph` pattern instead.)

**NEVER use `tool_calls[0]` in a manual executor** (WHY: LLMs can emit multiple tool calls in
a single response. Accessing only `[0]` silently drops every call after the first. The LLM
receives incomplete results, produces a hallucinated summary, and no error is raised. Iterate
the full `tool_calls` list or use `ToolNode`.)

**NEVER define tools inside node functions** (WHY: tools created inside a node closure are
re-instantiated on every node invocation. `ToolNode`'s internal dispatch table is keyed by
object identity at compile time, so the newly created object has a different identity and causes
`KeyError: <tool_name>` at runtime on the second invocation. Define tools at module level and
bind once before graph compilation.)

**NEVER use custom `TypedDict` state for tool-calling agents** (WHY: a custom state schema that
stores only `str` fields silently drops the `AIMessage` object including its `tool_calls` list.
`tools_condition` and `ToolNode` require the full message object to function. Use `MessagesState`,
which applies a list-append reducer and preserves message metadata.)

**NEVER omit `handle_tool_errors=True` on `ToolNode` in production** (WHY: without it, any tool
exception propagates as a Python exception and crashes the graph mid-run with no recovery path.
With it, the exception is caught and returned as a `ToolMessage` with the error text, letting the
LLM attempt recovery or explain the failure gracefully.)

**NEVER set `recursion_limit` above 50 without a termination analysis** (WHY: LangGraph counts
every node invocation, not just LLM calls. A 3-round agent consumes ~7 invocations. A very high
limit on an agent with a buggy tool masks infinite loops and silently burns LLM tokens before the
error surfaces. See the recursion_limit gotcha above for the production diagnosis procedure.)

**NEVER call `app.invoke()` inside an async context** (WHY: `invoke()` calls `asyncio.run()`
which opens a new event loop. If an existing loop is already running — MCP `async with`,
FastAPI endpoint, `pytest-asyncio` test — Python raises `RuntimeError: This event loop is
already running` and the graph never executes. Use `await app.ainvoke()` throughout.)

---

## Fixes

<fix-bind-tools>
```python
# WRONG: LLM without tools — will never produce tool calls
def assistant(state: MessagesState):
    return {"messages": [llm.invoke(state["messages"])]}

# CORRECT: Bind tools first, at module level
llm_with_tools = llm.bind_tools(tools)
def assistant(state: MessagesState):
    return {"messages": [llm_with_tools.invoke(state["messages"])]}
```
</fix-bind-tools>

<fix-tools-condition-import>
```python
# WRONG
from langgraph.graph import tools_condition  # ImportError!

# CORRECT
from langgraph.prebuilt import ToolNode, tools_condition
```
</fix-tools-condition-import>

<fix-messages-state>
```python
# WRONG: Custom state loses tool call metadata
class State(TypedDict):
    query: str
    response: str

# CORRECT: MessagesState preserves full message objects including tool calls
from langgraph.graph import MessagesState
graph = StateGraph(MessagesState)
```
</fix-messages-state>

<fix-tool-node-errors>
```python
# Without error handling, tool errors crash the graph
tool_node = ToolNode(tools)

# With error handling, errors become ToolMessages the LLM can process
tool_node = ToolNode(tools, handle_tool_errors=True)
```
</fix-tool-node-errors>
