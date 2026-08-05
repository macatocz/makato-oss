---
name: langgraph-reflexion
description: >-
  INVOKE when building iterative self-improvement agents with human feedback
  and persistent lessons in LangGraph. Covers the reflexion loop
  (act-tools-feedback-reflect-finalize), unique_lessons_reducer deduplication
  semantics, thread_id isolation for lesson scope, Postgres-backed lesson
  persistence, lesson pruning strategy, convergence detection heuristics, and
  testing the loop with InMemorySaver and scripted feedback stubs.
  Keywords: reflexion, self-improving agent, lessons, iterative feedback,
  lesson reducer, attempt cap, convergence, human-in-the-loop loop,
  unique_lessons_reducer, lesson pruning, InMemorySaver test. Python-only.
version: "1.3.0"
metadata:
  Authors: makato-langgraph contributors
  last_updated: "2026-08-05"
argument-hint: "[task description] [--max-attempts N] [--thread-id ID]"
---
<overview>
Reflexion is an iterative improvement pattern where an agent acts, receives human feedback, reflects to create reusable lessons, and retries guided by those lessons. Lessons persist across runs via a checkpointer, enabling domain-specific competence bootstrapping.
</overview>

**MANDATORY: Load `langgraph-persistence`** before setting up any checkpointer for this skill. It covers PostgresSaver connection setup, InMemorySaver testing patterns, and the `.setup()` DDL call lifecycle.

**Do NOT Load** `langgraph-persistence` if you only need to run the reflexion graph with no persistence (lessons lost at process exit, acceptable for one-off debugging).

---

## When to Use

<reflexion-design>

| Use Reflexion When                                | Use Simpler Patterns When   |
| ------------------------------------------------- | --------------------------- |
| Tasks require iterative quality improvement       | One-shot answers suffice    |
| Human feedback should guide future agent behavior | No human-in-the-loop needed |
| Domain-specific competence needs bootstrapping    | General-purpose tasks       |
| Lessons from past runs should persist             | Stateless execution is fine |

</reflexion-design>

---

## Expert Decision Guide

### Tuning max_attempts

`max_attempts` is the only hard ceiling on token spend. Choose it based on expected feedback quality, not optimism:

| Task Complexity      | Typical Feedback Quality  | Recommended max_attempts |
| -------------------- | ------------------------- | ------------------------ |
| Well-defined, narrow | Precise, actionable       | 2–3                      |
| Open-ended, creative | Subjective, iterative     | 4–6                      |
| Adversarial / QA     | Always picky              | 3 (with escalation path) |

Never use `max_attempts > 6` without a convergence check (see below) — past that threshold, repeated lessons stop improving quality and just grow the context window.

### Lesson Pruning Strategy

The `unique_lessons_reducer` deduplicates by exact stripped text, but semantic duplicates ("Always cite sources." / "Cite sources when uncertain.") survive deduplication and accumulate silently. Lessons degrade in two ways:

1. **Quantity dilution**: past ~15–20 lessons, act() system prompt grows long enough to push task instructions out of the model's effective attention window.
2. **Contradiction accumulation**: older lessons from different task contexts conflict with newer ones; the model averages them, reducing quality.

Prune when `len(state["lessons"]) > 15`:
```python
def prune_lessons(lessons: list[str], keep: int = 10) -> list[str]:
    """Keep the most recent lessons. Older lessons from different contexts
    corrupt newer, more task-specific ones — recency beats completeness here."""
    return lessons[-keep:]
```
Call `prune_lessons` at the start of `act()` before injecting into the system prompt. Do not prune the stored state — only prune what you feed to the LLM.

### Convergence Detection

Reflexion can get stuck in cycles where feedback is repetitive but approval never arrives. Detect this in `route_after_reflect`:

```python
def route_after_reflect(state):
    attempt = int(state.get("attempt", 0))
    if attempt >= max_attempts:
        return "finalize"
    # Convergence check: if last 2 feedback notes are identical, the human
    # is not providing actionable signal — force finalize to avoid waste
    history = state.get("history", [])
    if len(history) >= 2:
        last_two_notes = [h.get("notes", "") for h in history[-2:]]
        if last_two_notes[0] and last_two_notes[0] == last_two_notes[1]:
            return "finalize"  # Stuck: identical feedback twice → stop
    return "act"
```

### thread_id Scope: When to Isolate vs Share

thread_id determines which lessons the agent inherits. Getting scope wrong is the most common production bug:

| Scenario                             | thread_id Strategy                         | Why                                                    |
| ------------------------------------ | ------------------------------------------ | ------------------------------------------------------ |
| Single user, single task session     | `f"user-{user_id}-session-{session_id}"`   | Lessons stay within one task's feedback loop           |
| Same user, different task types      | New thread_id per task type                | Code-review lessons corrupt writing-assist behavior    |
| Multi-tenant (different users)       | Always include user_id in thread_id        | Lessons bleed across users if thread is shared         |
| Cross-session learning (desired)     | Store (not checkpointer) for lesson replay | Checkpointer thread replay is order-sensitive; Store is not |

