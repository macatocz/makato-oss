---
name: sagibeast-migrate-instance
description: "Move a live Sagibeast deployment from one Vast.ai instance to another with a cold sync and a short cutover. Use for host move, instance migration, new Vast box, cutover, or replacing the production instance."
version: "1.0.0"
argument-hint: "<source-ssh-alias> [phase]"
allowed-tools: Read Glob Grep Bash AskUserQuestion
---

# Migrate a Sagibeast Instance

Operator runbook for moving a running Sagibeast stack between Vast.ai instances. It drives the
sagibeast repo scripts; it does not replace them. The copy and cutover take well under an hour —
the previous move took days because of decisions taken late, release requalification, unused
encrypted archives and hand-written tooling. This skill front-loads decisions and reuses scripts.

**Prerequisite:** the sagibeast SHA being moved contains `scripts/vast-host-move.sh`,
`scripts/vast-public-tls.sh` and `source_rollout.py rebaseline-identity`. If it predates them, run
the tools from a newer checkout on the target; preflight then compares the source ledger with
THAT checkout's `sql/migrations`, so also compare it with the moved SHA's migrations yourself.

## When to Use

- Replacing the instance that serves Sagibeast (hardware, price, region, failing host).
- Rehearsing or resuming a partially done move (pass the phase to resume at).

## When NOT to Use

- Code refresh on the same host → `sagibeast-refresh-runtime`.
- Fresh dev box with no data to keep → sagibeast `scripts/install-vast-instance.sh`.
- Upgrading the release: move first, upgrade afterwards with a normal `scripts/vast-deploy-dev.sh`.

## Rules for the whole session

- **Move, don't upgrade.** The target runs the exact SHA and the runtime/executor image IDs the
  source serves now. Requalifying a moving branch cost 3–4 days and 7 SHAs last time.
- **One state directory is the source of truth.** Pick `RECEIPTS=/var/lib/sagibeast/host-move/<UTC>`
  on the target once and pass `--receipts "$RECEIPTS"` to every `vast-host-move.sh` call. Record
  owner decisions in `$RECEIPTS/decisions.json` and audit events in `$RECEIPTS/audit.jsonl`.
  Narrative notes and memory go stale; receipts don't.
- Never `docker compose down -v`, `docker system/volume/image prune`, or installers over restored
  data — they destroy the only copy or mint replacement trust identities.
- Never `cat`, `env`, `docker inspect` full config, or otherwise print `/etc/sagibeast/*.env`,
  tokens, PATs or vault material. Report names, modes, sizes and hashes only.
- A red test is a migration blocker only if it is green on the SOURCE. Run the same E2E against
  the source first. Time-box unexplained hosted-runner flakes (≤1 h) and never make them gates.
- Owner-gated steps (marked **[owner]**) need an explicit yes in this session; earlier approvals
  for a different step do not carry over.

Load @references/pitfalls.md whenever a step fails with an error not explained in the step.
Do NOT load it up front.

## Workflow

### Phase 0 — One decision round **[owner]**

Emit `session-start`. Gather facts first (read-only): source and target `nproc`, `free -g`,
`df -h /`, `nvidia-smi -L`, `/dev/kvm`; source `git rev-parse HEAD` of the deployed checkout and the
image IDs of running containers. Then ask ALL of these in ONE `AskUserQuestion` round, with
recommended defaults, and write the answers to `decisions.json`:

- [ ] **Target hardware** — show CPU/RAM/disk/GPU of target vs source; accept or pick another box.
- [ ] **Release** — migrate source SHA `<SHA>` and its image IDs unchanged (recommended).
- [ ] **Backup** — cold sync with manifest proof; the stopped source stays as rollback until the
      owner destroys it (recommended). No separate archive set.
- [ ] **Encrypted off-host custody** — only if the owner requires it. If yes, estimate now:
      payload GB ÷ measured egress MB/s; last time 53 GB of `.age` archives took ~3 days and were
      never used. Do not build archives if declined.
- [ ] **Secrets rotation** — now (during cutover) or deferred to a dated follow-up.
- [ ] **Cutover window** — date/time; expect ~30 min of downtime.
- [ ] **Source destruction** — who destroys the source instance and when.
- [ ] **omp auth** — new OAuth logins on the target, or transfer the omp auth store from the source.

Do not start Phase 1 work that depends on an unanswered item. Emit `decisions`.

