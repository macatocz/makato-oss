# SDK Upgrade Reference

## Migration Docs — Fetch First

**Always** fetch the relevant migration page before making any changes. These
are the canonical source; do not rely on memory.

```bash
# Python v3 → v4
curl -s "https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4.md"

# JS/TS v4 → v5
curl -s "https://langfuse.com/docs/observability/sdk/upgrade-path/js-v4-to-v5.md"
```

## Upgrade Checklist

Work through each item in order; skip items that do not apply.

### Both SDKs

- [ ] Update the SDK package to the latest version.
- [ ] **Audit span filtering:** non-LLM spans (HTTP, DB, queues) no longer export
      by default. If the user relied on them, configure a custom
      `should_export_span` / `shouldExportSpan` filter (see examples below).
- [ ] **Replace `update_current_trace()` / `updateActiveTrace()`** with three
      focused calls: `propagate_attributes()` (correlating attrs), `set_current_trace_io()`
      (I/O — deprecated for new code; prefer root observation), `set_current_trace_as_public()`.
- [ ] **Replace `.update_trace()` / `.updateTrace()`** on observation objects
      (same decomposition).
- [ ] **Update API namespace references:** `observations_v_2` → `observations`,
      `score_v_2` → `scores`, `metrics_v_2` → `metrics`. Legacy v1 APIs moved
      to `api.legacy.*`.
- [ ] **Validate metadata:** must be `dict[str, str]` / `Record<string, string>`,
      values ≤ 200 characters.
- [ ] **Move `release` and `environment`** to env vars:
      `LANGFUSE_RELEASE`, `LANGFUSE_TRACING_ENVIRONMENT`.
- [ ] **Enable debug logging** during migration (`debug=True` / `LANGFUSE_DEBUG="true"`).
- [ ] Test trace hierarchies — verify no spans are unexpectedly dropped.

### Python-specific

- [ ] Replace `start_span()` / `start_generation()` → `start_observation()`
      (use `as_type="generation"` for generations).
- [ ] Replace `start_as_current_span()` / `start_as_current_generation()` →
      `start_as_current_observation()`.
- [ ] Replace `item.run()` loop → `dataset.run_experiment(name=..., task=...)`.
- [ ] Remove `CallbackHandler(update_trace=...)` → use `propagate_attributes()` wrapper.
- [ ] Upgrade to Pydantic v2 (or use `pydantic.v1` shim if migrating gradually).
- [ ] Remove removed types: `TraceMetadata`, `ObservationParams` gone from
      `langfuse.types`; import `MapValue`, `ModelUsage`, `PromptClient` from
      `langfuse.model`.

### JS/TS-specific

- [ ] Update LangChain `CallbackHandler` — `traceMetadata` now requires string values.
- [ ] Update OpenAI integration — wrap entire execution in `propagateAttributes()`
      if relying on parent attribute inheritance.

## Key API Changes

**Correlating attributes — after (Python):**
```python
from langfuse import propagate_attributes
with propagate_attributes(trace_name="t", user_id="u1", session_id="s1"):
    result = call_llm("hello")
```

**Span creation — Python:**
```python
# start_span / start_generation → start_observation
langfuse.start_observation(name="x")
langfuse.start_observation(name="x", as_type="generation", model="gpt-4")
```

**Span filtering — extend defaults (preferred):**
```python
from langfuse.span_filter import is_default_export_span
langfuse = Langfuse(
    should_export_span=lambda span: (
        is_default_export_span(span)
        or span.instrumentation_scope.name.startswith("my_framework")
    )
)
# To export everything: should_export_span=lambda span: True
```

## Common Pitfalls

| Pitfall | Impact | Fix |
|---------|--------|-----|
| Dropping intermediate spans | Child spans orphaned | Use `is_default_export_span` as base |
| Metadata with non-string values | Silently dropped | Ensure all values are strings ≤ 200 chars |
| Setting attrs outside `propagate_attributes()` callback | Attrs don't attach | Wrap all traced code inside the callback |
| Using deprecated `set_current_trace_io()` in new code | Will be removed | Set I/O on the root observation directly |
| Forgetting Pydantic v2 upgrade (Python) | Import/runtime errors | Upgrade or use `pydantic.v1` shim |
| `release`/`environment` still passed as parameters | Silently ignored | Use env vars instead |
| LangChain/OpenAI propagation direction changed | Attrs don't reach parent traces | Wrap outer call in `propagate_attributes()` |
