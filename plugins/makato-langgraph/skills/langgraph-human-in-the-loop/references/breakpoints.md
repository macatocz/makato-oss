# Breakpoints (interrupt_before / interrupt_after)

MANDATORY: Load this file when the user mentions `interrupt_before`, `interrupt_after`, always-pause-before-node, or compile-time breakpoints.

---

## When to choose breakpoints over interrupt()

Use `interrupt_before` / `interrupt_after` when:
- The pause is **unconditional** — it fires on every graph run at that node
- You do not own the node's source (e.g., `ToolNode` from `langgraph.prebuilt`) so you cannot inject `interrupt()` inside it
- You want to inspect or edit state **before** a node's side effects (interrupt_before) or **after** them (interrupt_after)
- You are building a debugger or operator console — attach dynamically without code changes

Use `interrupt()` (inline) when:
- The pause is **conditional** — only some runs should pause (e.g., high-risk tool calls only)
- You need to surface **custom data** to the human (the interrupt value is richer than the raw state snapshot)
- You need a **validation loop** — re-interrupting until the human provides acceptable input

---

## Compile-time breakpoint setup

```python
graph = builder.compile(
    checkpointer=MemorySaver(),
    interrupt_before=["tools"],     # pause before every execution of "tools" node
    # interrupt_after=["assistant"], # alternative: pause after "assistant"
)
```

`interrupt_before` and `interrupt_after` each accept a list of node names. They stack with `interrupt()` calls — a graph can use both.

---

## Resuming from a breakpoint

After a breakpoint pause, `state.next` shows which node is queued. Resume with `None` (not a `Command`):

```python
# Inspect paused state
state = graph.get_state(config)
print(state.next)   # ('tools',)

# Optionally edit state before resuming
graph.update_state(config, {"radius": 5.0})

# Resume — pass None, not a dict, not Command
for chunk in graph.stream(None, config):
    pass
```

**Critical**: passing `None` after a breakpoint resumes from the checkpoint. Passing a new initial state dict would start a **new** run on the same thread, overwriting history.

---

## inspect-then-modify-then-resume pattern

```python
config = {"configurable": {"thread_id": "approval-1"}}

# Run until breakpoint before "tools"
for chunk in graph.stream({"messages": [HumanMessage(content="Calculate 15 * 23")]}, config):
    pass

state = graph.get_state(config)
last_msg = state.values["messages"][-1]

if hasattr(last_msg, "tool_calls") and last_msg.tool_calls:
    tool_name = last_msg.tool_calls[0]["name"]
    if tool_name in RISKY_TOOLS:
        # Operator denies — inject a refusal message and skip the tools node
        graph.update_state(
            config,
            {"messages": [AIMessage(content="Skipping that tool call.")]},
            as_node="tools",   # pretend tools node ran and returned this
        )
        # Now graph.get_state(config).next == () — nothing queued, run is done
    else:
        # Approve — resume normally
        for chunk in graph.stream(None, config):
            pass
```

`as_node="tools"` makes `update_state` act as if the named node executed — this advances `state.next` past the breakpoint without actually running the node.

---

## Edge case: interrupt_before on a node that branches

If the node routes to multiple possible successors via conditional edges, `state.next` after the breakpoint will show only the node itself (not its targets) because the edge function hasn't run yet. You can still override state or skip the node using `as_node` as above.

---

## Do NOT Load

Do NOT load this file when `interrupt()` is used inline — the inline interrupt pattern is covered in the main SKILL.md.
