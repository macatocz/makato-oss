# Graph Construction Boilerplate

MANDATORY: Load this file when the user asks "how do I wire the graph", "add_node / add_edge", "compile with checkpointer", or is assembling the reflexion StateGraph for the first time. Do NOT Load if the user already has the graph compiled and is debugging runtime behaviour.

---

## Node and edge wiring

The five nodes (`act`, `tools`, `feedback`, `reflect`, `finalize`) and their conditional edges follow a fixed topology — deviate only to add pre/post hooks, not to restructure the loop.

```python
from langgraph.graph import StateGraph, START, END
from langgraph.prebuilt import ToolNode

def build_reflexion_graph(tools, max_attempts: int = 3, checkpointer=None):
    # --- define act / feedback / reflect / finalize node functions here ---

    def route_after_act(state):
        last = (state.get("messages") or [None])[-1]
        return "tools" if last and getattr(last, "tool_calls", None) else "feedback"

    def route_after_feedback(state):
        return "finalize" if state.get("approved") else "reflect"

    def route_after_reflect(state):
        attempt = int(state.get("attempt", 0))
        if attempt >= max_attempts:
            return "finalize"
        history = state.get("history", [])
        if len(history) >= 2:
            last_two = [h.get("notes", "") for h in history[-2:]]
            if last_two[0] and last_two[0] == last_two[1]:
                return "finalize"  # convergence: identical feedback twice → stop
        return "act"

    builder = StateGraph(ReflexionState)
    builder.add_node("act", act)
    builder.add_node("tools", ToolNode(tools))
    builder.add_node("feedback", feedback)
    builder.add_node("reflect", reflect)
    builder.add_node("finalize", finalize)

    builder.add_edge(START, "act")
    builder.add_conditional_edges("act", route_after_act, {"tools": "tools", "feedback": "feedback"})
    builder.add_edge("tools", "feedback")
    builder.add_conditional_edges("feedback", route_after_feedback, {"finalize": "finalize", "reflect": "reflect"})
    builder.add_conditional_edges("reflect", route_after_reflect, {"finalize": "finalize", "act": "act"})
    builder.add_edge("finalize", END)

    return builder.compile(checkpointer=checkpointer) if checkpointer else builder.compile()
```

### Why ToolNode goes before feedback, not after act

`ToolNode` executes tool calls synchronously and appends `ToolMessage` results to state. The `feedback` node needs those results visible in the conversation before asking the human to evaluate — routing tools → feedback (not tools → act) prevents the human from reviewing a response that is still mid-execution.

### compile() with vs without checkpointer

| Mode | When to use |
|------|-------------|
| `builder.compile()` | No persistence needed (single-process, one-shot run) |
| `builder.compile(checkpointer=checkpointer)` | Lessons must survive process restart; use `thread_id` in config |

Never call `builder.compile(checkpointer=None)` explicitly — omit the argument instead. Passing `None` bypasses the default-checkpointer logic in some LangGraph versions and disables state snapshots even when a default is configured.
