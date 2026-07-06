# Deployment paths

Every Langfuse setup this skill supports falls into one of three paths. The plugin is deployment-neutral (see plugin `AGENTS.md` § *Langfuse deployment stance*) — the operator picks the path, this skill accepts the credentials they supply.

## 1. Langfuse Cloud

Hosted by Langfuse. Two regions:

- **US** — `https://cloud.langfuse.com`
- **EU** — `https://eu.cloud.langfuse.com`

The operator picks the region. This skill does NOT choose for them.

**Where to find credentials:** Project settings → API Keys → Create API Key. Both `pk-lf-…` (public) and `sk-lf-…` (secret) appear once at creation time. The operator records them out-of-band (password manager, secret store).

## 2. Self-hosted

Any Langfuse deployment the consumer owns — Helm chart on their Kubernetes cluster, `docker compose` on a bare-metal host, a managed container platform. The URL pattern is entirely up to the operator.

This skill treats self-hosted identically to Cloud: it accepts the arbitrary `LANGFUSE_HOST` URL and pairs it with the operator-supplied keys. No cluster DNS pattern, no cloud-provider name, no vendor branding ever appears in prose or templates.

**Where to find credentials:** the same in-Langfuse Project settings flow as Cloud. Self-hosting only changes the URL; the API-key issue path is identical.

## 3. E2E-local

A locally-run Langfuse instance used for end-to-end tests. Typically:

```bash
docker compose up -d langfuse
```

with `LANGFUSE_HOST=http://localhost:3000`. The consumer supplies the compose file; this skill does not ship one.

**Framing rule:** the SKILL.md prose treats e2e-local as "the same deployment shape the consumer app uses in production, run against a local container." The app under test picks the deployment; the plugin does not.

**Where to find credentials:** on first bring-up, a local Langfuse presents a signup flow. The operator creates a project and issues API keys through the same UI as Cloud. For CI, the operator typically pre-seeds a project via Langfuse's provisioning API or by mounting a pre-populated Postgres volume — that setup lives in the consumer repo, not here.

## AskUserQuestion recipe

Step 0 uses this exact question shape:

```
Question: "How is Langfuse deployed for this project?"
Options:
  1. Langfuse Cloud
  2. Self-hosted
  3. E2E-local (docker compose)
```

Regardless of which the operator picks, the skill then prompts for the same three values: `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`. Missing any one → HALT.