---

## Reflexion Loop

<reflexion-loop-diagram>

```
START -> act -> (has tool calls?) -> tools -> feedback -> (approved?) -> finalize -> END
                      |                                       |
                      +-> feedback -> reflect -> (retry?) -> act
                                                    |
                                                    +-> finalize -> END
```

Nodes:

1. **act** — LLM with tools, guided by accumulated lessons
2. **tools** — Execute tool calls (ToolNode)
3. **feedback** — Human approves or provides improvement notes
4. **reflect** — Convert feedback into compact, reusable lessons
5. **finalize** — Synthesize final answer from conversation and lessons

</reflexion-loop-diagram>

---

## State Definition

<ex-reflexion-state>
<python>
Reflexion state with message history, lessons (custom reducer), and attempt tracking.
`unique_lessons_reducer` is defined in the **Unique Lessons Reducer** section below — use
that annotated copy, not inline here.
```python
import operator
from typing import Annotated, Any, TypedDict
from langchain_core.messages import BaseMessage

# unique_lessons_reducer defined below — see "Unique Lessons Reducer" section
class ReflexionState(TypedDict, total=False):
    messages: Annotated[list[BaseMessage], operator.add]   # Chat history (accumulates)
    attempt: int                                            # Current iteration
    lessons: Annotated[list[str], unique_lessons_reducer]   # Persisted lessons (deduplicated)
    feedback: str                                           # Human feedback text
    approved: bool                                          # Human approval flag
    history: Annotated[list[dict[str, Any]], operator.add]  # Audit trail
    final: str                                              # Final synthesized answer
```
</python>
</ex-reflexion-state>

---

## Unique Lessons Reducer

<ex-unique-lessons-reducer>
<python>
Custom reducer that deduplicates lessons while preserving insertion order.
```python
def unique_lessons_reducer(left: list[str] | None, right: list[str] | None) -> list[str]:
    """Merge lessons uniquely, preserving order.

    - Keeps existing lessons from `left` in their original order
    - Appends only new lessons from `right` not already present
    - Compares by stripped text to avoid whitespace duplicates
    - Does NOT deduplicate semantic variants ("Cite sources." vs "Always cite sources.")
      — caller must prune_lessons() before injecting into act() system prompt
    """
    left_list = left or []
    right_list = right or []
    seen = set()
    result: list[str] = []
    for lesson in left_list + right_list:
        key = (lesson or "").strip()
        if key and key not in seen:
            seen.add(key)
            result.append(key)
    return result
```

</python>
</ex-unique-lessons-reducer>

---

## Graph Construction

**MANDATORY: Load `references/graph-boilerplate.md`** when the user asks "how do I wire the graph", "add_node / add_edge", "compile with checkpointer", or is assembling the StateGraph for the first time.

