# Error Handling

## Error-to-Handler Decision Table

Match the error type to the right resolver — wrong handler wastes tokens or hangs the graph:

| Error type                        | Owner     | Strategy                                     | Implementation                         |
|-----------------------------------|-----------|----------------------------------------------|----------------------------------------|
| Transient (network, rate limits)  | System    | `RetryPolicy(max_attempts=N)`                | Attach to `add_node()`                 |
| LLM-recoverable (tool failures)   | LLM       | `ToolNode(tools, handle_tool_errors=True)`   | Error returned as ToolMessage          |
| User-fixable (missing info)       | Human     | `interrupt({"message": ...})`                | See `langgraph-human-in-the-loop`     |
| Unexpected / programmer error     | Developer | Let it bubble up                             | `raise` — do not swallow              |

## RetryPolicy

Attach a retry policy per-node; different nodes can have different policies.

```python
from langgraph.types import RetryPolicy

workflow.add_node(
    "search_documentation",
    search_documentation,
    retry_policy=RetryPolicy(max_attempts=3, initial_interval=1.0)
)
```

**Important**: `RetryPolicy` retries the node function, not the entire graph. State is restored to the pre-node snapshot before each retry, so nodes must be idempotent (no side-effects that persist outside LangGraph state).

## ToolNode Error Handling

```python
from langgraph.prebuilt import ToolNode

tool_node = ToolNode(tools, handle_tool_errors=True)
workflow.add_node("tools", tool_node)
```

When `handle_tool_errors=True`, exceptions from tool execution are caught and returned to the LLM as `ToolMessage` with the error text — the LLM can then choose to retry, rephrase, or stop. Without this flag, a tool exception propagates and terminates the graph.

## Non-Transient Failure: Fail Fast

For errors that are not retryable (schema violations, auth failures), do NOT wrap in RetryPolicy — let the exception propagate. Swallowing errors in a loop leads to infinite retry storms.

```python
def validate_node(state: State) -> dict:
    if not state.get("required_field"):
        raise ValueError("required_field is missing from state")  # Propagates — correct
    return {}
```
