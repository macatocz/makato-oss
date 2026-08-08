---
name: fastapi
description: >-
  FastAPI best practices for production-grade Python HTTP APIs. Use when writing FastAPI
  endpoints, routers, Pydantic models, dependency injection (Depends, yield, scope),
  streaming responses (Server-Sent Events via fastapi.sse, JSON Lines, bytes), frontend
  asset serving (app.frontend), or working with the FastAPI tooling ecosystem (uv, Ruff,
  ty, Asyncer, SQLModel, HTTPX). Trigger keywords: fastapi, APIRouter, Depends,
  EventSourceResponse, StreamingResponse, sse, pydantic, SQLModel, asyncer, asyncify.
version: "1.1.0"
argument-hint: "[feature description or file path]"
---

# FastAPI

Official FastAPI skill. Focuses on non-obvious conventions, version-specific API surface,
and failure modes that practitioners learn through experience — not repeating what the
official tutorial already covers.

## Quick Reference

| Task | Reference | MANDATORY trigger |
|------|-----------|-------------------|
| SSE, JSON Lines, byte streaming | [references/streaming.md](references/streaming.md) | MANDATORY when any endpoint `yield`s or uses `EventSourceResponse` / `StreamingResponse` |
| `yield` deps, cleanup `scope=`, class deps | [references/dependencies.md](references/dependencies.md) | MANDATORY when using `yield` in a dependency or asking about cleanup timing |
| `response_model`, internal vs public schemas | [references/responses.md](references/responses.md) | MANDATORY when public response schema differs from function return type |
| Pydantic field constraints, `Annotated` | [references/pydantic.md](references/pydantic.md) | MANDATORY for Pydantic model field questions or validation constraints |
| Router prefixes, tags, `api_route`, versioning | [references/path-operations.md](references/path-operations.md) | MANDATORY for multi-router apps or non-standard route patterns |
| uv, Ruff, ty, Asyncer, SQLModel, HTTPX | [references/other-tools.md](references/other-tools.md) | MANDATORY when mixing sync/async code or setting up the tooling stack |

**Do NOT load** a reference unless its MANDATORY trigger applies to the current task.

---

## JSONL Audit Instrumentation

Emit a session-start entry when this skill is loaded, one entry per major section triggered,
and a session-end entry when the skill completes. Use
[`plugins/makato-build/shared/build-log.sh`](../../../../makato-build/shared/build-log.sh)
from within the worktree.

```bash
KEY="<issue-key>"  # e.g. 708-makato-fastapi-feat-resolve-5-feature-au

# Session start
build-log.sh "$KEY" '{"step":"session","skill":"fastapi","status":"start"}'

# Per-section entries (emit only for sections actually used)
build-log.sh "$KEY" '{"step":"streaming","skill":"fastapi","status":"ok"}'
build-log.sh "$KEY" '{"step":"dependencies","skill":"fastapi","status":"ok"}'
build-log.sh "$KEY" '{"step":"responses","skill":"fastapi","status":"ok"}'
build-log.sh "$KEY" '{"step":"pydantic","skill":"fastapi","status":"ok"}'
build-log.sh "$KEY" '{"step":"path-operations","skill":"fastapi","status":"ok"}'
build-log.sh "$KEY" '{"step":"other-tools","skill":"fastapi","status":"ok"}'

# Session end
build-log.sh "$KEY" '{"step":"session","skill":"fastapi","status":"ok"}'
```

---

## CLI

Run the development server (auto-reload):

```bash
fastapi dev
```

Run the production server:

```bash
fastapi run
```

Prefer declaring the entrypoint in `pyproject.toml` so the CLI needs no file-path argument:

```toml
[tool.fastapi]
entrypoint = "my_app.main:app"
```

When the entrypoint cannot be declared, or the user explicitly asks not to, pass the app file path:

```bash
fastapi dev my_app/main.py
```

---

## Parameter Declarations — `Annotated` Type Aliases

Always use `Annotated` for `Path`, `Query`, `Header`, `Body`, and `Depends` declarations.
The key expert reason beyond reusability: `Annotated` keeps the real type visible to `ty` and
mypy without special plugins. Without it, tools see `str | None` as the parameter type and
miss `Query(max_length=50)` constraints entirely.

Create a type alias for any dependency or parameterized type used in more than one router —
the alias is the canonical import point across the codebase:

```python
from typing import Annotated

from fastapi import Depends, FastAPI, Query

app = FastAPI()

# Define once; import into any router file
CurrentUserDep = Annotated[dict, Depends(get_current_user)]
PageQuery = Annotated[int, Query(ge=0, le=1000, description="Pagination offset")]


@app.get("/items/")
async def list_items(current_user: CurrentUserDep, offset: PageQuery = 0):
    ...
```

