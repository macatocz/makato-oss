# Streaming

## Stream JSON Lines

To stream JSON Lines, declare the return type and use `yield` to return the data.

```python
@app.get("/items/stream")
async def stream_items() -> AsyncIterable[Item]:
    for item in items:
        yield item
```

## Server-Sent Events (SSE)

To stream Server-Sent Events, use `response_class=EventSourceResponse` and `yield` items from the endpoint.

Plain objects are automatically JSON-serialized as `data:` fields, declare the return type so the serialization is done by Pydantic:

```python
from collections.abc import AsyncIterable

from fastapi import FastAPI
from fastapi.sse import EventSourceResponse
from pydantic import BaseModel

app = FastAPI()


class Item(BaseModel):
    name: str
    price: float


@app.get("/items/stream", response_class=EventSourceResponse)
async def stream_items() -> AsyncIterable[Item]:
    yield Item(name="Plumbus", price=32.99)
    yield Item(name="Portal Gun", price=999.99)
```

For full control over SSE fields (`event`, `id`, `retry`, `comment`), yield `ServerSentEvent` instances:

```python
from collections.abc import AsyncIterable

from fastapi import FastAPI
from fastapi.sse import EventSourceResponse, ServerSentEvent

app = FastAPI()


@app.get("/events", response_class=EventSourceResponse)
async def stream_events() -> AsyncIterable[ServerSentEvent]:
    yield ServerSentEvent(data={"status": "started"}, event="status", id="1")
    yield ServerSentEvent(data={"progress": 50}, event="progress", id="2")
```

Use `raw_data` instead of `data` to send pre-formatted strings without JSON encoding:

```python
yield ServerSentEvent(raw_data="plain text line", event="log")
```

### `sse_starlette` compatibility note

Existing codebases (for example, projects created before FastAPI 0.115) often use
`sse_starlette.sse.EventSourceResponse` from the third-party `sse-starlette` package. Both
work correctly at runtime; the native `fastapi.sse` module is the **preferred choice for new
code** (FastAPI 0.115+) — no extra dependency, same API surface.

**Migration from `sse_starlette` to `fastapi.sse`:**

```python
# Before (sse_starlette)
from sse_starlette.sse import EventSourceResponse

@app.get("/events", response_class=EventSourceResponse)
async def stream_events():
    yield {"data": "hello", "event": "msg", "media_type": "text/event-stream"}
```

```python
# After (fastapi.sse — FastAPI 0.115+)
from fastapi.sse import EventSourceResponse, ServerSentEvent

@app.get("/events", response_class=EventSourceResponse)
async def stream_events():
    yield ServerSentEvent(data="hello", event="msg")
    # No explicit media_type= — EventSourceResponse sets it automatically
```

Key differences:
- Remove the explicit `"media_type": "text/event-stream"` key from yielded dicts — `EventSourceResponse` sets the header automatically.
- Replace plain `dict` yields with `ServerSentEvent` instances for type safety and IDE support.
- Swap the import: `from fastapi.sse import EventSourceResponse` replaces `from sse_starlette.sse import EventSourceResponse`.

Do **not** change existing working `sse_starlette` endpoints unless you are already touching
the file — a mechanical import swap is low-risk, but the migration is not urgent.

## Stream bytes

To stream bytes, declare a `response_class=` of `StreamingResponse` or a sub-class, and use `yield` to return the data.

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from app.utils import read_image

app = FastAPI()


class PNGStreamingResponse(StreamingResponse):
    media_type = "image/png"

@app.get("/image", response_class=PNGStreamingResponse)
def stream_image_no_async_no_annotation():
    with read_image() as image_file:
        yield from image_file
```

prefer this over returning a `StreamingResponse` directly:

```python
# DO NOT DO THIS

import anyio
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from app.utils import read_image

app = FastAPI()


class PNGStreamingResponse(StreamingResponse):
    media_type = "image/png"


@app.get("/")
async def main():
    return PNGStreamingResponse(read_image())
```
