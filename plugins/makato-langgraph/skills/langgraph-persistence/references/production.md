# Production Persistence

MANDATORY: Load this file when the user is deploying to production, asks about connection pooling, PostgresSaver async, setup() idempotency, schema migration, or AsyncPostgresSaver.

Do NOT Load: for local development or testing scenarios where InMemorySaver is sufficient.

---

## PostgresSaver (sync)

```python
from langgraph.checkpoint.postgres import PostgresSaver

with PostgresSaver.from_conn_string(
    "postgresql://user:pass@localhost/db"
) as checkpointer:
    checkpointer.setup()  # idempotent: creates tables if absent; safe to call on every startup
    graph = builder.compile(checkpointer=checkpointer)
```

`setup()` is idempotent — it is safe to call on every process start. Do NOT skip it on first deployment or schema changes will not apply.

---

## AsyncPostgresSaver (for async graphs)

When your graph nodes use `async def`, use `AsyncPostgresSaver` — mixing sync saver with async graph causes deadlocks in Python's event loop:

```python
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

async def build_graph():
    async with AsyncPostgresSaver.from_conn_string(
        "postgresql://user:pass@localhost/db"
    ) as checkpointer:
        await checkpointer.setup()
        graph = builder.compile(checkpointer=checkpointer)
        result = await graph.ainvoke({"messages": ["Hello"]}, config)
        return result
```

---

## AsyncInMemoryStore (async long-term memory)

For async graphs that also use a Store, use `AsyncInMemoryStore` (or the async Postgres store variant) — the sync `InMemoryStore` blocks the event loop when called from `async def` nodes:

```python
from langgraph.store.memory import InMemoryStore
# sync — use in sync graphs only

# For async graphs:
from langgraph.store.memory import AsyncInMemoryStore
store = AsyncInMemoryStore()
```

---

## Production checklist

| Concern | Guidance |
|---|---|
| Connection pooling | Use `psycopg` connection pool; `from_conn_string` opens a single connection — not safe under concurrent load |
| `setup()` idempotency | Call on every startup; creates tables only if absent |
| Schema migration | LangGraph manages its own schema via `setup()`; do NOT hand-edit checkpoint tables |
| Async vs sync mismatch | Sync `PostgresSaver` + async graph node = deadlock; always match saver type to graph type |
| Thread ID collisions | Use a stable namespace prefix (e.g., `f"{user_id}:{session_id}"`) to prevent cross-user state leakage in multi-tenant apps |
| Checkpoint retention | LangGraph never prunes checkpoints automatically; implement a periodic cleanup job against the `checkpoints` table if storage is a concern |
