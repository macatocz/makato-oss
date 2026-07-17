# LangGraph + OpenTelemetry integration

This skill wires OTel spans into LangGraph **without** the classic-LangChain callback surface. LangGraph nodes are plain Python functions; spans wrap the function body directly.

## Where to place spans

Every LangGraph node is a callable `(state) -> state_delta`. Wrap the body:

```python
from opentelemetry import trace

_tracer = trace.get_tracer(__name__)

def my_node(state: MyState) -> dict:
    with _tracer.start_as_current_span("my_node") as span:
        # ... node body ...
        return {"key": "value"}
```

The span name SHOULD match the node's registered name in the graph (`graph.add_node("my_node", my_node)`). That way the dashboard trace tree mirrors the graph topology.

## Context propagation across async boundaries

LangGraph runs nodes concurrently when the graph declares parallel edges (`add_edge(start, [a, b, c])`). OTel's context carries the parent span across the async boundary automatically when the node uses `async with _tracer.start_as_current_span(...)`. No manual `context.attach()` / `context.detach()` needed.

If the node spawns a `asyncio.create_task()` inside its body, the task inherits the parent context at the moment of creation. Spans opened inside the task nest correctly under the parent.

## LLM spans

For LLM calls (the primary observation type Langfuse cares about), the pattern is:

```python
with _tracer.start_as_current_span("llm.call", kind=trace.SpanKind.CLIENT) as span:
    span.set_attribute("gen_ai.system", "openai")           # or "anthropic", ...
    span.set_attribute("gen_ai.request.model", model_name)
    response = client.chat.completions.create(...)
    span.set_attribute("gen_ai.usage.input_tokens", response.usage.prompt_tokens)
    span.set_attribute("gen_ai.usage.output_tokens", response.usage.completion_tokens)
```

`kind=SpanKind.CLIENT` signals this is an outbound call. Langfuse renders CLIENT spans differently in the trace tree.

## Tool-call spans

For LangGraph nodes that invoke tools (retrievers, function-calling), open a nested span:

```python
def tool_node(state):
    with _tracer.start_as_current_span("tool.execute") as span:
        tool_name = state["tool_call"]["name"]
        span.set_attribute("tool.name", tool_name)
        result = TOOLS[tool_name](state["tool_call"]["args"])
        return {"tool_result": result}
```

## What NOT to do

- Do NOT wrap the entire `graph.invoke()` call in a single top-level span. LangGraph's own runtime already emits the trace root when configured; wrapping it externally double-counts observations.
- Do NOT emit LangChain `Callback` events (`on_llm_start`, `on_chain_end`, etc.). LangGraph nodes without a LangChain wrapper never fire those callbacks — the trace stays empty.
- Do NOT block the async event loop with synchronous span exporter flushes inside a node. `BatchSpanProcessor` handles export asynchronously; per-span `span.end()` returns immediately.
