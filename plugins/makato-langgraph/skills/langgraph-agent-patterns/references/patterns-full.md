# Full Pattern Implementations

Complete, runnable code examples for every agent pattern. Load this reference when you need a
copy-paste starting point for an implementation.

---

## MANDATORY load trigger

Load when the user says any of:
- "show me the full example"
- "complete working implementation"
- "copy-paste / runnable code for [pattern]"
- "boilerplate for [minimal | multi-step | conditional | react] agent"

## Do NOT Load

Do NOT load for understanding pattern structure or debugging — the SKILL.md body covers the
non-obvious structural choices. Load only when a complete implementation template is needed.

---

## Minimal Single-Node Agent

```python
from typing import Any, TypedDict
from langchain_core.messages import SystemMessage, HumanMessage
from langchain_core.output_parsers import JsonOutputParser
from langgraph.graph import StateGraph, END
from langchain_openai import ChatOpenAI

class State(TypedDict, total=False):
    prompt: str
    result: dict[str, Any]

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
parser = JsonOutputParser()

def call_model(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content="Respond with STRICT JSON. No backticks.")
    user = HumanMessage(content=state.get("prompt", ""))
    response = llm.invoke([system, user])
    return {"result": parser.parse(response.content)}

graph = StateGraph(State)
graph.add_node("call_model", call_model)
graph.set_entry_point("call_model")
graph.add_edge("call_model", END)
app = graph.compile()

result = app.invoke({"prompt": "Return JSON with 'answer' and 'confidence' about: capital of France?"})
```

---

## Multi-Step Planning

```python
from typing import Any, TypedDict
from langchain_core.messages import SystemMessage, HumanMessage
from langchain_core.output_parsers import JsonOutputParser
from langgraph.graph import StateGraph, END
from langchain_openai import ChatOpenAI

class State(TypedDict, total=False):
    question: str
    plan: dict[str, Any]
    final: dict[str, Any]

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
parser = JsonOutputParser()

def plan_node(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content='Decompose the question into steps. Output STRICT JSON: {"steps": [...], "assumptions": [...]}')
    user = HumanMessage(content=f"Question: {state.get('question', '')}")
    response = llm.invoke([system, user])
    return {"plan": parser.parse(response.content)}

def answer_node(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content='Execute the plan step by step. Output STRICT JSON: {"answer": string, "used_steps": [...]}')
    user = HumanMessage(content=f"Question: {state.get('question', '')}. Plan: {state.get('plan', {})}")
    response = llm.invoke([system, user])
    return {"final": parser.parse(response.content)}

graph = StateGraph(State)
graph.add_node("plan", plan_node)
graph.add_node("answer", answer_node)
graph.set_entry_point("plan")
graph.add_edge("plan", "answer")
graph.add_edge("answer", END)
app = graph.compile()
```

---

## Conditional Branching

```python
from typing import Any, TypedDict
from langchain_core.messages import SystemMessage, HumanMessage
from langchain_core.output_parsers import JsonOutputParser
from langgraph.graph import StateGraph, END
from langchain_openai import ChatOpenAI

class State(TypedDict, total=False):
    input: str
    intent: str
    result: dict[str, Any]

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
parser = JsonOutputParser()

def classify(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content='Classify as "informational" or "creative". Output JSON: {"intent": <value>}')
    user = HumanMessage(content=state.get("input", ""))
    response = llm.invoke([system, user])
    return {"intent": parser.parse(response.content).get("intent")}

def informational(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content='Provide factual info. Output JSON: {"answer": string, "style": "informational"}')
    user = HumanMessage(content=state.get("input", ""))
    return {"result": parser.parse(llm.invoke([system, user]).content)}

def creative(state: dict[str, Any]) -> dict[str, Any]:
    system = SystemMessage(content='Respond creatively. Output JSON: {"answer": string, "style": "creative"}')
    user = HumanMessage(content=state.get("input", ""))
    return {"result": parser.parse(llm.invoke([system, user]).content)}

def route(state: dict[str, Any]) -> str:
    intent = state.get("intent", "").lower().strip()
    return "informational" if intent == "informational" else "creative"  # default fallback

graph = StateGraph(State)
graph.add_node("classify", classify)
graph.add_node("informational", informational)
graph.add_node("creative", creative)
graph.set_entry_point("classify")
graph.add_conditional_edges("classify", route, {"informational": "informational", "creative": "creative"})
graph.add_edge("informational", END)
graph.add_edge("creative", END)
app = graph.compile()
```

