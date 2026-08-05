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

Use `Send` for dynamic fan-out where the number of workers is not known at graph-definition time.

```python
import operator
from typing import Any, Annotated, TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.types import Send
from langchain_openai import ChatOpenAI
from langchain_core.messages import SystemMessage, HumanMessage

class AnalysisState(TypedDict):
    code: str
    security: Annotated[list[dict[str, Any]], operator.add]
    performance: Annotated[list[dict[str, Any]], operator.add]
    quality: Annotated[list[dict[str, Any]], operator.add]
    report: dict[str, Any]

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)

def security_mapper(state: AnalysisState) -> dict:
    system = SystemMessage(content="Analyze code for security issues. Return JSON: {\"issues\": [...]}")
    response = llm.invoke([system, HumanMessage(content=state["code"])])
    return {"security": [{"aspect": "security", "raw": response.content}]}

def performance_mapper(state: AnalysisState) -> dict:
    system = SystemMessage(content="Analyze code for performance issues. Return JSON: {\"issues\": [...]}")
    response = llm.invoke([system, HumanMessage(content=state["code"])])
    return {"performance": [{"aspect": "performance", "raw": response.content}]}

def quality_mapper(state: AnalysisState) -> dict:
    system = SystemMessage(content="Analyze code quality (SOLID, readability). Return JSON: {\"issues\": [...]}")
    response = llm.invoke([system, HumanMessage(content=state["code"])])
    return {"quality": [{"aspect": "quality", "raw": response.content}]}

def reducer(state: AnalysisState) -> dict:
    total = len(state["security"]) + len(state["performance"]) + len(state["quality"])
    return {"report": {"total_aspects_analyzed": total}}

builder = StateGraph(AnalysisState)
builder.add_node("security", security_mapper)
builder.add_node("performance", performance_mapper)
builder.add_node("quality", quality_mapper)
builder.add_node("reduce", reducer)

builder.add_edge(START, "security")
builder.add_edge(START, "performance")
builder.add_edge(START, "quality")
builder.add_edge("security", "reduce")
builder.add_edge("performance", "reduce")
builder.add_edge("quality", "reduce")
builder.add_edge("reduce", END)

graph = builder.compile()
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
