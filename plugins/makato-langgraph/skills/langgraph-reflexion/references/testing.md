# Testing the Reflexion Graph

MANDATORY: Load this file when the user asks "how do I test", "write unit tests", "mock feedback", "InMemorySaver test", or "test without a database" for a reflexion graph.

Do NOT Load for production persistence setup — that is covered by `langgraph-persistence`.

---

## Core challenge: feedback() contains a human interaction

The `feedback()` node in the main example uses `input()` — a blocking stdin call. Tests must replace this with a deterministic stub that returns pre-scripted approval/rejection sequences.

**NEVER use `input()` in production or in tests.** See Anti-patterns in the main SKILL.md. For production, load `langgraph-human-in-the-loop` (interrupt/resume pattern). For tests, use the stub below.

---

## Stubbing feedback() for unit tests

Replace the `feedback` node with a factory that replays a scripted sequence:

```python
from langchain_core.messages import HumanMessage

def make_scripted_feedback(responses: list[dict]):
    """
    responses: list of {"approved": bool, "notes": str}
    Pops from the front on each call; last entry repeats if list exhausted.
    """
    queue = list(responses)

    def feedback_node(state):
        entry = queue.pop(0) if len(queue) > 1 else queue[0]
        approved = entry.get("approved", False)
        notes = entry.get("notes", "")
        return {
            "approved": approved,
            "feedback": notes,
            "messages": [HumanMessage(content=f"FEEDBACK: approved={approved}; notes={notes}")],
            "history": [{"attempt": state.get("attempt", 1), "approved": approved, "notes": notes}],
        }

    return feedback_node
```

---

## Full unit test with InMemorySaver

