# Troubleshooting

Symptom → cause → fix, in the order most likely encountered.

## No traces on the dashboard

**Symptom:** Agent runs, LangGraph nodes execute, but the Langfuse Tracing tab stays empty.

Check in this order:

1. **Credentials loaded?** Log `os.environ.get("LANGFUSE_PUBLIC_KEY")` in the bootstrap module. If it's `None`, the TracerProvider silently no-op'd. Fix the `.env.local` load path — typically the runner needs to pick up `.env.local` before importing the agent module.
2. **TracerProvider actually installed?** Add a log line in the template's happy path (right after `trace.set_tracer_provider(provider)`) and confirm it fires on agent start.
3. **Node bodies wrapped in spans?** Grep the graph module for `tracer.start_as_current_span`. If nodes don't open spans, the OTLP exporter has nothing to send.

## 401 Unauthorized from the OTLP endpoint

**Symptom:** Agent logs `Failed to export batch code: 401`.

**Cause:** `Authorization: Basic <base64>` header malformed or key pair mismatched.

**Fix:**

- Verify the header format — MUST be `Basic <base64(pk:sk)>` with a colon between pk and sk before base64 encoding.
- Verify the pk/sk pair belongs to the same Langfuse project the `LANGFUSE_HOST` points to. A pk-lf-… from project A won't authenticate against project B's host.

Reproduce the header manually:

```bash
echo -n "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" | base64
curl -v -H "Authorization: Basic <the-base64-above>" "$LANGFUSE_HOST/api/public/health"
```

Expect `HTTP/1.1 200 OK`.

## Connection refused / DNS failure

**Symptom:** `ConnectionError: Failed to establish a new connection`.

**Cause:** `LANGFUSE_HOST` unreachable from the agent's network. For e2e-local: docker compose service not up. For self-hosted: firewall / VPN / cluster network policy.

**Fix:**

- Confirm reachability with `curl "$LANGFUSE_HOST/api/public/health"`. Expect `{"status":"OK"}`.
- For e2e-local: `docker compose ps langfuse` should show `Up`. Restart if not.
- For self-hosted: check the deployment's ingress rules / service DNS.

## OTLP endpoint returns 404

**Symptom:** Agent logs `Failed to export batch code: 404`.

**Cause:** OTLP endpoint path wrong. Common mistakes:

- Sent to `/v1/traces` instead of `/api/public/otel/v1/traces`.
- Sent to gRPC endpoint (`opentelemetry-exporter-otlp-proto-grpc` package). Langfuse rejects gRPC OTLP — MUST use `opentelemetry-exporter-otlp-proto-http`.

**Fix:** verify the exporter constructor uses `endpoint=f"{host}/api/public/otel/v1/traces"` and the HTTP exporter package.

## Traces appear, but `observations` array is empty

**Symptom:** `curl "$LANGFUSE_HOST/api/public/traces?limit=1"` returns a trace with `observations: []`.

**Cause:** OTel spans are being exported but they don't carry the required attributes for Langfuse to render them as observations.

**Fix:** verify LLM spans set at least `gen_ai.system` + `gen_ai.request.model`. Without these, Langfuse treats them as generic spans (they appear on the trace but not in the Generations tab).

## `gen_ai.usage.input_tokens` missing from LLM spans

**Symptom:** Traces render but token counts are `null` in Langfuse.

**Cause:** The LLM client's response object doesn't expose usage where the wrapping code expects it, or the attribute is set after `span.end()` (span already exported).

**Fix:** capture usage inside the `with tracer.start_as_current_span` block, before the response object goes out of scope. If the LLM client streams tokens, set usage on the final chunk's callback.

## Scrub-leak: perimeter=brain span shows raw input

**Symptom:** A brain-perimeter span has `input: "the raw prompt"` instead of `[CONTENT SCRUBBED]`.

**Cause:** the node body sets `span.set_attribute("input", raw)` before the perimeter guard fires, or misses the guard entirely.

**Fix:** perimeter check MUST run before any `span.set_attribute("input", ...)` / `("output", ...)`. See `references/span-attribute-conventions.md` § *Scrub sentinels*.

Downstream test assertions match on the exact sentinels — do NOT paraphrase (`[SCRUBBED]`, `[REDACTED]`, `<masked>` all break the test contract).

## Buffered spans lost on process exit

**Symptom:** Some spans from the last request never appear in Langfuse.

**Cause:** process exited before `BatchSpanProcessor` flushed its buffer.

**Fix:** register the shutdown hook from `references/otel-setup.md` § *Graceful shutdown*:

```python
import atexit
atexit.register(lambda: trace.get_tracer_provider().shutdown())
```
