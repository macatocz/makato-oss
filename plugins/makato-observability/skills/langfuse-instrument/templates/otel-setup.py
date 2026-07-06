"""
OpenTelemetry tracing bootstrap for a LangGraph-based agent, exporting via
OTLP HTTP to a Langfuse endpoint.

Usage:
    # In the agent's entry point, before any LangGraph node imports:
    from <your-module> import setup_tracing
    setup_tracing(service_name="<service-name>", service_version="<version>")

Behaviour:
    - When LANGFUSE_PUBLIC_KEY is unset (typical local dev), the function
      is a silent no-op. Zero overhead. LangGraph nodes still call
      tracer.start_as_current_span but the spans are dropped.
    - When all three LANGFUSE_* env vars are present, a TracerProvider is
      installed globally with a BatchSpanProcessor exporting HTTP/protobuf
      to <LANGFUSE_HOST>/api/public/otel/v1/traces via Basic auth.
    - Idempotent: calling setup_tracing() twice replaces the provider.
      Prefer to call it exactly once from the entry point.

Requires:
    opentelemetry-api>=1.25
    opentelemetry-sdk>=1.25
    opentelemetry-exporter-otlp-proto-http

Environment variables (all three required for tracing to be enabled):
    LANGFUSE_HOST         e.g. https://cloud.langfuse.com, https://langfuse.internal, http://localhost:3000
    LANGFUSE_PUBLIC_KEY   pk-lf-...
    LANGFUSE_SECRET_KEY   sk-lf-...

Optional:
    OTEL_SERVICE_NAME     overrides the service_name argument if set
    OTEL_SERVICE_VERSION  overrides the service_version argument if set
"""

from __future__ import annotations

import atexit
import base64
import logging
import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

_LOG = logging.getLogger(__name__)

_TRACES_PATH = "/api/public/otel/v1/traces"


def setup_tracing(service_name: str, service_version: str) -> None:
    """Install a TracerProvider exporting to Langfuse via OTLP HTTP.

    Silent no-op when Langfuse credentials are absent.
    """
    host = os.environ.get("LANGFUSE_HOST")
    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY")

    if not (host and public_key and secret_key):
        _LOG.info(
            "Langfuse tracing disabled — LANGFUSE_HOST/PUBLIC_KEY/SECRET_KEY not all set",
        )
        return

    # Env overrides win over the caller's arguments.
    name = os.environ.get("OTEL_SERVICE_NAME", service_name)
    version = os.environ.get("OTEL_SERVICE_VERSION", service_version)

    auth = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()
    exporter = OTLPSpanExporter(
        endpoint=f"{host.rstrip('/')}{_TRACES_PATH}",
        headers={"Authorization": f"Basic {auth}"},
    )

    resource = Resource.create({
        "service.name": name,
        "service.version": version,
    })
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    # Flush buffered spans on interpreter shutdown so trailing observations
    # from the last request reach the dashboard.
    atexit.register(provider.shutdown)

    _LOG.info(
        "OpenTelemetry TracerProvider installed — exporting to %s (service=%s v%s)",
        host,
        name,
        version,
    )
