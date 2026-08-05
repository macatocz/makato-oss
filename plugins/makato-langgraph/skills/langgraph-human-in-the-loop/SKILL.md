---
name: langgraph-human-in-the-loop
description: >-
  INVOKE THIS SKILL when implementing human-in-the-loop patterns, pausing for
  approval, breakpoints, or state editing in LangGraph. Covers interrupt(),
  Command(resume=...), interrupt_before breakpoints, update_state,
  approval/validation workflows, and idempotency. Python-only.
version: "1.1.0"
metadata:
  authors: ["makato-langgraph"]
  last_updated: "2026-08-05"
argument-hint: "[pattern: interrupt | breakpoint | state-edit | multi-interrupt | validation-loop]"
---

## Decision tree — pick your HITL pattern

```
Need to pause execution?
├── YES: Is the pause conditional (only some runs)?
│   ├── YES → use interrupt()         (inline, inside node function)
│   └── NO  → use interrupt_before    (compile-time breakpoint, always fires)
│               LOAD references/breakpoints.md
│
├── Do you need to edit state between runs (correct agent decisions)?
│   └── YES → use update_state
│               LOAD references/state-editing.md
│
└── Multiple parallel branches each interrupt?
    └── YES → resume with Command(resume={id: value, ...}) map
               see ## Multiple Interrupts below
```

---

## Requirements

Three things are required for interrupts to work:

1. **Checkpointer** — compile with `checkpointer=InMemorySaver()` (dev) or `PostgresSaver` (prod)
2. **Thread ID** — pass `{"configurable": {"thread_id": "..."}}` to every `invoke`/`stream` call
3. **JSON-serializable payload** — the value passed to `interrupt()` must be JSON-serializable

---

## Anti-patterns

**NEVER call db.insert() or any non-idempotent operation before interrupt()**
WHY: When the graph resumes, the node restarts from the beginning — every line before `interrupt()` re-runs. An `INSERT` before `interrupt()` creates a duplicate record on every resume attempt. Use upsert / check-before-create, or move the write after `interrupt()`.

**NEVER append to a list before interrupt()**
WHY: Same re-execution mechanic. `list.append(item)` before `interrupt()` adds the same item every time the thread resumes, producing duplicates in state.

**NEVER pass Command(update=...) as the top-level input to invoke()/stream()**
WHY: `Command(update=...)` is designed to be returned *from* a node, not passed as an *invoke* argument. When passed as invoke input it resumes from the latest checkpoint but the update is applied at the wrong phase — the graph appears stuck, spinning without progress. Only `Command(resume=...)` is valid as invoke input.

