# Langfuse CLI Reference

Documentation: https://langfuse.com/docs/api-and-data-platform/features/cli

## Install

```bash
# Run directly (recommended)
npx langfuse-cli api <resource> <action>
bunx langfuse-cli api <resource> <action>

# Or install globally
npm i -g langfuse-cli
langfuse api <resource> <action>
```

## Discovery

```bash
# List all resources and auth info
langfuse api __schema

# List actions for a resource
langfuse api <resource> --help

# Show args/options for a specific action
langfuse api <resource> <action> --help

# Preview the curl command without executing
langfuse api <resource> <action> --curl
```

## Credentials

Set these environment variables before every CLI invocation:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
export LANGFUSE_HOST=http://localhost:3000   # primary: your self-hosted instance URL
```

`LANGFUSE_HOST` is the primary configuration variable. It must point to your
self-hosted instance (e.g. `http://localhost:3000` for local dev). Do not
hard-code any cloud provider hostname.

## Tips

- Use `--json` for machine-readable output; `--curl` to preview without executing.
- All list commands support filtering — check `<resource> <action> --help` for options.
- **Prefer modern endpoints over legacy v1:**
  - `observations` over `legacy-observations-v1s`
  - `scores` over `legacy-score-v1s`
  - `metrics` over `legacy-metrics-v1s`
  The modern endpoints have better performance and cursor-based pagination; v1
  endpoints are deprecated.
- **`traces list` can time out** on large projects. Use `observations list`
  instead (add `--trace-id` when traversing from a known trace). See the
  [Observations API docs](https://langfuse.com/docs/api-and-data-platform/features/observations-api)
  for the v1 → v2 field mapping.
- **Pagination:** legacy v1 endpoints use `--limit` + `--page`; modern endpoints
  (`observations`, `metrics`, `scores`) use cursor-based pagination — pass
  `--limit`, then thread `meta.cursor` from the response into the next
  request's `--cursor`.
