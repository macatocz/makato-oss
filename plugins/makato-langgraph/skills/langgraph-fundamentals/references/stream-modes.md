# Stream Modes & Custom Data

## Stream Mode Selection

| Mode       | What it streams            | Use case                    |
|------------|----------------------------|-----------------------------|
| `values`   | Full state after each step | Monitor complete state      |
| `updates`  | State deltas only          | Track incremental updates   |
| `messages` | LLM tokens + metadata      | Chat UIs, token-level UX    |
| `custom`   | User-defined data          | Progress indicators, events |

## Stream LLM Tokens (messages mode)

```python
from langchain_core.messages import HumanMessage

for chunk in graph.stream(
    {"messages": [HumanMessage("Hello")]},
    stream_mode="messages"
):
    token, metadata = chunk
    if hasattr(token, "content"):
        print(token.content, end="", flush=True)
```

## Custom Stream Writer

Use `get_stream_writer()` inside a node to push arbitrary data to `stream_mode="custom"` consumers. The writer is a contextvar injected by the runtime — do NOT import or construct it yourself; calling `get_stream_writer()` outside a running graph raises `RuntimeError`.

```python
from langgraph.config import get_stream_writer

def my_node(state):
    writer = get_stream_writer()
    writer({"event": "processing", "step": 1})
    # Do work
    writer({"event": "complete"})
    return {"result": "done"}

for chunk in graph.stream({"data": "test"}, stream_mode="custom"):
    print(chunk)
```

## Multi-mode Streaming

Pass a list to `stream_mode` to receive multiple stream types simultaneously:

```python
for chunk in graph.stream(input, stream_mode=["updates", "custom"]):
    mode, data = chunk
    if mode == "custom":
        print("Progress:", data)
    elif mode == "updates":
        print("State delta:", data)
```

## Invoke (non-streaming)

```python
result = graph.invoke({"input": "hello"})
# With config (required for persistence / thread isolation)
result = graph.invoke({"input": "hello"}, {"configurable": {"thread_id": "1"}})
```
