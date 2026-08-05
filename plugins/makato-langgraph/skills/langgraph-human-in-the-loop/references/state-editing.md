# State Editing (update_state)

MANDATORY: Load this file when the user mentions `update_state`, `get_state`, `as_node`, editing state mid-run, overriding state between runs, or injecting state on a specific node.

---

## update_state mechanics

`update_state(config, values, as_node=None)` writes to the checkpoint for `thread_id`. The write goes through the same **reducers** defined on the state schema:

- An `Annotated[list[str], operator.add]` field will **append** the update values, not replace
- A plain field (no annotation) will **overwrite**
- To force-overwrite a reducer field, import and use `Overwrite` from `langgraph.types` in your schema, or redesign — there is no ad-hoc bypass at call time

```python
from typing import Annotated
import operator
from langgraph.types import Overwrite

class State(TypedDict):
    msgs: Annotated[list[str], operator.add]   # append semantics
    status: str                                  # overwrite semantics
    locked: Annotated[str, Overwrite]            # force-overwrite even with annotation
```

---

## as_node parameter

`as_node="node_name"` tells the checkpoint that the update came from the named node. This has two effects:

1. The graph's `state.next` advances past that node (it treats the node as already executed)
2. Conditional edges originating from that node fire, which may queue additional nodes

Use `as_node` when you want to **skip** a node (e.g., deny a tool call in an interrupt_before breakpoint) or **inject** a synthetic node result without running actual node code.

**Without `as_node`**: the update is written but `state.next` is not advanced — useful for patching a value before resuming normally with `graph.invoke(None, config)`.

---

## Reading state: get_state vs get_state_history

```python
# Current snapshot
state = graph.get_state(config)
state.values       # dict of current field values
state.next         # tuple of next-queued node names (empty = graph finished)
state.config       # the config dict you passed
state.metadata     # step count, etc.
state.tasks        # in-progress tasks (non-empty when graph is paused mid-step)

# Full history (newest first)
for snapshot in graph.get_state_history(config):
    print(snapshot.metadata["step"], snapshot.values)
```

Use `get_state_history` to build a time-travel debugger or to roll back to an earlier checkpoint:

```python
# Roll back to step 3
target = next(s for s in graph.get_state_history(config) if s.metadata["step"] == 3)
graph.update_state(target.config, target.values)  # restore that snapshot
```

---

## update_state before vs after interrupt

| Timing | Effect |
|---|---|
| Before `invoke(None, config)` after a **breakpoint** | Edits what the next node sees; `state.next` unchanged unless `as_node` used |
| Before `invoke(Command(resume=...), config)` after an `interrupt()` | Edits go into checkpoint; node re-runs from beginning and sees updated values |
| After graph completes | Allowed — useful for data correction; next `invoke` sees updated values |

---

## Common trap: updating the wrong thread

`update_state` silently succeeds even if the thread_id has no checkpoint (it creates one). Always verify with `graph.get_state(config)` before updating — if `state.values` is empty and `state.next` is empty, the thread does not exist and you are writing to a ghost checkpoint.

---

## Do NOT Load

Do NOT load this file for basic `interrupt()` / `Command(resume=...)` patterns — state editing is an advanced modifier. Load only when the user explicitly needs to inspect or mutate graph state between runs.
