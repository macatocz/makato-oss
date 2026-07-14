# Exploration Patterns by Architecture Type

## Layered Architecture (MVC, Clean, N-Tier)

**Entry points to trace**: HTTP handlers, CLI commands, event listeners.

**Call direction**: Controllers → Services → Repositories → Data stores.

**Key grep patterns**:

```bash
grep -r "class.*Controller\|class.*Handler\|@app.route\|router\." src/ --include="*.py"
```

**What to look for**: The service layer is the "brain" — most business logic lives there.
Repositories are often thin wrappers. If service methods are > 50 lines, they're doing too
much and the architecture is drifting.

## Event-Driven / Message-Based

**Entry points to trace**: Topic subscriptions, queue consumers, event handlers.

**Call direction**: Event source → Dispatcher → Handlers → Side-effects.

**Key grep patterns**:

```bash
grep -r "subscribe\|on_message\|@event_handler\|consume(" src/ --include="*.py"
```

**What to look for**: The event schema is the contract. Find where events are
*published* first (not consumed) — the publisher defines what downstream handlers
can rely on. Orphaned subscribers (no active publisher) are dead code.

## Microservices / API-First

**Entry points to trace**: API gateway routes, gRPC service definitions, OpenAPI specs.

**Call direction**: API layer → Business service → Downstream service calls → DB.

**Key grep patterns**:

```bash
grep -r "import requests\|httpx.get\|grpc.Channel\|stub\." src/ --include="*.py"
```

**What to look for**: Cross-service calls are the blast radius. Find every place this
service calls another service — those are the failure points under load. Missing circuit
breakers or retries are architecture gaps worth noting.

## Pipeline / ETL

**Entry points to trace**: Trigger functions, scheduled jobs, input readers.

**Call direction**: Source → Transform stages → Sink/Output.

**Key grep patterns**:

```bash
grep -r "def run\|def execute\|def process\|@task\|def transform" src/ --include="*.py"
```

**What to look for**: The pipeline stage boundaries. Each stage should have a clear input
type and output type. Mixed responsibilities (a stage that both transforms and writes)
indicate a design smell.

## Quick Orientation Checklist

Run these grep commands to get oriented in any codebase:

```bash
# What are the main entry points?
grep -r "if __name__\|def main\|app.run\|@app.route" . --include="*.py" -l

# What does it import from outside?
grep -r "^import\|^from" src/ --include="*.py" | grep -v "from \." | sort -u | head -20

# What are the main classes?
grep -r "^class " src/ --include="*.py" | sort

# What tests exist?
find . -name "test_*.py" -o -name "*_test.py" | head -10
```
