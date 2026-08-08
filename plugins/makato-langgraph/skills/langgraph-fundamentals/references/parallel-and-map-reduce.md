# Parallel Execution & Map-Reduce

## Parallel Fan-out / Fan-in

Multiple `add_edge(START, node)` calls within the same builder cause all targets to execute in the same superstep. All parallel branches must complete before the next superstep runs.

**Key constraint**: every state field written by more than one parallel branch MUST have a reducer, or LangGraph raises a conflict error at runtime.

```python
import operator
from typing import Annotated, TypedDict
from langgraph.graph import StateGraph, START, END

class ResearchState(TypedDict):
    query: str
    stock_data: Annotated[list, operator.add]
    news_data: Annotated[list, operator.add]
    info_data: Annotated[list, operator.add]
    report: str

def get_stock(state: ResearchState) -> dict:
    return {"stock_data": [f"Price for {state['query']}: $150.00"]}

def get_news(state: ResearchState) -> dict:
    return {"news_data": [f"Latest news for {state['query']}"]}

def get_info(state: ResearchState) -> dict:
    return {"info_data": [f"Company info for {state['query']}"]}

def synthesize(state: ResearchState) -> dict:
    all_data = state["stock_data"] + state["news_data"] + state["info_data"]
    return {"report": f"Report with {len(all_data)} data points"}

builder = StateGraph(ResearchState)
builder.add_node("stock", get_stock)
builder.add_node("news", get_news)
builder.add_node("info", get_info)
builder.add_node("synthesize", synthesize)

# Fan-out: START to all three (parallel superstep)
builder.add_edge(START, "stock")
builder.add_edge(START, "news")
builder.add_edge(START, "info")

# Fan-in: all three converge to synthesizer
builder.add_edge("stock", "synthesize")
builder.add_edge("news", "synthesize")
builder.add_edge("info", "synthesize")
builder.add_edge("synthesize", END)

graph = builder.compile()
```

## Map-Reduce Pattern (Dynamic Fan-out via Send)

Use `Send` for dynamic fan-out where the number of workers is not known at graph-definition time. A dispatcher function returns a list of `Send` objects — one per work item — via `add_conditional_edges`. LangGraph spawns a separate worker invocation for each `Send`, then a reducer collects all results.

```python
import operator
from typing import Annotated, TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.types import Send

class OverallState(TypedDict):
    tasks: list[str]
    results: Annotated[list[dict], operator.add]
    summary: str

class WorkerState(TypedDict):
    task: str
    results: Annotated[list[dict], operator.add]

def dispatcher(state: OverallState) -> list[Send]:
    """Dynamic fan-out: one Send per task item; count determined at runtime."""
    return [Send("worker", {"task": t}) for t in state["tasks"]]

def worker(state: WorkerState) -> dict:
    """Process a single task and append its result."""
    return {"results": [{"task": state["task"], "output": f"processed: {state['task']}"}]}

def reducer(state: OverallState) -> dict:
    """Collect results from all worker invocations and produce a summary."""
    return {"summary": f"Processed {len(state['results'])} tasks"}

builder = StateGraph(OverallState)
builder.add_node("worker", worker)
builder.add_node("reduce", reducer)

# Dynamic fan-out via conditional edge returning Send objects — NOT add_edge(START, ...)
builder.add_conditional_edges(START, dispatcher, ["worker"])
builder.add_edge("worker", "reduce")
builder.add_edge("reduce", END)

graph = builder.compile()

# The task list is determined at runtime; any number of workers is spawned
result = graph.invoke({"tasks": ["task-A", "task-B", "task-C"]})
# result["summary"] == "Processed 3 tasks"
```

## Custom Reducer for Metrics Aggregation

When `operator.add` is not sufficient (e.g., you need to sum values per-key across parallel workers):

```python
from typing import Annotated

def metrics_aggregator(left: dict[str, int], right: dict[str, int]) -> dict[str, int]:
    """Sum matching keys from parallel metric collectors."""
    result = (left or {}).copy()
    for key, value in (right or {}).items():
        result[key] = result.get(key, 0) + value
    return result

class AnalysisState(TypedDict):
    metrics: Annotated[dict[str, int], metrics_aggregator]
    summary: str
```

**Note**: custom reducers receive `None` as the left argument when the field has no prior value — always guard with `(left or {})`.
