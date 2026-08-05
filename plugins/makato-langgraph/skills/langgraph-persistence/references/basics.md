# Persistence Basics

MANDATORY: Load this file ONLY when the user is new to LangGraph persistence and explicitly asks "how do I set up a checkpointer" or "what is a thread_id" — experienced users have this from training data.

Do NOT Load: when the user already has a graph with a checkpointer and is asking about subgraphs, time travel, Store, or production concerns.

---

## Checkpointer Setup (InMemorySaver — dev only)

```python
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import StateGraph, START, END
from typing_extensions import TypedDict, Annotated
import operator

class State(TypedDict):
    messages: Annotated[list, operator.add]

def add_message(state: State) -> dict:
    return {"messages": ["Bot response"]}

checkpointer = InMemorySaver()

graph = (
    StateGraph(State)
    .add_node("respond", add_message)
    .add_edge(START, "respond")
    .add_edge("respond", END)
    .compile(checkpointer=checkpointer)
)

# ALWAYS provide thread_id
config = {"configurable": {"thread_id": "conversation-1"}}

result1 = graph.invoke({"messages": ["Hello"]}, config)
print(len(result1["messages"]))  # 2

result2 = graph.invoke({"messages": ["How are you?"]}, config)
print(len(result2["messages"]))  # 4 (previous + new)
```

## Thread Isolation

Different `thread_id` values maintain fully separate state — Alice's messages never merge with Bob's:

```python
alice_config = {"configurable": {"thread_id": "user-alice"}}
bob_config = {"configurable": {"thread_id": "user-bob"}}

graph.invoke({"messages": ["Hi from Alice"]}, alice_config)
graph.invoke({"messages": ["Hi from Bob"]}, bob_config)
# Alice's state is isolated from Bob's
```

## Checkpointer selection

| Checkpointer | Use Case | Production Ready |
|---|---|---|
| `InMemorySaver` | Testing, development | No — data lost on restart |
| `PostgresSaver` | Production | Yes |
