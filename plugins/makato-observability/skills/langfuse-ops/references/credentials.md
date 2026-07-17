# Credentials — self-hosted / local setup

This skill targets self-hosted and local Langfuse instances only. `LANGFUSE_HOST` is the primary var; there is no default host assumed. **NEVER default `LANGFUSE_HOST` to any remote host when the var is unset — halt and ask.**

## Required environment variables

| Variable | Description | Example value |
|---|---|---|
| `LANGFUSE_HOST` | Base URL of the Langfuse instance. No trailing slash. | `http://localhost:3000` |
| `LANGFUSE_PUBLIC_KEY` | Project public key. Always starts with `pk-lf-`. | `pk-lf-abc123...` |
| `LANGFUSE_SECRET_KEY` | Project secret key. Always starts with `sk-lf-`. | `sk-lf-xyz789...` |

All three are required. **If any is missing, halt before running any CLI or API command — do not proceed past Step 0 in SKILL.md.**

## LANGFUSE_BASE_URL — JS/TS alias warning

The `@langfuse/otel` JS/TS package uses `LANGFUSE_BASE_URL` instead of `LANGFUSE_HOST`. If that var is absent, the SDK silently routes to a remote cloud endpoint. Set it equal to `LANGFUSE_HOST` in every JS/TS context:

```bash
export LANGFUSE_BASE_URL="$LANGFUSE_HOST"
```

Add this alongside `LANGFUSE_HOST` in `.env.local` for JS/TS projects.

## Where credentials come from

Keys are issued per-project inside the running Langfuse instance:

1. Open the Langfuse UI at `$LANGFUSE_HOST`.
2. Navigate to **Project Settings → API Keys**.
3. Click **Create API Key**. Copy both `pk-lf-…` and `sk-lf-…` immediately — the secret is shown once.
4. Store them in your password manager or secret store. Never commit them to the repo.

NEVER ask the operator to paste key values into the chat. If verification is needed, use a connectivity check (see below) which does not expose the keys.

## Verify connectivity

**NEVER print or log `LANGFUSE_SECRET_KEY`. Confirm auth from the exit code / HTTP status of the check below, never by echoing the response body.** Run one of these to confirm the vars are wired and the instance is reachable:

**Option A — CLI schema probe (no output on success; non-zero exit on failure):**

```bash
npx langfuse-cli api __schema \
  --host "$LANGFUSE_HOST" \
  --public-key "$LANGFUSE_PUBLIC_KEY" \
  --secret-key "$LANGFUSE_SECRET_KEY" \
  > /dev/null && echo "OK"
```

**Option B — curl auth check (returns HTTP 200 with project metadata on success):**

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  "$LANGFUSE_HOST/api/public/projects"
```

Expected: `200`. A `401` means keys are wrong. A connection error means `LANGFUSE_HOST` is unreachable.