<ex-reflexion-graph>
<python>
Build the reflexion graph with act-tools-feedback-reflect-finalize loop.
```python
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.output_parsers import JsonOutputParser
from langgraph.graph import StateGraph, START, END
from langgraph.prebuilt import ToolNode
from langchain_openai import ChatOpenAI

def build_reflexion_graph(tools, max_attempts: int = 3, checkpointer=None):
    parser = JsonOutputParser()

    def act(state: ReflexionState) -> dict:
        """LLM acts guided by accumulated lessons."""
        attempt = int(state.get("attempt", 0)) + 1
        lessons = prune_lessons(state.get("lessons", []) or [])  # prune before injecting
        lessons_text = "\n".join(f"- {l}" for l in lessons) if lessons else "(none)"

        llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
        llm_with_tools = llm.bind_tools(tools)

        system = SystemMessage(content=(
            "You are a careful, tool-using assistant.\n"
            f"LESSONS:\n{lessons_text}\n\n"
            "Use lessons to avoid repeating past mistakes."
        ))
        convo = [system] + (state.get("messages", []) or [])
        response = llm_with_tools.invoke(convo)
        return {"messages": [response], "attempt": attempt}

    def feedback(state: ReflexionState) -> dict:
        """Collect human approval and improvement notes.

        PRODUCTION: Replace this node with the interrupt/resume pattern from
        langgraph-human-in-the-loop. input() blocks the event loop and cannot
        be used in async graphs, web servers, or any multi-user context.

        MANDATORY: Load langgraph-human-in-the-loop when replacing this node
        for production deployment.
        """
        # DEV/TESTING ONLY — replace with interrupt() for production
        approved = input("Approve? (y/n): ").strip().lower().startswith("y")
        notes = "" if approved else input("What should improve? ").strip()
        feedback_msg = HumanMessage(content=f"FEEDBACK: approved={approved}; notes={notes}")
        return {
            "approved": approved,
            "feedback": notes,
            "messages": [feedback_msg],
            "history": [{"attempt": state.get("attempt", 1), "approved": approved, "notes": notes}],
        }

    def reflect(state: ReflexionState) -> dict:
        """Convert feedback into compact, reusable lessons."""
        llm = ChatOpenAI(model="gpt-4.1", temperature=0.0)
        system = SystemMessage(content=(
            "Convert feedback into compact lessons (short imperatives).\n"
            "Return JSON: {\"lessons\": string[], \"should_retry\": boolean}"
        ))
        user = HumanMessage(content=f"Feedback: {state.get('feedback', '')}")
        response = llm.invoke([system, user])
        try:
            data = parser.parse(response.content)
            new_lessons = [l for l in data.get("lessons", []) if isinstance(l, str) and l.strip()]
        except Exception:
            new_lessons = ["Verify facts before answering.", "Prefer concise structured output."]
        return {"lessons": new_lessons}

    def finalize(state: ReflexionState) -> dict:
        """Synthesize final answer from conversation and lessons."""
        llm = ChatOpenAI(model="gpt-4.1", temperature=0.2)
        system = SystemMessage(content="Produce the final answer. Be clear and concise.")
        convo = [system] + (state.get("messages", []) or [])
        response = llm.invoke(convo)
        return {"final": response.content.strip(), "messages": [response]}

    # See references/graph-boilerplate.md for add_node/add_edge/compile wiring
    builder = StateGraph(ReflexionState)
    builder.add_node("act", act)
    builder.add_node("tools", ToolNode(tools))
    builder.add_node("feedback", feedback)
    builder.add_node("reflect", reflect)
    builder.add_node("finalize", finalize)

    builder.add_edge(START, "act")
    builder.add_conditional_edges("act", lambda s: "tools" if (s.get("messages") or [None])[-1] and getattr((s.get("messages") or [None])[-1], "tool_calls", None) else "feedback", {"tools": "tools", "feedback": "feedback"})
    builder.add_edge("tools", "feedback")
    builder.add_conditional_edges("feedback", lambda s: "finalize" if s.get("approved") else "reflect", {"finalize": "finalize", "reflect": "reflect"})
    builder.add_conditional_edges("reflect", lambda s: "finalize" if int(s.get("attempt", 0)) >= max_attempts or (len(s.get("history", [])) >= 2 and s["history"][-1].get("notes") == s["history"][-2].get("notes") and s["history"][-1].get("notes")) else "act", {"finalize": "finalize", "act": "act"})
    builder.add_edge("finalize", END)

    return builder.compile(checkpointer=checkpointer) if checkpointer else builder.compile()
```
</python>
</ex-reflexion-graph>

---

## Persistent Lessons with PostgreSQL

**MANDATORY: Load `langgraph-persistence`** before wiring a PostgresSaver — it covers `.setup()` DDL lifecycle, connection pooling, and AsyncPostgresSaver for async graphs.

<ex-reflexion-persistence>
<python>
Use PostgresSaver so lessons persist across process restarts. Use InMemorySaver for tests.
```python
from langgraph.checkpoint.postgres import PostgresSaver
from langchain_core.messages import HumanMessage

def run_reflexion(prompt: str, conn_string: str = "postgresql://user:pass@localhost/db", thread_id: str = "default"):
    """Run reflexion agent with persistent lessons."""
    with PostgresSaver.from_conn_string(conn_string) as checkpointer:
        checkpointer.setup()  # DDL only — call once at startup, not per-request
        app = build_reflexion_graph(
            tools=my_tools,
            max_attempts=3,
            checkpointer=checkpointer,
        )
        config = {"configurable": {"thread_id": thread_id}}
        initial = {"messages": [HumanMessage(content=prompt)], "attempt": 0, "lessons": [], "history": []}
        result = app.invoke(initial, config=config)
        return result

# First run: agent learns lessons
result1 = run_reflexion("Analyze this data", thread_id="session-1")

# Second run (same thread): agent starts with previously learned lessons
result2 = run_reflexion("Analyze different data", thread_id="session-1")
```

</python>
</ex-reflexion-persistence>

---

## Testing

**MANDATORY: Load `references/testing.md`** when the user asks "how do I test", "write unit tests", "mock feedback", "InMemorySaver test", or "test without a database".

Key points:
- The `feedback()` node's `input()` call blocks in any test runner. Replace it with `make_scripted_feedback(responses)` from `references/testing.md`.
- Always use unique `thread_id` per test case even with InMemorySaver — shared thread_ids cause lesson state bleed between tests.
- Use `InMemorySaver` for all unit/CI tests. Reserve `PostgresSaver` for integration smoke tests only.
- `FakeListChatModel` from `langchain_core.language_models.fake` lets you test reflect() and act() without calling the OpenAI API.

