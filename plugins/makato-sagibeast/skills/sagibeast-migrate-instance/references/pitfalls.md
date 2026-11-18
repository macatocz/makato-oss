# Host-move pitfalls (symptom → cause → fix)

All observed during a real Vast.ai instance move. Placeholders only: `<SOURCE_IP>`, `<TARGET_IP>`,
`<UID>`, `<CONTAINER_IP>`.

## Start and rollout controller

| Symptom | Cause | Fix |
|---|---|---|
| `sagibeast-stack` fails: `source-rollout: finished: exit 65 target_changed` / `database_oid` | `source_rollout.py` stores the DB identity (`database_oid`, `system_identifier`, `namespace_id`) in its state file; the cold copy replaced the database | Stop the unit first (`Restart=on-failure` otherwise loops into the start limit), `source_rollout.py rebaseline-identity --confirm`, `systemctl reset-failed`, start. Never hand-edit the state file |
| Ports 8000/8080 vanish ~5 min right after start | Body-vault unseal runs a `sagibeast-openbao-unseal sync-policies` follow-up that recreates Body/Brain consumers | Expected. Wait for its `exit 0 ok`; restarting the stack mid-way only extends the outage |
| All modules return 503 `TENANT_AUTHORITY_UNAVAILABLE` after cutover | Source DB carried migrations the migrated SHA does not know (applied from an unmerged branch); new constraints reject the old code's writes | Prevent: preflight schema-drift finding must be resolved before cutover by migrating the code that owns those migrations. Do not ship ad-hoc compatibility triggers as the plan |
| Body tables lack new columns although Brain is current | The rollout controller applies only Brain migrations | Run owner-approved `infra/bootstrap/migrate.py` with budgets after a `pg_dump -Fc` |
| `fastapi-body` stays `starting`; deploy FATAL after retries | Newer code requires `offline_access` in `DOCS_OIDC_SCOPE` (env contract change) | Compare env keys the new SHA requires vs `/etc/sagibeast/*.env` (names only) before deploying; another reason to move first and upgrade later |
| `FATAL: /app/pyproject.toml differs` from a frozen runtime container | The frozen runtime image was built for a different `pyproject.toml`/`uv.lock` | Rebuild the runtime image for the deployed SHA (seconds); never bypass the guard |

## TLS, host values, models

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (60)` on public IP origins; deploy needs `--no-verify` | Public origin cert is self-signed for the SOURCE IP and was copied verbatim | `scripts/vast-public-tls.sh ensure` (re-mints when SAN ≠ `VAST_PUBLIC_IP` or <30 days left) |
| Scripts reach the old box or a third box | Stale default hosts/ports in scripts | Host scripts need `-H/--host` or `VAST_HOST`; on-box scripts read `/etc/default/sagibeast` and fail if keys are missing — set them, don't rely on defaults |
| `Pinned Wismut model artifacts are unavailable` | Model files written as root with mode 0600 (`NamedTemporaryFile` + `os.replace`); Body runs as non-root | Current `scripts/fetch_wismut_int8.py` publishes them 0644; for copies fetched by older code, `chmod 0644` the pinned public model files only — never relax credential files or whole trees |
| Shared tags (`openbao:<tag>`, `redis:<tag>`) on target point at different images than source | Floating tags re-pulled by CI | `vast-host-move.sh images` copies by image ID; never prune, so pinned IDs survive |

## Rehearsal isolation (only if you rehearse)

| Symptom | Cause | Fix |
|---|---|---|
| `connection refused` on `127.0.0.1:<published port>` of a service | Docker 28 publishes no host ports for containers attached only to `internal: true` networks (PortBindings set, `NetworkSettings.Ports` empty) | Reach `<CONTAINER_IP>` directly from the host or via a temporary loopback forwarder; remove it afterwards |
| `conflicting options: custom host-to-IP mapping and the network mode` | `extra_hosts` added to a service with `network_mode: service:X` | Skip such services in overlays; they inherit X's `/etc/hosts` |
| Rollout exits 65 `boundary_violation` | Overlay set `environment: PYTHONPATH` on `source-preparation-worker`, which is not on the worker allowlist | Set `PYTHONPATH` inline in that service's entrypoint instead |
| Rehearsal stack reaches the source after reboot | `iptables -I DOCKER-USER -d <SOURCE_IP> -j REJECT` is not persistent | Persist it in a oneshot unit ordered `Before=docker.service`; remove unit and rule at cutover |

## Q1452 qualification stack

- Vault unseal against `127.0.0.1:<port>` fails (internal-only network, see Docker 28 above): run
  the canonical unseal helper through a temporary loopback forwarder to the vault container IP,
  then remove the forwarder.
- Start it with its parent-apply `start` **without** `initialize`. Never run `vault-init`,
  `prepare-static` or `render-runtime` on copied state: they mint new identities and secrets.
- Never reset the provider meter; its ledger is part of the synced state.

## systemd connectors

- A unit with `RuntimeDirectory=` that drops privileges (`setpriv`, `User=`) in `ExecStart` gets
  `permission denied`: systemd re-chowns the runtime directory to the unit user (root) before each
  `Exec*`, undoing a chown in `ExecStartPre`. Use
  `ExecStartPre=install -d -o <UID> -g <GID> -m 0700 /run/<name>` and
  `ExecStopPost=rm -rf /run/<name>` instead.
- Connector tokens live in env files; check presence and mode, never their content.

## Access and process

| Symptom | Cause | Fix |
|---|---|---|
| OAuth login times out | Callback is localhost-bound on the headless box; tunnel opened late or only one port | Open ONE tunnel with both `1455` and `54545` before starting; one login at a time; never `--dry-run` (it starts OAuth) |
| Source SSH drops, multiplexer dies | Ad-hoc sessions over the owner's personal key | Dedicated target key + persistent ControlMaster alias, tested in preflight |
| Days lost on an archive/custody gate that was never used | Custody decided late, sized after the fact | Decide in Phase 0 with a bandwidth estimate; skip archives if not required |
| Runner install replaces live runners or enables them early | Installer defaults reuse names; the installer is fresh-host only | Register target runners after cutover with `config.sh` and distinct names/labels |
| Unpushed work lost with the source | Source doubled as a dev box | List worktrees, stashes and untracked files on the source for the owner before destruction |