### Phase 1 — Access (run in parallel)

1. **Target → source SSH.** Generate a dedicated key on the target, have the owner append its
   public key to the source `authorized_keys`, and define a ControlMaster alias in
   `/root/.ssh/config` (`ControlMaster auto`, `ControlPersist yes`, `ControlPath
   /root/.ssh/<alias>.sock`, `ForwardAgent no`). Never copy the owner's personal key; never use
   agent forwarding. Test: `ssh <alias> true`. Then `export SOURCE_SSH="ssh <alias>"`.
2. **GitHub** — `gh auth login` + `gh auth setup-git` on the target **[owner]**.
3. **omp / LLM providers** — either transfer the omp auth store from the source (only with the
   Phase 0 consent), or log in fresh: open ONE SSH tunnel from the owner's machine carrying both
   callback ports (`-L 1455:127.0.0.1:1455 -L 54545:127.0.0.1:54545`) BEFORE starting OAuth, run one
   login at a time, then prove every configured role answers. Never run
   `omp auth-broker login --dry-run` — it really starts OAuth.
4. **Port map** — read `VAST_TCP_PORT_8000/8080/3000` and the SSH port from `/etc/environment` on the
   target (or `vastai show instance <INSTANCE_ID> --raw`). These become the public ports.

Emit `access`.

### Phase 2 — Provision the target (fresh host only)

Fetch the installer of the source SHA onto the fresh target (`gh api
'repos/<OWNER>/<REPO>/contents/scripts/install-vast-instance.sh?ref=<SHA>' -H 'Accept:
application/vnd.github.raw' > /root/install-vast-instance.sh`) and run it; it clones that SHA itself:

```bash
gh auth token | sudo bash /root/install-vast-instance.sh --git-token-stdin --ref "<SHA>" \
  --skip-stack --runner-count 0 --public-ip "<TARGET_IP>" --llm-model "<MODEL>"
```

Run it only while the target holds no restored data. Never run it, or
`scripts/vast-bootstrap-demo-prerequisites.sh` (demo/dev-auth hosts only), after any sync: the
restored state already holds the credentials and trust they would provision.
Host extras the installer may not cover: the pinned `semgrep` version CI expects (check the CI
workflow), and Chromium for `@playwright/mcp` (`npx playwright install chromium` with the version
the MCP package pins). From here on, run repo commands as root from `/opt/sagibeast` on the
target. `--skip-stack` leaves `sagibeast-stack` and its watchdog disabled (the watchdog would
start the stack on a partial copy) and the installer never enables `sagibeast-cloudflared`.
Emit `provision`.

### Phase 3 — Preflight, images, warm sync

```bash
scripts/vast-host-move.sh --receipts "$RECEIPTS" preflight
scripts/vast-host-move.sh --receipts "$RECEIPTS" images --dry-run   # then without --dry-run
scripts/vast-host-move.sh --receipts "$RECEIPTS" sync               # warm; repeat freely
```

