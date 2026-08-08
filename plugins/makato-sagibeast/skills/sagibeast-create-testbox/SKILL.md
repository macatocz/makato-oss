---
name: sagibeast-create-testbox
description: >-
  Provision a sagibeast testbox VM (Lima/VZ on macOS, EC2, or Hetzner) for E2E
  parity testing. Use when creating testbox, provisioning testbox, spinning up
  vm, new sagibeast vm.
version: "2.0.0"
argument-hint: "[runtime] [cpus] [memGB] [diskGB] [os]"
allowed-tools:
  - Bash
---

# sagibeast-create-testbox

## When to Use

- Brain-only or customer-tier parity testing that a single laptop cannot simulate (ADR-0023 cross-node perimeter)
- Team-shared multi-day E2E rig that must outlive any single laptop session
- Stable egress IP required for an IP-allowlisted endpoint (laptop NAT unsuitable)
- Long-running E2E suites that must survive a laptop closing

## When NOT to Use

- Unit and property tests → host pytest (fastest, no VM needed)
- Integration tests with Brain-PG + Body-PG → Docker Compose on host (Track 1)
- Full-stack E2E on a laptop with ≥ 16 GB RAM → Docker Compose covers the full ADR-0023 shape
- CI on PR → GH Actions ubuntu-latest handles it
- Testbox already exists → use `sagibeast-connect-testbox` instead

## Runtime: Lima (VZ), not Multipass, on macOS

On the local Apple-Silicon host the **Multipass QEMU backend is broken**: every
VM — even a freshly launched one — hangs in `State=Unknown` with no IPv4, because
the vmnet/`bootpd` DHCP path never assigns a lease. Rebooting, `brew reinstall
multipass`, and switching `local.driver` all fail (multipass 1.16.x on this host
only accepts the `qemu` driver, which is the broken one). See
`docs/development/testbox-runner.md` for the full diagnosis.

**Use Lima instead.** Lima drives Apple's Virtualization.framework (VZ) directly —
the same backend colima uses successfully here — so the VM boots and gets an IP
reliably. This skill provisions the macOS testbox via `limactl` and the checked-in
`infra/testbox/lima.yaml`. The EC2 and Hetzner paths are unchanged (they never used
Multipass).

## Philosophy

A testbox is the **escape hatch** — not the default path.

