---
name: sagibeast-refresh-runtime
description:
  "Refresh Sagibeast code and recreate containers to apply the latest solution. Use for redeploy
  Sagibeast, refresh code, restart stale containers, or apply newest changes."
version: "1.0.0"
argument-hint: "[host] [revision] [--check-only]"
allowed-tools: Read Glob Grep Bash
---

# Refresh Sagibeast Runtime

## When to Use

Apply the newest Sagibeast solution to an existing Docker Compose environment, including
bind-mounted Python and frontend code that running processes may still have cached. Use after
deployment appears successful but `/import`, chat, APIs, or workers run older code.

## When NOT to Use

- Provisioning a new host or establishing SSH access.
- Kubernetes deployment, database recovery, or secret rotation.
- Production rollout without an approved maintenance window and rollback procedure.
- Merely creating this skill: authoring it does not authorize a deployment.

## Inputs and Output

Infer host, deployed repository, branch, project and overlays from runtime metadata and repository
configuration. An explicit revision overrides the deployed branch's upstream. Ask with selectable
options only when multiple actual environments or revisions remain plausible.

`--check-only` performs read-only discovery and verification planning: no fetch, checkout, build,
restart, HTTP mutation, or audit-file write. Emit audit lines to the session instead.

Output the resolved commit, service actions, health and behavioral evidence, and any blockers. Do
not equate a healthy HTTP endpoint with a verified authenticated chat or ingestion flow.

## Workflow

### 1. Discover the real deployment

Emit `session-start` using the audit format below. Load @references/deployment.md. Discover Compose
projects and inspect the selected containers' labels, bind mounts, image IDs, network mode and
process start times. Inspect only needed fields; full environment/config dumps can expose secrets.
Follow mounts to the deployed checkout instead of updating the runner worktree.

Read that repository's deployment instructions, Compose overlays, start/deploy scripts and CI
workflow. Identify the existing deployment lock or serialized runner. If a deployment is active,
wait for it to finish before taking the same lock; if exclusive access cannot be established, stop.
Do not invent an independent lock that CI ignores. Announce the restart window and affected
services.

Preserve unrelated Compose projects, databases, volumes, secrets and local changes. Do not use
`down -v`, prune, `git reset --hard`, `git clean`, automatic stash, or broad destructive sync. If
production is discovered, require explicit rollout authorization before mutation. Emit `discovery`
with project, checkout and current revision, excluding credentials.

### 2. Resolve and refresh source

Under deployment exclusivity, record the previous SHA, branch/upstream and working-tree status. Stop
on dirty tracked or untracked files; distinguish documented ignored runtime data from source.
Resolve the configured upstream rather than assuming `main` or `development`. For a clean tracked
branch, fetch its remote, resolve the upstream to an immutable SHA, then fast-forward to that SHA
with `git merge --ff-only`. Stop on divergence or fetch failure. An explicitly requested commit/tag
must resolve after fetching the configured remote; switching to it requires a clean checkout and the
repository's documented detached-release procedure. If there is no upstream or release procedure,
ask for the target rather than guessing.

In check-only mode, report the local and remote-tracking SHAs as cached observations, not proof of
the newest remote code, and skip to the verification plan in step 5.

Inspect the revision delta and updated deployment entrypoint before execution. Identify dependency,
image, asset, configuration and migration changes. Use the repository's migration procedure and
backup/approval requirements; stop before service recreation if required migration prerequisites are
missing. Re-check the selected SHA before building and after rollout to detect concurrent edits.
Emit `source` with old and target SHA and status.

### 3. Build and select the rollout path

Prefer the repository's supported deployment entrypoint when it covers the intended environment.
Read its actions first: do not invoke first-boot provisioning, credential reseeding or unrelated
infrastructure changes just to refresh code. If its scope exceeds this request, use the same
resolved Compose project, ordered overlays, profiles and environment inputs for a targeted rollout.

Classify every code-bearing service from the effective configuration, including both Temporal worker
services when present. Rebuild services with local Docker build contexts; pull configured registry
images when required by the deployment policy. Record image IDs/digests. Complete builds and pulls
before replacing running services; stop if either fails.

Bind-mounted source still requires a fresh process even if its image is unchanged. Config/env or
image changes require recreation, not `docker compose restart`. For a full refresh, recreate all
code-bearing services; restrict to a subset only when explicitly requested and its consumers are
accounted for. Identify shared-network dependents before replacing their network owner. Emit `build`
with service names and result, not rendered secrets.

### 4. Recreate in dependency order

Use the supported rollout or the targeted Compose commands in the reference. Preserve stateful
infrastructure unless an identified change explicitly requires its documented upgrade procedure.
Bring prerequisites up and complete required migrations first. Recreate application services and
workers, then wait for the network owner's readiness before recreating its namespace-sharing
frontend/proxies. Derive the order from current configuration, not a fixed historical service list.

Use bounded waits from the repository's health script. A service in `Created`, restart loops, an
unhealthy container, a failed build, or a nonzero deployment command is a failure. Do not hide it
with `|| true`. Collect scoped logs since rollout began and stop advancing the rollout on error.
Record what was replaced and what remains running. Roll back only using the documented procedure and
after checking migration compatibility; do not blindly revert code across schema changes. Emit
`recreate` with service actions and status.

### 5. Prove freshness and behavior

Check the deployed SHA still equals the target. Verify source inside containers against deployed
files and built images against the recorded IDs. Verify every recreated process/container started
after the source refresh, including workers and namespace-sharing dependents.

Check service readiness, public routing and recent error logs. Then exercise the affected flow: for
`/import` chat, use an authorized session and selected non-sensitive test documents to submit a
question, observe the stream and terminal result, and confirm the previous TypeError is absent. Do
not log document contents, prompts, tokens or answers in audit output. Test uploads or other
mutating operations only with authorized disposable fixtures. If authentication or a fixture is
unavailable, report the exact missing prerequisite and mark functional verification blocked. A
browser refresh alone cannot replace stale server processes.

In check-only mode, report mismatched revisions/start times and the precise proposed commands; do
not claim the refresh or functional verification was performed. Emit `verify` and `session-end`.
Release deployment exclusivity on every exit. Report success only when both freshness and the
requested behavior are verified; otherwise report partial deployment or blocked verification
explicitly, with the last successful step and recovery action.

## Audit Output

Emit one JSON object per line at session start, each executed major step and session end. Use the
repository's existing audit sink when available; otherwise emit in the session. No new audit system
is needed. Populate actual timestamps and observed values; omit fields not yet known.

```json
{"event":"sagibeast-refresh-runtime.session-start","mode":"apply","status":"started"}
{"event":"sagibeast-refresh-runtime.discovery","project":"sagibeast","status":"ok"}
{"event":"sagibeast-refresh-runtime.session-end","status":"blocked","reason":"deployment-active"}
```

Step suffixes: `discovery`, `source`, `build`, `recreate`, `verify`. Status values: `started`, `ok`,
`failed`, `blocked`, `check-only`. Include old/target SHA, service names and verification results
when known. Redact credentials and customer data from all evidence.