See [the Pydantic reference](references/pydantic.md) for model field constraints and
validation utilities.

---

## Async vs Sync — Decision Tree

```
Is ALL code called from this endpoint guaranteed non-blocking
(pure async libraries with no file I/O, DB, or subprocess)?
├─ Yes → async def path operation
└─ No (or uncertain)
   ├─ Has isolated blocking sections mixed with async? → def path operation
   │  + Asyncer asyncify() for the blocking sections
   └─ Fully synchronous? → def path operation
      (FastAPI runs def operations in a thread pool automatically)
```

**The silent performance trap:** FastAPI runs `async def` handlers directly on the event loop
thread — no thread pool. A single blocking call (`requests.get`, `time.sleep`, synchronous DB
query, `open()` on a large file) in an `async def` stalls the event loop for every concurrent
request on that worker. Under 50 concurrent requests, a 100 ms blocking call in `async def`
serializes all 50 — effective throughput drops 50×. The failure is invisible in unit tests and
low-traffic staging; it surfaces under load.

FastAPI `def` (sync) operations use a thread pool and never block the event loop.
The same async/sync rule applies to `async def` dependencies.

In case of doubt, use regular `def`. See [the other tools reference](references/other-tools.md)
for Asyncer `asyncify()` / `syncify()` patterns.

---

## Performance — Response Serialization

Do not use `ORJSONResponse` or `UJSONResponse` — they are deprecated.

`ORJSONResponse` requires the optional `orjson` package; `UJSONResponse` requires `ujson`.
If those packages are absent, you get an `ImportError` at request time (not at startup), which
is silent in development and crashes in production. More importantly, declaring a return type
routes serialization through Pydantic v2's built-in Rust-backed serializer — already faster
than orjson for Pydantic models, with zero extra dependencies.

Instead, declare a return type or `response_model`:

```python
@app.get("/items/{item_id}")
async def read_item(item_id: int) -> Item:   # Pydantic serializes via Rust
    ...
```

---

## Response Type vs `response_model` — Decision Tree

```
Is the function's return type the exact schema you want in the OpenAPI response?
├─ Yes → return type annotation only (simpler, preferred)
└─ No
   ├─ Return type is broader (Any, dict, internal model with extra fields)?
   │  └─ Use response_model=PublicSchema to filter + validate + document output
   └─ Return type cannot be annotated (legacy code, dynamic dict)?
      └─ response_model=PublicSchema with return type -> Any
```

**The security trap:** `response_model` silently drops fields present in the return value but
absent from the response schema. Forgetting `response_model` on an endpoint that returns an
internal model (with `hashed_password`, `secret_token`, etc.) leaks those fields in the
response. Using a typed return annotation alone does not filter — it only validates.

See [the response reference](references/responses.md) for worked filtering examples.

---

## Frontend Assets

Use `app.frontend()` or `router.frontend()` to serve a built frontend app (Vite, Astro,
Angular, Svelte, Vue) from a directory:

```python
app.frontend("/", directory="dist")
```

```python
router = APIRouter(prefix="/admin")
router.frontend("/", directory="admin-dist")
app.include_router(router)
```

**Key behavior:** `frontend()` registers a low-priority catch-all route. Regular API routes
match first; only unmatched paths fall through to frontend files and the SPA routing fallback.
This is the correct approach for single-page apps — do not use `StaticFiles` manually, which
requires a separate mount point and does not handle SPA client-side routing fallbacks.

---

## Dependency Injection

Use dependencies when: logic cannot be expressed in Pydantic validation, relies on external
resources, needs cleanup with `yield`, or is shared across endpoints.

Apply shared dependencies (auth, rate limits, request context) at the router level so they
automatically cover all endpoints without repeating `Depends(...)` per function:

```python
router = APIRouter(
    prefix="/items",
    tags=["items"],
    dependencies=[Depends(require_auth)],
)
```

**Scope decision for `yield` dependencies:**
- `scope="request"` (default) — cleanup runs after response is sent; use for DB sessions,
  file handles, any resource that can close post-response.
- `scope="function"` — cleanup runs before response bytes are flushed; use when the cleanup
  itself must affect the response (e.g., flushing a buffer, committing a transaction whose
  result the client needs to observe immediately).

See [the dependency injection reference](references/dependencies.md) for `yield` patterns,
scope timing details, and class dependency pitfalls.

---

## Streaming (SSE, JSON Lines, bytes)

MANDATORY: load [references/streaming.md](references/streaming.md) for any streaming task.

Quick start for SSE — import from `fastapi.sse`, the native built-in module (no third-party
`sse-starlette` required):