---

## ReAct — Prebuilt (ToolNode + tools_condition)

```python
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import MessagesState, StateGraph, START
from langgraph.prebuilt import ToolNode, tools_condition
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool

@tool
def calculator(expression: str) -> str:
    """Evaluate a math expression."""
    return str(eval(expression))

@tool
def search(query: str) -> str:
    """Search for information."""
    return f"Search results for: {query}"

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
tools = [calculator, search]
llm_with_tools = llm.bind_tools(tools)

system_message = SystemMessage(content="You are a helpful assistant. Use tools when needed.")

def assistant(state: MessagesState):
    response = llm_with_tools.invoke([system_message] + state["messages"])
    return {"messages": [response]}

graph = StateGraph(MessagesState)
graph.add_node("assistant", assistant)
graph.add_node("tools", ToolNode(tools=tools, handle_tool_errors=True))
graph.add_edge(START, "assistant")
graph.add_conditional_edges("assistant", tools_condition)
graph.add_edge("tools", "assistant")
app = graph.compile(recursion_limit=25)

result = app.invoke({"messages": [HumanMessage(content="What is 12 * 7?")]})
```

---

## ReAct — Manual Routing

```python
from langchain_core.messages import HumanMessage, SystemMessage, ToolMessage
from langgraph.graph import MessagesState, StateGraph, START, END
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
tools = [calculator, search]  # @tool-decorated functions defined at module level
tools_by_name = {t.name: t for t in tools}
llm_with_tools = llm.bind_tools(tools)

system_message = SystemMessage(content="You are a helpful assistant.")

def assistant(state: MessagesState):
    return {"messages": [llm_with_tools.invoke([system_message] + state["messages"])]}

def tool_executor(state: MessagesState):
    """Execute ALL tool calls — LLMs can emit multiple in one response."""
    results = []
    for call in state["messages"][-1].tool_calls:
        tool_fn = tools_by_name[call["name"]]
        result = tool_fn.invoke(call["args"])
        results.append(ToolMessage(content=str(result), tool_call_id=call["id"]))
    return {"messages": results}

def should_continue(state: MessagesState) -> str:
    last = state["messages"][-1]
    calls = getattr(last, "tool_calls", None) or []   # handle None and [] both
    return "tools" if calls else END

graph = StateGraph(MessagesState)
graph.add_node("assistant", assistant)
graph.add_node("tools", tool_executor)
graph.add_edge(START, "assistant")
graph.add_conditional_edges("assistant", should_continue, {"tools": "tools", END: END})
graph.add_edge("tools", "assistant")
app = graph.compile(recursion_limit=25)
```

---

## MCP Integration — Single Server

```python
import asyncio
import sys
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import MessagesState, StateGraph, START
from langgraph.prebuilt import ToolNode, tools_condition
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from langchain_mcp_adapters.tools import load_mcp_tools
from langchain_openai import ChatOpenAI

async def run_mcp_agent(prompt: str, server_script: str):
    """Run a ReAct agent with MCP-provided tools."""
    server_params = StdioServerParameters(
        command=sys.executable,
        args=[server_script],
    )

    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await load_mcp_tools(session)

            llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
            llm_with_tools = llm.bind_tools(tools)
            system_msg = SystemMessage(content="Use tools when appropriate.")

            def assistant(state: MessagesState):
                return {"messages": [llm_with_tools.invoke([system_msg] + state["messages"])]}

            graph = StateGraph(MessagesState)
            graph.add_node("assistant", assistant)
            graph.add_node("tools", ToolNode(tools=tools, handle_tool_errors=True))
            graph.add_edge(START, "assistant")
            graph.add_conditional_edges("assistant", tools_condition)
            graph.add_edge("tools", "assistant")
            app = graph.compile(recursion_limit=25)

            # MUST use ainvoke — invoke() creates a new event loop, conflicting with this async context
            return await app.ainvoke({"messages": [HumanMessage(content=prompt)]})

# asyncio.run(run_mcp_agent("Compute 12 + 7", "mcp_server.py"))
```
