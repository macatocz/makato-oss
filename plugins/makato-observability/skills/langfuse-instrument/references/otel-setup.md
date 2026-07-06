# OTel setup — TracerProvider + OTLP HTTP exporter

## Langfuse OTel endpoint

Langfuse exposes an OTLP HTTP receiver at:

```
<LANGFUSE_HOST>/api/public/otel/v1/traces
```

**Authentication:** HTTP Basic with `pk-lf-…:sk-lf-…` base64-encoded in the `Authorization` header. This is the same key pair used elsewhere in the Langfuse API.

**Protocol:** HTTP/protobuf. **NOT gRPC.** The Langfuse OTel receiver does not accept gRPC OTLP — the `opentelemetry-exporter-otlp-proto-grpc` package will fail with connection errors. This skill mandates `opentelemetry-exporter-otlp-proto-http`.

## Minimal TracerProvider

The template `templates/otel-setup.py` implements the full bootstrap. The core shape is:

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
import base64, os

def setup_tracing(service_name: str, service_version: str) -> None:
    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY")
    host       = os.environ.get("LANGFUSE_HOST")

    if not (public_key and secret_key and host):
        return  # silent no-op

    auth = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()
    exporter = OTLPSpanExporter(
        endpoint=f"{host}/api/public/otel/v1/traces",
        headers={"Authorization": f"Basic {auth}"},
    )

    provider = TracerProvider(resource=Resource.create({
        "service.name": service_name,
        "service.version": service_version,
    }))
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
```

## BatchSpanProcessor vs SimpleSpanProcessor

- **BatchSpanProcessor** — production default. Buffers spans, flushes on interval (5s) or batch size (512). Non-blocking. Some spans lag; occasional drops during shutdown if not flushed.
- **SimpleSpanProcessor** — test-only. Flushes each span synchronously. Slow, but deterministic — a test that generates a span sees it in the in-memory exporter immediately.

Production path uses Batch. Test path (Step 5) uses Simple with the InMemory exporter.

## Graceful shutdown

Add a flush handler so the process exits cleanly:

```python
import atexit
atexit.register(lambda: trace.get_tracer_provider().shutdown())
```

Without this, buffered spans in the batch processor may be lost when the process terminates.

## Resource attributes

`service.name` and `service.version` are the minimum. Consumers MAY add:

- `service.namespace` — for multi-service deployments
- `deployment.environment` — `production` / `staging` / `local` / `test`
- `service.instance.id` — for horizontally scaled deployments

The skill does not choose these — the consumer configures them via environment variables per the OTel resource-detector convention. `templates/env-local.example` documents the standard vars.