**NEVER pass a plain dict to invoke() to resume an interrupted graph**
WHY: Passing a dict starts a *new* run on the same thread_id — it does not resume the paused interrupt. The paused state is lost (overwritten by the new run's initial state). Resume always requires `Command(resume=value)`.

**NEVER skip the checkpointer in subgraph deployments**
WHY: If a parent graph has a checkpointer but a subgraph does not, `interrupt()` inside the subgraph raises at runtime. The subgraph must also be compiled with the same (or a compatible) checkpointer.

**NEVER assume subgraph interrupt() re-executes only the subgraph node**
WHY: Resuming re-executes BOTH the parent node (which called subgraph.invoke()) AND the subgraph node that called interrupt(). Any non-idempotent code in the parent node before the subgraph call is also duplicated — a double re-execution trap that is easy to miss.

**NEVER resume multiple parallel interrupts with separate invoke() calls**
WHY: Each `invoke(Command(resume=single_value), config)` tries to resume all pending interrupts with the same value. The second parallel interrupt gets the wrong value (the same one as the first). Collect all pending interrupt IDs from `result["__interrupt__"]` and resume with a single `Command(resume={id: value, ...})` map.

---

## Basic Interrupt + Resume

`interrupt(value)` pauses the graph. The value surfaces in the result under `__interrupt__`. `Command(resume=value)` resumes — the resume value becomes the return value of `interrupt()`.

**Critical**: when the graph resumes, the node restarts from the **beginning** — all code before `interrupt()` re-runs.

```python
from langgraph.types import interrupt, Command
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import StateGraph, START, END
from typing_extensions import TypedDict

class State(TypedDict):
    approved: bool

def approval_node(state: State):
    # Pause and ask for approval
    approved = interrupt("Do you approve this action?")
    # When resumed, Command(resume=...) returns that value here
    return {"approved": approved}

checkpointer = InMemorySaver()
graph = (
    StateGraph(State)
    .add_node("approval", approval_node)
    .add_edge(START, "approval")
    .add_edge("approval", END)
    .compile(checkpointer=checkpointer)
)

config = {"configurable": {"thread_id": "thread-1"}}

# Initial run — hits interrupt and pauses
result = graph.invoke({"approved": False}, config)
print(result["__interrupt__"])
# [Interrupt(value='Do you approve this action?')]

# Resume with the human's response
result = graph.invoke(Command(resume=True), config)
print(result["approved"])  # True
```

---

## Approval Workflow

A common pattern: interrupt to show a draft, then route based on the human's decision.

```python
from langgraph.types import interrupt, Command
from langgraph.graph import StateGraph, START, END
from typing import Literal
from typing_extensions import TypedDict

class EmailAgentState(TypedDict):
    email_content: str
    draft_response: str
    classification: dict

def human_review(state: EmailAgentState) -> Command[Literal["send_reply", "__end__"]]:
    """Pause for human review using interrupt and route based on decision."""
    # interrupt() must come first — any code before it will re-run on resume
    human_decision = interrupt({
        "draft_response": state.get("draft_response", ""),
        "urgency": state.get("classification", {}).get("urgency"),
        "action": "Please review and approve/edit this response"
    })

    if human_decision.get("approved"):
        return Command(
            update={"draft_response": human_decision.get("edited_response", state.get("draft_response", ""))},
            goto="send_reply"
        )
    else:
        return Command(update={}, goto=END)
```

---

## Validation Loop

Use `interrupt()` in a loop to validate human input and re-prompt if invalid. Each `Command(resume=...)` call provides the next answer.

```python
from langgraph.types import interrupt

def get_age_node(state):
    prompt = "What is your age?"

    while True:
        answer = interrupt(prompt)
        # Validate the input
        if isinstance(answer, int) and answer > 0:
            break
        else:
            prompt = f"'{answer}' is not a valid age. Please enter a positive number."

    return {"age": answer}
```

```python
config = {"configurable": {"thread_id": "form-1"}}
first = graph.invoke({"age": None}, config)
# __interrupt__: "What is your age?"

retry = graph.invoke(Command(resume="thirty"), config)
# __interrupt__: "'thirty' is not a valid age..."

final = graph.invoke(Command(resume=30), config)
print(final["age"])  # 30
```

---

## Breakpoints (interrupt_before)

MANDATORY: Load `references/breakpoints.md` when the user asks about `interrupt_before`, `interrupt_after`, always-pause-before-node, or compile-time breakpoints.

Do NOT Load `references/breakpoints.md` for inline `interrupt()` patterns — those are covered in this file.

Quick summary: breakpoints are compile-time declarations that pause before/after a node without code changes inside it — ideal for `ToolNode` and operator consoles. See `references/breakpoints.md` for the full inspect-modify-resume pattern, `as_node` usage, and the resume-with-None mechanic.

```python
graph = builder.compile(
    checkpointer=MemorySaver(),
    interrupt_before=["tools"]
)

config = {"configurable": {"thread_id": "approval-1"}}

for chunk in graph.stream({"messages": [HumanMessage(content="Calculate 15 * 23")]}, config):
    pass

state = graph.get_state(config)
print(f"Stopped before: {state.next}")    # ('tools',)

# Resume after human approval — pass None, not a new dict
for chunk in graph.stream(None, config):
    pass
```

---

## State Editing

MANDATORY: Load `references/state-editing.md` when the user asks about `update_state`, `get_state`, `as_node`, overriding state between runs, time-travel, or injecting a synthetic node result.

Do NOT Load `references/state-editing.md` for basic interrupt/resume flows — load only when state inspection or mutation is explicitly needed.

Quick summary: `update_state(config, values, as_node=None)` writes through reducers — appending fields append, scalar fields overwrite. Use `as_node` to advance `state.next` past a node without running it. See `references/state-editing.md` for reducer behavior, time-travel rollback, and the ghost-checkpoint trap.

```python
# Modify state before resuming from a breakpoint
graph.update_state(config, {"radius": 5.0})  # Correct a value
result = graph.invoke(None, config)           # Resume
```

Note: `update_state` passes through reducers. Use `Overwrite()` in your schema to replace instead of merge — see `references/state-editing.md` and the persistence skill.

---

## Multiple Interrupts

When parallel branches each call `interrupt()`, resume all of them in a single invocation by mapping each interrupt ID to its resume value.

```python
from typing import Annotated, TypedDict
import operator
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import START, END, StateGraph
from langgraph.types import Command, interrupt

class State(TypedDict):
    vals: Annotated[list[str], operator.add]

def node_a(state):
    answer = interrupt("question_a")
    return {"vals": [f"a:{answer}"]}

def node_b(state):
    answer = interrupt("question_b")
    return {"vals": [f"b:{answer}"]}

graph = (
    StateGraph(State)
    .add_node("a", node_a)
    .add_node("b", node_b)
    .add_edge(START, "a")
    .add_edge(START, "b")
    .add_edge("a", END)
    .add_edge("b", END)
    .compile(checkpointer=InMemorySaver())
)

config = {"configurable": {"thread_id": "1"}}

# Both parallel nodes hit interrupt() and pause
result = graph.invoke({"vals": []}, config)

# Resume all pending interrupts at once using a map of id -> value
resume_map = {
    i.id: f"answer for {i.value}"
    for i in result["__interrupt__"]
}
result = graph.invoke(Command(resume=resume_map), config)
# result["vals"] = ["a:answer for question_a", "b:answer for question_b"]
```

User-fixable errors use `interrupt()` to pause and collect missing data — that's the pattern covered by this skill. For the full 4-tier error handling strategy (RetryPolicy, Command error loops, etc.), see the **fundamentals** skill.

---

## Side Effects Before Interrupt Must Be Idempotent

When the graph resumes, the node restarts from the **beginning** — ALL code before `interrupt()` re-runs. In subgraphs, BOTH the parent node and the subgraph node re-execute.

**Do:**
- Use **upsert** (not insert) operations before `interrupt()`
- Use **check-before-create** patterns
- Place side effects **after** `interrupt()` when possible
- Separate side effects into their own nodes

**Don't:**
- Create new records before `interrupt()` — duplicates on each resume
- Append to lists before `interrupt()` — duplicate entries on each resume

```python
# GOOD: Upsert is idempotent — safe before interrupt
def node_a(state: State):
    db.upsert_user(user_id=state["user_id"], status="pending_approval")
    approved = interrupt("Approve this change?")
    return {"approved": approved}

# GOOD: Side effect AFTER interrupt — only runs once
def node_a(state: State):
    approved = interrupt("Approve this change?")
    if approved:
        db.create_audit_log(user_id=state["user_id"], action="approved")
    return {"approved": approved}

# BAD: Insert creates duplicates on each resume!
def node_a(state: State):
    audit_id = db.create_audit_log({  # Runs again on resume!
        "user_id": state["user_id"],
        "action": "pending_approval",
    })
    approved = interrupt("Approve this change?")
    return {"approved": approved}
```

### Subgraph re-execution on resume

When a subgraph contains an `interrupt()`, resuming re-executes BOTH the parent node (that invoked the subgraph) AND the subgraph node (that called `interrupt()`):

```python
def node_in_parent_graph(state: State):
    some_code()  # <-- Re-executes on resume
    subgraph_result = subgraph.invoke(some_input)
    # ...

def node_in_subgraph(state: State):
    some_other_code()  # <-- Also re-executes on resume
    result = interrupt("What's your name?")
    # ...
```

---

## Fixes

**Checkpointer required for interrupt functionality:**

```python
# WRONG
graph = builder.compile()

# CORRECT
graph = builder.compile(checkpointer=InMemorySaver())
```

**Use Command to resume from an interrupt (regular dict restarts graph):**

```python
# WRONG — starts a new run, overwrites paused state
graph.invoke({"resume_data": "approve"}, config)

# CORRECT
graph.invoke(Command(resume="approve"), config)
```

**Command(resume=...) is the only Command pattern valid as invoke() input:**

```python
# WRONG — Command(update=...) as invoke input causes stuck graph
graph.invoke(Command(update={"field": "value"}), config)

# CORRECT — return Command(update=...) from inside a node, never pass as invoke input
def my_node(state):
    return Command(update={"field": "value"}, goto="next_node")
```
