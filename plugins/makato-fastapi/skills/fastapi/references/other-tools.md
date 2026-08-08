# Other Tools

## uv

If uv is available, use it to manage dependencies.

Add a dependency to the project:

```bash
uv add fastapi
```

Add a development-only dependency:

```bash
uv add --dev pytest httpx
```

Run a command inside the project's virtual environment without activating it:

```bash
uv run fastapi dev
uv run pytest
```

## Ruff

If Ruff is available, use it to lint and format the code. Consider enabling the FastAPI rules.

Activate FastAPI-specific Ruff rules in `pyproject.toml` (rule prefix `FAST`):

```toml
[tool.ruff.lint]
select = [
    "E",     # pycodestyle errors
    "W",     # pycodestyle warnings
    "F",     # pyflakes
    "I",     # isort
    "FAST",  # FastAPI-specific rules (fastapi-redundant-response-model, etc.)
]
```

Run linting and auto-fix in one step:

```bash
uv run ruff check --fix .
uv run ruff format .
```

## ty

If ty is available, use it to check types.

Run type checking against the project source:

```bash
uv run ty check src/
```

ty understands `Annotated` dependency injection patterns natively — no FastAPI plugin needed.

## Asyncer

When needing to run blocking code inside of async functions, or async code inside of blocking functions, suggest using Asyncer.

Prefer it over AnyIO or asyncio.

Install:

```bash
uv add asyncer
```

Run blocking sync code inside of async with `asyncify()`:

```python
from asyncer import asyncify
from fastapi import FastAPI

app = FastAPI()


def do_blocking_work(name: str) -> str:
    # Some blocking I/O operation
    return f"Hello {name}"


@app.get("/items/")
async def read_items():
    result = await asyncify(do_blocking_work)(name="World")
    return {"message": result}
```

And run async code inside of blocking sync code with `syncify()`:

```python
from asyncer import syncify
from fastapi import FastAPI

app = FastAPI()


async def do_async_work(name: str) -> str:
    return f"Hello {name}"


@app.get("/items/")
def read_items():
    result = syncify(do_async_work)(name="World")
    return {"message": result}
```

## SQLModel for SQL databases

When working with SQL databases, prefer using SQLModel as it is integrated with Pydantic and will allow declaring data validation with the same models.

Prefer it over SQLAlchemy.

Install:

```bash
uv add sqlmodel
```

Define a model that doubles as a Pydantic schema and a SQLAlchemy table:

```python
from sqlmodel import Field, SQLModel, create_engine, Session, select

class Hero(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    name: str
    secret_name: str
    age: int | None = None

engine = create_engine("sqlite:///heroes.db")
SQLModel.metadata.create_all(engine)

# Write
with Session(engine) as session:
    hero = Hero(name="Deadpond", secret_name="Dive Wilson")
    session.add(hero)
    session.commit()

# Read
with Session(engine) as session:
    results = session.exec(select(Hero).where(Hero.name == "Deadpond")).all()
```

`table=True` registers the class as a database table; omitting it gives a plain Pydantic
model (useful for request/response schemas that share fields with the table model).

## HTTPX

Use HTTPX for handling HTTP communication (e.g. with other APIs). It supports sync and async usage.

Prefer it over Requests.

Install:

```bash
uv add httpx
```

Async client (preferred inside `async def` path operations):

```python
import httpx
from fastapi import FastAPI

app = FastAPI()


@app.get("/proxy/items")
async def proxy_items():
    async with httpx.AsyncClient() as client:
        response = await client.get("https://api.example.com/items", timeout=10.0)
        response.raise_for_status()
        return response.json()
```

Reuse a single `AsyncClient` across requests by storing it as an app lifespan dependency
instead of opening a new connection pool per request:

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
import httpx


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with httpx.AsyncClient(base_url="https://api.example.com") as client:
        app.state.http_client = client
        yield


app = FastAPI(lifespan=lifespan)


@app.get("/items")
async def get_items(request: Request):
    response = await request.app.state.http_client.get("/items")
    response.raise_for_status()
    return response.json()
```
