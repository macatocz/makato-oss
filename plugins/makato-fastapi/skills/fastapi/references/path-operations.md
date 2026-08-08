# Path Operations and Routing

## Including Routers

When declaring routers, prefer to add router-level parameters like prefix, tags, and shared dependencies to the router itself instead of in `include_router()`.

Do this:

```python
from fastapi import APIRouter, FastAPI

app = FastAPI()

router = APIRouter(prefix="/items", tags=["items"])


@router.get("/")
async def list_items():
    return []


app.include_router(router)
```

Instead of:

```python
# DO NOT DO THIS
from fastapi import APIRouter, FastAPI

app = FastAPI()

router = APIRouter()


@router.get("/")
async def list_items():
    return []


app.include_router(router, prefix="/items", tags=["items"])
```

There could be exceptions, but try to follow this convention.

Apply shared dependencies at the router level via `dependencies=[Depends(...)]`.

## API Versioning

### URL-prefix versioning with `APIRouter`

The simplest and most common pattern: mount versioned routers under a `/v1`, `/v2`, … prefix.

```python
from fastapi import APIRouter, FastAPI

app = FastAPI()

v1_router = APIRouter(prefix="/v1", tags=["v1"])
v2_router = APIRouter(prefix="/v2", tags=["v2"])


@v1_router.get("/items")
async def list_items_v1():
    return [{"id": 1, "name": "Widget"}]


@v2_router.get("/items")
async def list_items_v2():
    return [{"id": 1, "name": "Widget", "sku": "WGT-001"}]


app.include_router(v1_router)
app.include_router(v2_router)
```

Clients reach `GET /v1/items` and `GET /v2/items` independently. OpenAPI groups operations
under the respective `v1` / `v2` tags. Router-level configuration (auth dependencies, rate
limits) applies uniformly to all endpoints in that version without repeating it per function.

### Header-based versioning (sketch)

When URL structure must stay stable, inspect a custom request header instead:

```python
from fastapi import APIRouter, Depends, Header, HTTPException
from typing import Annotated


async def require_v1(accept_version: Annotated[str | None, Header()] = None):
    if accept_version not in (None, "1", "1.0"):
        raise HTTPException(status_code=400, detail="Unsupported API-Version header")


versioned_router = APIRouter(
    prefix="/items",
    tags=["items"],
    dependencies=[Depends(require_v1)],
)
```

Header versioning is harder to test in browsers and OpenAPI UIs; prefer URL-prefix versioning
for new projects unless the URL must be stable (e.g., published webhooks, embedded URLs in
third-party systems).

## Use one HTTP operation per function

Don't mix HTTP operations in a single function. Having one function per HTTP operation helps separate concerns and organize the code.

Do this:

```python
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()


class Item(BaseModel):
    name: str


@app.get("/items/")
async def list_items():
    return []


@app.post("/items/")
async def create_item(item: Item):
    return item
```

Instead of:

```python
# DO NOT DO THIS
from fastapi import FastAPI, Request
from pydantic import BaseModel

app = FastAPI()


class Item(BaseModel):
    name: str


@app.api_route("/items/", methods=["GET", "POST"])
async def handle_items(request: Request):
    if request.method == "GET":
        return []
```