Preflight is read-only and exits non-zero on blocking findings. Treat **schema drift** as the
critical one: migrations applied on the source DB that the migrated SHA does not ship. Resolve it
BEFORE cutover by migrating the code that owns them (owner picks the SHA that contains them,
then repeat Phase 0's release item). Ignoring it caused a 3 h post-cutover outage last time.
Also resolve disk headroom (source near-full means no staging there; `images` streams anyway).

Preflight also lists `/etc/default/sagibeast` keys present on the source but missing on the
target (names only; the file is not part of the data sync). Keep the target's host keys the
installer wrote (`VAST_PUBLIC_IP`, `VAST_CONSOLE_PORT`, `VAST_CUSTOMER_UI_PORT`,
`VAST_LANGFUSE_PORT`) and append the missing ones without displaying values, after backing the
file up: `$SOURCE_SSH "grep -E '^(KEY_A|KEY_B)=' /etc/default/sagibeast" >> /etc/default/sagibeast`.

Repeat warm `sync` until the delta is small; it shortens the cold sync. Emit `preflight`,
`images`, `sync-warm`.

### Phase 4 — Rehearsal (avoid if possible)

Prefer not to start the stack on copied production data before cutover: it can write to shared
external services, mint state and diverge identities. If a rehearsal is unavoidable, use a
throwaway state directory, block the source IP and public hostnames, and read the isolation
section of @references/pitfalls.md before writing any overlay. Delete the rehearsal state before
cutover. Emit `rehearsal` (or `skipped`).

### Phase 5 — Cutover **[owner: go signal]**

Announce the window. Expected durations are from the last move (~13 GB data).

| # | Step | Expect |
|---|------|--------|
| 1 | `scripts/vast-host-move.sh --receipts "$RECEIPTS" quiesce-source --yes` | 1–2 min |
| 2 | `scripts/vast-host-move.sh --receipts "$RECEIPTS" sync --cold` — must report every pair identical | 5–15 min |
| 3 | Pending Body migrations **[owner]**: `pg_dump -Fc` first, then `infra/bootstrap/migrate.py` with `--rollout-config` budgets and `--evidence-out "$RECEIPTS/…"` (`--preflight-only` first). Its DSNs carry passwords: build them from the env files inside a subshell, never echo them. The rollout controller applies only Brain migrations | 2–5 min |
| 4 | `systemctl enable --now sagibeast-stack.service sagibeast-watchdog.timer`. The start re-mints the copied public IP certificate (its SAN still names the source IP) via `scripts/vast-public-tls.sh ensure` | 5–10 min |
| 5 | On `exit 65 target_changed` (database identity changed by the copy): `systemctl stop sagibeast-stack`, `python3 /opt/sagibeast/scripts/source_rollout.py rebaseline-identity --confirm`, `systemctl reset-failed sagibeast-stack`, start again | 2 min |
| 6 | Body-vault unseal triggers a `sync-policies` follow-up: 8000/8080 disappear ~5 min. Wait for its `exit 0 ok`; do not restart anything | ~5 min |
| 7 | Q1452 qualification stack, if present — see @references/pitfalls.md "Q1452" | 3–5 min |
| 8 | Connectors: `systemctl enable --now sagibeast-cloudflared.service`; other host-run connectors per pitfalls "systemd" | 1 min |
| 9 | Verify (below) | 5 min |

Stop at the first failing step; do not improvise around a failed cold-sync proof.
**Verify:** all services healthy (`docker ps` shows no restarting/unhealthy containers; console
health); public HTTPS on every public hostname and on the IP origins, validated against the
deployment's `public-ca-bundle` (no `-k`); an authenticated smoke with a QA identity through the
main user flow. Emit `cutover` with per-step status and timings.

**Rollback** (writes since quiesce are lost): on the target `systemctl disable --now
sagibeast-cloudflared sagibeast-watchdog.timer sagibeast-stack`, then on the source run
`$SOURCE_SSH bash -s < "$RECEIPTS/rollback.sh"` (restores restart policies, re-enables and starts
the recorded units). Never run both stacks against the public hostnames.

### Phase 6 — After cutover

1. Runners: the installer is fresh-host only, so register with the runner's `config.sh` as in
   sagibeast `docs/development/testbox-runner.md`, using distinct names (e.g. `vast-<INSTANCE_ID>-…`)
   and the labels the workflows target; switch routing (`CI_RUNNER` repo variable /
   `scripts/ci-runner-target.sh`), then deregister the source's runners **[owner]**.
2. Reboot acceptance **[owner]**: reboot the target, confirm the stack, vault unseal, GPU and
   connectors come back without intervention.
3. Before the source is destroyed, the owner reviews unpushed branches, stashes and untracked files
   in every worktree on the source (list them read-only for the owner).
4. Delete pre-migration dumps after the owner confirms the new instance.
5. Rotate secrets if decided in Phase 0.
6. Upgrades now follow the normal `scripts/vast-deploy-dev.sh` path.

Emit `post-cutover` and `session-end`.

## Audit Output

Append one JSON object per line to `$RECEIPTS/audit.jsonl` (before `$RECEIPTS` exists, emit in the
session) at session start, each phase and session end. Use observed values only; never secrets.

```json
{"event":"sagibeast-migrate-instance.session-start","source":"<SOURCE_ALIAS>","target":"<TARGET_IP>","status":"started"}
{"event":"sagibeast-migrate-instance.cutover","step":"sync-cold","status":"ok","seconds":512}
{"event":"sagibeast-migrate-instance.session-end","status":"blocked","reason":"schema-drift"}
```

Phase suffixes: `decisions`, `access`, `provision`, `preflight`, `images`, `sync-warm`,
`rehearsal`, `cutover`, `post-cutover`. Status values: `started`, `ok`, `failed`, `blocked`,
`skipped`.