```python
from collections.abc import AsyncIterable

from fastapi import FastAPI
from fastapi.sse import EventSourceResponse, ServerSentEvent

app = FastAPI()


@app.get("/events", response_class=EventSourceResponse)
async def stream_events() -> AsyncIterable[ServerSentEvent]:
    yield ServerSentEvent(data={"status": "started"}, event="status", id="1")
```

Plain yielded objects are auto-JSON-serialized as `data:` fields. Use `ServerSentEvent` for
full field control (`event`, `id`, `retry`, `comment`, `raw_data`).

---

## Error Handling

Raise `HTTPException` for expected error cases (not-found, unauthorized, validation failures
the framework does not catch automatically):

```python
from fastapi import HTTPException

raise HTTPException(status_code=404, detail="Item not found")
```

Use `@app.exception_handler(ExcType)` for cross-cutting concerns — translating ORM exceptions
(`IntegrityError`, `NoResultFound`) into HTTP responses without wrapping every endpoint in
try/except. Register on the router or app depending on scope.

---

## Anti-patterns

### NEVER use `ORJSONResponse` or `UJSONResponse`

**WHY:** Both are deprecated wrappers that require `orjson` / `ujson` as optional installs.
Absent packages cause `ImportError` at request time, not at startup — silent in dev environments
that happened to have the package installed globally, crashing only in a clean prod container.
Pydantic v2's Rust serializer (active when you declare a return type or `response_model`) is
already faster and ships with FastAPI — no extra dependencies.

### NEVER run blocking code inside `async def` path operations or async dependencies

**WHY:** FastAPI runs `async def` handlers directly on the single event loop thread — no thread
pool buffer. One blocking call (`requests.get`, `time.sleep`, synchronous ORM query) blocks
every other in-flight coroutine on that worker for the duration. The failure is invisible under
serial tests and low-traffic staging, then catastrophic under real concurrency. FastAPI `def`
(sync) operations are dispatched to a thread pool automatically and do not block the event loop.

Fix: switch to `def`, or use `asyncify(blocking_fn)()` from Asyncer for isolated blocking
sections inside an otherwise async flow.

### NEVER use `Ellipsis` (`...`) as a default value in Pydantic v2 models or FastAPI parameters

**WHY:** In Pydantic v1, `Field(...)` was the idiomatic "required" marker. In Pydantic v2 it is
a silent no-op — `Field(...)` is treated identically to `Field()`. Keeping `...` in v2 code
misleads readers into thinking it adds a constraint, and some tooling (ty, mypy) misclassifies
the field as having an explicit default. The correct v2 signal for "required" is the absence
of any default.

### NEVER use `Depends(MyClass)` directly for class-based dependencies

**WHY:** FastAPI introspects `MyClass.__init__` to build the dependency graph. If `__init__`
uses `dataclasses.field(default_factory=...)`, keyword-only args, or custom `__init_subclass__`
logic, FastAPI cannot resolve the signature and raises a cryptic `ParameterError` at startup.
The factory-function pattern (`Depends(get_my_instance)`) delegates construction to a plain
function whose signature is always inspectable, regardless of how complex the class internals are.

### NEVER use `RootModel` in FastAPI endpoints

**WHY:** FastAPI auto-creates a Pydantic `TypeAdapter` for plain annotated types at registration
time, producing clean OpenAPI schemas (e.g., a bare `array` type). `RootModel` wraps the type
in an extra object layer — the OpenAPI schema gains a `$defs` wrapper object instead of the
direct type. API client generators (openapi-generator, hey-api) emit incorrect wrapper types
from the wrapped schema, requiring manual fixups in every consumer.

### NEVER declare multi-method routes via `api_route(methods=[...])`

**WHY:** OpenAPI path items support per-operation response schemas, security definitions, and
descriptions. `api_route` with multiple methods collapses to a single operation object in the
generated spec — you cannot attach different `response_model` values or status codes per HTTP
method. The resulting schema misleads client generators into assuming both methods share a
response shape. Give each HTTP method its own function.

---

## Routers

Declare `prefix`, `tags`, and `dependencies` on the `APIRouter` constructor, not in
`include_router()`. This keeps router configuration self-contained and prevents the router
from being included with different prefixes by accident.

See [the path operation reference](references/path-operations.md) for examples and exceptions.

---

## Tooling

See [the other tools reference](references/other-tools.md) for full patterns:

- **Asyncer** — `asyncify()` wraps a blocking function for use in `async def`;
  `syncify()` calls async code from sync context. Prefer over raw `anyio.to_thread`.
- **SQLModel** — SQL databases with Pydantic-integrated models; prefer over SQLAlchemy alone.
- **HTTPX** — sync and async HTTP client; prefer over Requests.
- **uv** — package and virtual environment management.
- **Ruff** — linting + formatting (enable FastAPI-specific rules); **ty** — type checking.