Three test scenarios to always cover:
1. Immediate approval (1 attempt, lessons unchanged)
2. One rejection then approval (lessons accumulate, reflect() fires)
3. Convergence detection (identical feedback twice stops the loop before max_attempts)

---

## Anti-patterns

Each item includes the non-obvious failure mode that only experience reveals.

**NEVER reuse the same thread_id across unrelated task types.**
Why: `unique_lessons_reducer` accumulates lessons from every run on that thread. Code-review lessons ("Always flag missing type hints") bleed into writing-assist runs and vice versa. The corruption is silent — the agent applies off-topic lessons confidently, and the degradation only shows up as subtle quality drift across sessions, not as an obvious error.

**NEVER use `input()` in the feedback() node outside a local REPL session.**
Why: `input()` blocks the calling thread, making the graph incompatible with async event loops (FastAPI, asyncio), multi-user web servers, and test runners that timeout blocking calls. It also cannot be interrupted cleanly — a hung `input()` call holds the thread and prevents graceful shutdown. For production, replace with the `interrupt()`/`Command` pattern from `langgraph-human-in-the-loop`. For tests, use `make_scripted_feedback` from `references/testing.md`.

**NEVER store verbose multi-sentence lessons.**
Why: act()'s system prompt includes every lesson as a bullet. Lessons exceeding ~15 words dilute the signal-to-noise ratio in the system prompt. In practice, a lesson like "When the user asks about data analysis, make sure to verify all facts and provide comprehensive explanations with multiple examples..." takes up as much attention budget as three short imperatives. Use short imperatives: "Verify facts before answering."

**NEVER skip the max_attempts guard in route_after_reflect.**
Why: LangGraph's conditional edges have no built-in termination condition — the graph runs forever until a node returns an edge that leads to END. A human who never approves, or a feedback function that always returns `approved=False`, will loop indefinitely burning tokens with no visible signal until the process is killed or the API budget runs out.

**NEVER call `checkpointer.setup()` on every request in production.**
Why: `setup()` issues `CREATE TABLE IF NOT EXISTS` DDL. Even though it's idempotent, DDL takes a table lock in most Postgres configurations. At high request volume, concurrent `setup()` calls queue against that lock and add measurable latency. Call `setup()` once at application startup (or as a migration step), not inside the per-request execution path.

**NEVER let the `lessons` list grow unbounded across many runs on the same thread.**
Why: `unique_lessons_reducer` deduplicates exact-match text but not semantic variants. A thread that has accumulated 30+ lessons will inject a system prompt section longer than many tasks' instructions. Past ~20 lessons, newer more-specific lessons compete for attention against older general ones; the model averages conflicting signals instead of prioritizing recency. Prune before injecting into act() (see `prune_lessons` in Expert Decision Guide).

**NEVER parse reflect()'s JSON output without a fallback.**
Why: LLMs occasionally return markdown code fences, trailing commas, or prose explanations alongside the JSON. `JsonOutputParser` raises on all of these. Without a `try/except`, a single malformed reflect output crashes the entire reflexion run — including discarding all lessons learned in earlier attempts. The fallback ensures the loop continues with a generic lesson rather than failing completely.

---

## Code Fix Examples

<fix-lesson-format>
<python>
Lessons should be short imperatives, not paragraphs.
```python
# WRONG: Verbose lessons waste context window
lessons = ["When the user asks about data analysis, make sure to verify all facts and provide comprehensive explanations with multiple examples..."]

# CORRECT: Short imperatives that guide behavior
lessons = ["Verify facts before answering.", "Prefer concise structured output.", "Cite sources when uncertain."]
```
</python>
</fix-lesson-format>

<fix-reflect-json-parsing>
<python>
Always wrap lesson extraction in try/except with fallback.
```python
# WRONG: Crashes if LLM returns malformed JSON
data = parser.parse(response.content)
new_lessons = data["lessons"]

# CORRECT: Fallback to generic lessons on parse failure
try:
    data = parser.parse(response.content)
    new_lessons = [l for l in data.get("lessons", []) if isinstance(l, str) and l.strip()]
except Exception:
    new_lessons = ["Verify facts before answering.", "Prefer concise structured output."]
```
</python>
</fix-reflect-json-parsing>

<boundaries>
### What This Skill Does NOT Cover

- Use reflexion for simple one-shot tasks — it adds unnecessary complexity
- Async reflexion graphs — use `AsyncPostgresSaver` and `async def` nodes (see `langgraph-persistence`)
- Store-based cross-thread lesson sharing — `langgraph-persistence` covers the Store API
- Production feedback() node implementation — load `langgraph-human-in-the-loop` for the interrupt/resume pattern
</boundaries>
