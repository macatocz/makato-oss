<!-- JS/TS OTel bootstrap path. Scope admitted by AGENTS.md §What Belongs Here
     (Python services OR JS/TS OTel clients). This is instrumentation SETUP —
     enrichment of the resulting spans is covered by the langfuse-enrich skill. -->

# JS/TS: First Trace via OTel SDK

Lands a first Langfuse trace from a serverless/edge-runtime JS/TS agent using
`@opentelemetry/sdk-node` + `@langfuse/otel`. This framework-neutral path works
under any OTel registration hook; if your framework ships its own OTel wrapper
package, register the same `LangfuseSpanProcessor` through it instead.

## 1. Install

```bash
npm install @opentelemetry/sdk-node @langfuse/otel @langfuse/tracing
```

## 2. `instrumentation.ts` — MUST be the first import in the process

```ts
import { NodeSDK } from '@opentelemetry/sdk-node';
import { LangfuseSpanProcessor } from '@langfuse/otel';

const sdk = new NodeSDK({
  spanProcessors: [
    new LangfuseSpanProcessor({
      // must match ^(?!langfuse)[a-z0-9-_]+$ max 40 chars
      // typos create permanent env entries — no client-side validation warning
      environment: process.env.LANGFUSE_TRACING_ENVIRONMENT ?? 'development',
    }),
  ],
});
sdk.start(); // NEVER import any instrumented module before this line
```

In `index.ts` make this line 1:

```ts
import './instrumentation'; // bundler hoisting breaks tracing if placed later
```

## 3. Wrap an agent invocation

```ts
import { startActiveObservation, startObservation } from '@langfuse/tracing';

await startActiveObservation('chat-turn', async (span) => {
  span.update({ input: { userMessage } });

  const gen = startObservation(
    'llm-call', { model: 'gpt-4o', input: messages }, { asType: 'generation' },
  );
  const result = await callLlm(messages);
  gen.update({ output: result, usageDetails: { input: promptTokens, output: completionTokens } }).end();

  span.update({ output: result.content });
});
```

## 4. Environment variables

| Variable | Purpose |
|---|---|
| `LANGFUSE_BASE_URL` | Self-hosted endpoint (e.g. `http://localhost:3000`). **Unset = silently routes to cloud.** |
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-…` — required |
| `LANGFUSE_SECRET_KEY` | `sk-lf-…` — required |
| `LANGFUSE_TRACING_ENVIRONMENT` | Env label; constructor `environment` param takes precedence when both are set |

`LANGFUSE_BASE_URL` is the client SDK variable. `LANGFUSE_HOST` is the server-container
variable. For self-hosted, set both to the same URL.

## 5. Serverless/edge: flush before exit

```ts
// At handler boundary, before the function returns or stream closes.
await sdk.shutdown(); // or: langfuseSpanProcessor.forceFlush()
```

`BatchSpanProcessor` buffers spans in memory. Short-lived invocations exit before
the timer fires — buffered spans are silently lost. Call inside an `after()` hook,
not inline in the response stream (it blocks the event loop).

## Gotchas

- **`sdk.start()` ordering**: importing any instrumented client (`openai`, `@ai-sdk/openai`)
  before `sdk.start()` silently skips those calls. No error is thrown.
- **`forceFlush()` in serverless**: mandatory, not optional.
- **Framework OTel wrappers**: if you register through a framework's own OTel package
  instead of `@opentelemetry/sdk-node`, confirm it supports a custom `spanProcessors`
  array — older wrapper versions ignore `LangfuseSpanProcessor` and land no spans.
- **`traceFlags: 1`** is mandatory when injecting a custom `parentSpanContext` — omit
  it and Langfuse silently drops all spans (marked unsampled, no SDK error).
- **Environment typos** (e.g. `producton`) create permanent entries in the Langfuse
  UI — no client-side validation. Validate against the regex when generating labels dynamically.