```python
import pytest
from langgraph.checkpoint.memory import InMemorySaver
from langchain_core.tools import tool

@tool
def dummy_search(query: str) -> str:
    """Fake search tool for tests."""
    return f"Results for: {query}"

def build_test_graph(feedback_responses: list[dict], max_attempts: int = 3):
    """Build reflexion graph with scripted feedback and in-memory checkpointer."""
    checkpointer = InMemorySaver()

    # Build the graph using build_reflexion_graph but override the feedback node
    # by constructing it manually with the stubbed feedback
    from langchain_core.messages import HumanMessage, SystemMessage
    from langchain_core.output_parsers import JsonOutputParser
    from langgraph.graph import StateGraph, START, END
    from langgraph.prebuilt import ToolNode
    from langchain_openai import ChatOpenAI

    parser = JsonOutputParser()

    def act(state):
        attempt = int(state.get("attempt", 0)) + 1
        lessons = state.get("lessons", []) or []
        lessons_text = "\n".join(f"- {l}" for l in lessons) if lessons else "(none)"
        llm = ChatOpenAI(model="gpt-4.1", temperature=0.0).bind_tools([dummy_search])
        system = SystemMessage(content=f"LESSONS:\n{lessons_text}")
        response = llm.invoke([system] + (state.get("messages", []) or []))
        return {"messages": [response], "attempt": attempt}

    def reflect(state):
        llm = ChatOpenAI(model="gpt-4.1", temperature=0.0)
        system = SystemMessage(content='Return JSON: {"lessons": [], "should_retry": true}')
        user = HumanMessage(content=f"Feedback: {state.get('feedback', '')}")
        response = llm.invoke([system, user])
        try:
            data = parser.parse(response.content)
            new_lessons = [l for l in data.get("lessons", []) if isinstance(l, str) and l.strip()]
        except Exception:
            new_lessons = ["Verify facts before answering."]
        return {"lessons": new_lessons}

    def finalize(state):
        return {"final": "done", "messages": []}

    scripted_feedback = make_scripted_feedback(feedback_responses)

    def route_after_act(state):
        last = (state.get("messages") or [None])[-1]
        return "tools" if last and getattr(last, "tool_calls", None) else "feedback"

    def route_after_feedback(state):
        return "finalize" if state.get("approved") else "reflect"

    def route_after_reflect(state):
        if int(state.get("attempt", 0)) >= max_attempts:
            return "finalize"
        history = state.get("history", [])
        if len(history) >= 2:
            last_two = [h.get("notes", "") for h in history[-2:]]
            if last_two[0] and last_two[0] == last_two[1]:
                return "finalize"
        return "act"

    builder = StateGraph(ReflexionState)
    builder.add_node("act", act)
    builder.add_node("tools", ToolNode([dummy_search]))
    builder.add_node("feedback", scripted_feedback)
    builder.add_node("reflect", reflect)
    builder.add_node("finalize", finalize)
    builder.add_edge(START, "act")
    builder.add_conditional_edges("act", route_after_act, {"tools": "tools", "feedback": "feedback"})
    builder.add_edge("tools", "feedback")
    builder.add_conditional_edges("feedback", route_after_feedback, {"finalize": "finalize", "reflect": "reflect"})
    builder.add_conditional_edges("reflect", route_after_reflect, {"finalize": "finalize", "act": "act"})
    builder.add_edge("finalize", END)
    return builder.compile(checkpointer=checkpointer)


def test_immediate_approval():
    """One attempt, immediately approved — lessons list unchanged."""
    graph = build_test_graph([{"approved": True, "notes": ""}])
    result = graph.invoke(
        {"messages": [HumanMessage(content="Summarize X")], "attempt": 0, "lessons": [], "history": []},
        config={"configurable": {"thread_id": "test-1"}},
    )
    assert result["approved"] is True
    assert result["attempt"] == 1


def test_one_rejection_then_approval():
    """Rejection on attempt 1 triggers reflect + lesson accumulation; approval on attempt 2."""
    graph = build_test_graph([
        {"approved": False, "notes": "Be more concise."},
        {"approved": True, "notes": ""},
    ])
    result = graph.invoke(
        {"messages": [HumanMessage(content="Explain Y")], "attempt": 0, "lessons": [], "history": []},
        config={"configurable": {"thread_id": "test-2"}},
    )
    assert result["approved"] is True
    assert result["attempt"] == 2


def test_convergence_detection():
    """Identical feedback twice → convergence → finalize without reaching max_attempts."""
    graph = build_test_graph(
        [{"approved": False, "notes": "Too long."}, {"approved": False, "notes": "Too long."}],
        max_attempts=5,  # Would not stop at 2 without convergence check
    )
    result = graph.invoke(
        {"messages": [HumanMessage(content="Write Z")], "attempt": 0, "lessons": [], "history": []},
        config={"configurable": {"thread_id": "test-convergence"}},
    )
    # Convergence fired at attempt 2, not at max_attempts=5
    assert result["attempt"] == 2


def test_lesson_persistence_across_runs():
    """Second run on same thread_id inherits lessons from the first run."""
    graph = build_test_graph([{"approved": True, "notes": ""}])
    config = {"configurable": {"thread_id": "lesson-persist"}}
    initial = {"messages": [HumanMessage(content="Run 1")], "attempt": 0, "lessons": ["Be concise."], "history": []}
    result = graph.invoke(initial, config=config)
    # On a second invoke with the same thread_id, lessons from prior run are in state
    result2 = graph.invoke(
        {"messages": [HumanMessage(content="Run 2")], "attempt": 0, "lessons": [], "history": []},
        config=config,
    )
    # Checkpointer replays state from prior run; lessons from run 1 survive
    assert "Be concise." in result2.get("lessons", [])
```

---

## InMemorySaver vs PostgresSaver in tests

| Aspect | InMemorySaver | PostgresSaver |
|--------|---------------|---------------|
| Setup | Zero — no DDL, no connection | Requires a running Postgres instance |
| State lifetime | In-process only | Durable across restarts |
| Thread isolation | Isolated per test process | Shared — tests must use unique thread_ids |
| When to use | All unit and CI tests | Integration / smoke tests only |

**Always use unique `thread_id` values per test case** even with InMemorySaver. Shared thread_ids across tests cause lesson state bleed — a test that seeds lessons will corrupt a later test that expects an empty lessons list.

---

## Mocking the LLM in reflect()

For tests that must not call the OpenAI API, use `langchain_core.language_models.fake.FakeListChatModel`:

```python
from langchain_core.language_models.fake import FakeListChatModel

fake_llm = FakeListChatModel(responses=['{"lessons": ["Be concise."], "should_retry": true}'])
```

Patch `ChatOpenAI` in the reflect node's closure via `unittest.mock.patch` or pass the LLM as a constructor argument to `build_reflexion_graph`.