The vast majority of sagibeast E2E runs locally via Track 1's Docker Compose stack.
That stack reproduces the full ADR-0023 deployment shape (Brain-PG + Body-PG +
MinIO×2 + Zitadel + Langfuse + OpenBao×2 + Temporal + FastAPI Brain/Body + Temporal
worker + Tesseract OCR) on a single developer laptop with ≥ 16 GB RAM. Provision a
testbox **only** when a scenario from the [§ When to use a testbox](#when-to-use-a-testbox)
table below applies.

Treating the testbox as a convenience degrades discipline around the Compose stack and
makes the ADR-0020 / ADR-0021 perimeter harder to reason about. Every team-member
provisioning "just to be safe" ends up running two stacks in parallel, burning disk
quota, and creating lateral-movement risk.

## Mindset: Provision Once, Configure Completely

The four most-skipped steps that cause painful re-provisioning:

1. **Point `lima.yaml` at your repo and SSH key.** The `infra/testbox/lima.yaml`
   template carries an `AGENT_SUBSTITUTE` marker for the repo mount path; replace it
   with your absolute repo path before `limactl create`. Lima injects your
   `~/.ssh/*.pub` keys automatically (`loadDotSSHPubKeys: true`), so no OS password is
   needed for SSH — `limactl shell` uses the generated key on `localhost:60022`. (The
   legacy Multipass path needed a 1Password OS password in `cloud-init.yaml`; Lima does
   not.)

2. **Reach the VM with `limactl shell`, not raw SSH.** `limactl shell sagibeast-testbox
   <cmd>` handles the key, port, and user for you and stays alive for the whole command.
   If you do add a raw-SSH `~/.ssh/config` block, keep `ServerAliveInterval 5` so a long
   `pytest -m e2e` session does not drop silently and orphan the Brain-PG pool. Lima's
   SSH endpoint is `127.0.0.1:60022`.

3. **Trust the project step-ca root before the first API call.** `bootstrap.sh` does
   this automatically, but if you skip bootstrap and curl a Brain/Body endpoint directly,
   you will get a TLS certificate error that looks like a service misconfiguration — not
   a missing trust anchor. Run `step ca root --ca-url "$SAGIBEAST_CA_URL" | sudo tee
   /usr/local/share/ca-certificates/sagibeast-root.crt && sudo update-ca-certificates`
   exactly once after first boot if you bypass bootstrap.

4. **Register the GitHub Actions runners with the right labels.** The sagibeast
   workflows (`sensors.yml`, `post-merge.yml`, `spec-docs.yml`, `archive-spec.yml`)
   route the **heavy** docker-stack job onto `["self-hosted", "sagibeast-testbox"]` and
   the **light** lint job (including the required `pre-commit` check) onto
   `["self-hosted", "cmai-lint"]` when `CI_RUNNER=self-hosted`. The runner **name** is
   NOT automatically a **label**. Register the heavy runner with
   `--labels self-hosted,sagibeast-testbox` and the lint pool with
   `--labels self-hosted,cmai-lint`. Omit the flag and jobs sit `queued` for GitHub's
   24 h ceiling, then die `cancelled` — a red `sync-status` on every PR (#572). Missing
   the `cmai-lint` pool leaves the required `pre-commit` check with no runner, so the PR
   is BLOCKED forever. See [§5/5](#55-bootstrap-and-verify).

## Anti-patterns

**NEVER point two testboxes at the same Brain-PG.**
ADR-0020 mandates a bilateral Brain-PG / Body-PG split: one Brain-PG owns the
checkpoint table for exactly one developer context. Sharing a Brain-PG across two
testboxes contaminates checkpoint rows — tests from developer A overwrite vectors
created by developer B mid-run, producing non-deterministic E2E failures that are
extremely hard to attribute. Each testbox must provision its own Brain-PG container.

**NEVER export tenant API keys, DEKs, or service account tokens as long-lived shell env vars on the testbox.**
A shared testbox (team-shared rig) means multiple developers access the same shell
history and any env dump (e.g., `printenv`) leaks every credential set in the
session. Use `op run -- <command>` per invocation. Long-lived env vars survive `ssh`
reconnects and `tmux` sessions, expanding the exfiltration window.

**NEVER write tenant skill encryption keys to disk on the testbox.**
ADR-0021 (customer IP isolation) prohibits materialising tenant keys outside the
vault. A key written to `/tmp` or a dotfile persists across re-boots, is included in
`scp` transfers, and may end up in Docker bind mounts or test artefacts. Fetch via
`op run --` per invocation; the key must never touch the filesystem.

**NEVER peer, VPN-join, or network-connect the testbox k3d cluster to the customer K8s tier.**
ADR-0023 defines the testbox as a dev-tier perimeter. Joining a dev k3d node to the
customer K8s network collapses the perimeter: workloads in the testbox gain
network-level access to production service endpoints. Provision the testbox in a
dedicated dev VPC with no route to customer-tier CIDRs.

**NEVER register a runner without its explicit `--labels`.**
The runner name does NOT become a label (#572). The heavy runner needs
`--labels self-hosted,sagibeast-testbox`; each lint runner needs
`--labels self-hosted,cmai-lint`. Omitting the flag leaves only the platform defaults
(`self-hosted,Linux,ARM64`); label-gated jobs queue for 24 h and die `cancelled`, and
the required `pre-commit` check never schedules. Re-run `config.sh --replace` with the
explicit flag to recover; the flag is load-bearing, not optional.

**NEVER fall back to the Multipass/QEMU driver on this macOS host.**
It cannot bring a VM to a routable state (no DHCP lease → `State=Unknown`). Reboot,
reinstall, and driver-switch all fail. Use Lima/VZ. On EC2/Hetzner this does not apply.

**NEVER provision a testbox VM with fewer than 64 GB disk or 8 GB RAM.**
Ubuntu base (~6 GB) + Docker layer cache (~22 GB) + pgvector + bge-m3 indexes
(~12 GB) = ~48 GB before swap. With 8 GB RAM the Temporal worker and bge-m3
ONNX inference together exhaust available memory before the first E2E test completes.
MANDATORY: Load `@references/sizing-guide.md` when the operator is choosing VM
specs or evaluating whether an existing instance type is adequate — it contains the
full per-layer disk and RAM breakdown with recommended instance tiers.

## Navigation

| Your situation | Use this skill |
| --- | --- |
| No testbox exists yet, you need one | **This skill** (`sagibeast-create-testbox`) |
| Testbox exists, you need to SSH in | `sagibeast-connect-testbox` |
| Testbox exists, you need port-forward | `sagibeast-connect-testbox --port-forward` |
| Testbox exists, you need k3d cluster | `sagibeast-connect-testbox --k3d` |
| Testbox exists, you need to sync creds | `sagibeast-connect-testbox --sync-creds` |
| Testbox exists but `limactl list` shows Stopped | `sagibeast-connect-testbox` (it will start first) |
| You are debugging a CI E2E failure | Run locally via `docker compose -f infra/docker-compose.yml -f infra/docker-compose.test.yml up -d` — no testbox needed |

## When to use a testbox

Cross-reference: `docs/superpowers/plans/2026-06-21-e2e-testing-strategy.md` §
"When to use a testbox (decision matrix)"

| Scenario | Where to run | Why |
| --- | --- | --- |
| Unit + property tests | **Host pytest (L1)** | `testing.md:154-159` fast lane < 30 s |
| Integration with Brain-PG + Body-PG | **Compose on host (L2)** | TRUNCATE-between-tests pattern |
| Full-stack E2E (FastAPI + LG + PG×2 + MinIO×2 + Zitadel + Langfuse + OpenBao×2 + Temporal) | **Compose on host (L2)** — laptop with ≥ 16 GB RAM fits | ADR-0023 deployment shape matches exactly |
| ADR-0023 Makato Internal parity | **Compose on host (L2)** with `is_internal_operator: true` | Same Compose; checkpointer selector flips |
| Brain-only / customer tier parity (cross-node ADR-0023 perimeter a laptop cannot simulate) | **Testbox (L3)** | Different physical machine = real perimeter |
| Team-shared multi-day E2E rig | **Testbox (L3)** | Outlives any single laptop; Tailscale ACLs share it safely |
| Stable egress IP for IP-allowlisted endpoint | **Testbox (L3) in a known region** | Laptop NAT is unsuitable |
| CI on PR | **GH Actions ubuntu-latest** | No testbox; `e2e.yml` handles it |
| Apple Silicon parity in CI | **Self-hosted macOS runner (Mac Studio)** | Same hardware as ADR-0023 production target |
| Nightly cron E2E | **GH Actions** primary; testbox optional for egress-IP scenarios | `testing.md:164-165` |

## Workflow

Run all steps from the repository root (`git rev-parse --show-toplevel`). Relative
paths (`infra/testbox/...`) are repo-root-relative and fail if invoked from a
subdirectory.

### [0/5] Pre-flight checks

Verify all dependencies exist before spending time on provisioning:

```bash
# Lima runtime (macOS, VZ backend)
limactl --version
# OR for EC2: aws sts get-caller-identity
# OR for Hetzner: hcloud version

# 1Password CLI signed in (used later for tenant creds via `op run`)
op whoami

# step-ca root reachable
step ca root --ca-url "$SAGIBEAST_CA_URL"
```

If `limactl` is missing: `brew install lima`.

If `SAGIBEAST_CA_URL` is not set, check `infra/testbox/bootstrap.sh` and the project
`.env.local` for the correct URL.

If `op whoami` fails, run `op signin` before continuing.

For EC2: MANDATORY load `@references/provider-ec2.md` for instance selection and
exact `aws ec2 run-instances` invocation with ARM64 AMI lookup.

For Hetzner: MANDATORY load `@references/provider-hetzner.md` for instance
selection — `cx31` is too small (OOM), minimum is `cx41`; file also has the
`hcloud server create` command and volume attachment for large Docker storage.

Do NOT load provider-ec2.md or provider-hetzner.md for a Lima provisioning run.
Do NOT load sizing-guide.md unless the operator is choosing VM specs or evaluating
whether an existing instance type is adequate.

### [1/5] Abort if testbox already exists

```bash
if limactl list --quiet 2>/dev/null | grep -qx sagibeast-testbox; then
  echo "ERROR: sagibeast-testbox already exists."
  echo "Use sagibeast-connect-testbox instead."
  exit 1
fi
```

If you need to reprovision from scratch: `limactl stop -f sagibeast-testbox &&
limactl delete sagibeast-testbox`. This is destructive — confirm first.

If the testbox is on EC2 or Hetzner, replace the `limactl list` check with the
provider equivalent from the loaded provider reference.

### [2/5] Prepare the Lima config

```bash
# Copy the template and point the repo mount at your absolute repo path.
REPO_ROOT="$(git rev-parse --show-toplevel)"
cp infra/testbox/lima.yaml /tmp/sagibeast-lima.yaml

# Substitute the repo mount path (BSD sed on macOS needs the -i '' form).
sed -i '' "s|# AGENT_SUBSTITUTE: repo-path.*|${REPO_ROOT}|" /tmp/sagibeast-lima.yaml

# Sanity-check the config before launch.
limactl validate /tmp/sagibeast-lima.yaml
```

`infra/testbox/lima.yaml` already pins `vmType: "vz"`, requests 4 CPU / 8 GiB / 64 GiB,
loads your `~/.ssh/*.pub` keys, and installs the full CI toolchain in its `provision`
block — including the packages that were once missing on a bare VM: `docker-compose-v2`
(Ubuntu's `docker.io` ships no compose plugin, and the old `docker-compose-plugin`
package is empty on 24.04), `libatomic1` (pre-commit's biome/node hook fails to load
without it), and it disables `unattended-upgrades` + the apt-daily timers so a
post-boot auto-upgrade never holds the dpkg lock against a CI job.

For k3d parity testing, verify `--with-k3d` is set so `bootstrap.sh` installs k3d.

### [3/5] Create and start the VM

```bash
limactl create --name sagibeast-testbox --yes /tmp/sagibeast-lima.yaml
limactl start sagibeast-testbox

# Wait for Running state.
until limactl list sagibeast-testbox --format '{{.Status}}' 2>/dev/null | grep -q Running; do
  echo "Waiting for VM to reach Running state..."
  sleep 5
done

echo "VM is Running."
limactl list sagibeast-testbox

# Enable auto-start on login so the VM survives a host reboot (see infra/testbox/
# cz.sagibeast.testbox-autostart.plist — this is the supported, upgrade-safe path).
limactl start-at-login sagibeast-testbox
```

**4 vCPU / 8 GB / 64 GB is the absolute minimum** for a single-developer testbox
running Compose without k3d. Bump `memory` in `lima.yaml` to 16 GiB if you observe OOM
kills in the Temporal worker or LangGraph execution.

For EC2 or Hetzner: use the launch command from the provider reference loaded in step
[0/5] in place of `limactl create/start`.

### [4/5] Access over `limactl shell`

Lima exposes SSH on `127.0.0.1:60022` and injects your ed25519 key. Prefer
`limactl shell` for command execution — it needs no `~/.ssh/config` entry:

```bash
limactl shell sagibeast-testbox -- bash -c 'hostname; ip -4 addr show | grep -oE "inet [0-9.]+"'
```

If you want a raw-SSH host alias too, append once to `~/.ssh/config` (keep the
keep-alive so long E2E runs do not drop):

```text
Host sagibeast.testbox
    HostName 127.0.0.1
    Port 60022
    User <your-macos-username>.linux
    IdentityFile ~/.lima/_config/user
    ServerAliveInterval 5
    ServerAliveCountMax 1
```

For EC2 or Hetzner: use the IP retrieval + SSH command from the loaded provider reference.

### [5/5] Bootstrap and verify

```bash
# The repo is already mounted read-write at /repo (lima.yaml mount), so no transfer
# is needed — bootstrap.sh lives at /repo/infra/testbox/bootstrap.sh.

# Run bootstrap (add --with-k3d if you need k3d).
limactl shell sagibeast-testbox -- bash /repo/infra/testbox/bootstrap.sh

# Verify step-ca root is trusted.
limactl shell sagibeast-testbox -- \
  step certificate verify \
  /etc/ssl/certs/sagibeast-root.crt \
  --ca-url "$SAGIBEAST_CA_URL"

# Smoke: verify pytest can collect (catches pythonpath=["src"] foot-gun).
limactl shell sagibeast-testbox -- bash -c "cd /repo && pytest --collect-only -q"
```

If `step certificate verify` fails, re-run bootstrap with `SAGIBEAST_CA_URL` exported:

```bash
limactl shell sagibeast-testbox -- bash -c "SAGIBEAST_CA_URL=${SAGIBEAST_CA_URL} bash /repo/infra/testbox/bootstrap.sh"
```

If `pytest --collect-only` fails with `ModuleNotFoundError`, check that `src/` is on
the testbox's `PYTHONPATH` via `pyproject.toml:pythonpath = ["src"]` and that the
project was installed with `pip install -e .[test]`.

Run `pytest --collect-only -q` before any full E2E suite — this step confirms
`pythonpath = ["src"]` is resolved. The `pyproject.toml` setting is silently ignored
if pytest is invoked from a subdirectory or if the package is not installed with
`pip install -e .`. Catching this early saves 20+ minutes of a failed E2E run.

#### Register the GitHub Actions runners

The sagibeast workflows pin the **heavy** docker-stack job to
`["self-hosted", "sagibeast-testbox"]` and the **light** lint job (the required
`pre-commit` check) to `["self-hosted", "cmai-lint"]`. Register **one** heavy runner
plus a **cmai-lint pool** (3 runners matches the original setup so lint jobs do not
queue behind each other). Each runner needs its own registration token and its own
directory. The custom label is not applied automatically from the name (#572).

```bash
# 1) Heavy runner (integration lane, E2E). ~/actions-runner ships with the base image.
REG_TOKEN=$(gh api -X POST repos/macatocz/sagibeast/actions/runners/registration-token --jq '.token')
limactl shell sagibeast-testbox -- bash -c "cd ~/actions-runner && \
  ./config.sh \
    --url https://github.com/macatocz/sagibeast \
    --token ${REG_TOKEN} \
    --name sagibeast-testbox \
    --labels self-hosted,sagibeast-testbox \
    --unattended --replace && \
  sudo ./svc.sh install lima && sudo ./svc.sh start"

# 2) cmai-lint pool — clone the runner tree into 3 dirs, register each with a fresh token.
for n in 1 2 3; do
  TOK=$(gh api -X POST repos/macatocz/sagibeast/actions/runners/registration-token --jq '.token')
  limactl shell sagibeast-testbox -- bash -c "
    DIR=~/actions-runner-lint-${n}
    [ -d \"\$DIR\" ] || { cp -a ~/actions-runner \"\$DIR\"; \
      rm -f \"\$DIR\"/.runner \"\$DIR\"/.credentials* \"\$DIR\"/.service; \
      rm -rf \"\$DIR\"/_work \"\$DIR\"/_diag; }
    cd \"\$DIR\" && ./config.sh \
      --url https://github.com/macatocz/sagibeast \
      --token ${TOK} \
      --name sagibeast-testbox-lint-${n} \
      --labels self-hosted,cmai-lint \
      --unattended --replace && \
    sudo ./svc.sh install lima && sudo ./svc.sh start"
done

# Verify all four are online with the right labels.
gh api repos/macatocz/sagibeast/actions/runners \
  --jq '.runners[] | [.name, .status, ([.labels[].name]|join(","))]'
```

The verify line must show `sagibeast-testbox` with label `sagibeast-testbox` and three
`sagibeast-testbox-lint-N` with label `cmai-lint`, all `online`. If a runner shows only
`self-hosted,Linux,ARM64`, the `--labels` flag was dropped — re-run `config.sh` with
`--replace` to recover.

If GitHub reports "Registration was not found ... deleted for runners that have not
connected recently", the server pruned a long-idle registration — run `config.sh
remove --token <T>` then re-register as above.

Re-provisioning the VM resets every runner registration. Always re-run this whole
step (heavy + `cmai-lint` pool) with the explicit `--labels` after any reprovision.

## Output Audit Entry

Emit a JSONL audit entry at the start of each provisioning step executed. Use the `event`
values below — one line per step reached:

```json
{"event": "sagibeast-create-testbox.preflight", "runtime": "lima|ec2|hetzner", "status": "ok"}
{"event": "sagibeast-create-testbox.lima-config", "template": "infra/testbox/lima.yaml", "status": "ok"}
{"event": "sagibeast-create-testbox.launch", "name": "sagibeast-testbox", "cpus": 4, "mem": "8GiB", "disk": "64GiB", "status": "Running"}
{"event": "sagibeast-create-testbox.shell-access", "endpoint": "127.0.0.1:60022", "status": "ok"}
{"event": "sagibeast-create-testbox.bootstrap", "with_k3d": false, "status": "ok"}
{"event": "sagibeast-create-testbox.runner-register", "runners": ["sagibeast-testbox", "sagibeast-testbox-lint-1", "sagibeast-testbox-lint-2", "sagibeast-testbox-lint-3"], "status": "ok"}
```

Always emit `sagibeast-create-testbox.preflight` first. Emit subsequent entries only for the
steps actually completed — omit steps that were skipped or not reached.
