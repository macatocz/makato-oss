---
name: sagibeast-create-testbox
description: Provision a sagibeast testbox VM (Multipass, EC2, or Hetzner) for E2E parity testing. Use when creating testbox, provisioning testbox, spinning up vm, new sagibeast vm.
version: "1.1.0"
argument-hint: "[runtime] [cpus] [memGB] [diskGB] [os]"
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

The testbox is also the preferred runtime for Team-shared multi-day E2E rigs, stable-
egress-IP scenarios, and ADR-0023 brain-only / customer-tier parity testing that a
single laptop cannot physically simulate.

## Mindset: Provision Once, Configure Completely

The four most-skipped steps that cause painful re-provisioning:

1. **Set an OS password during cloud-init.** The AGENT_SUBSTITUTE placeholder in
   `infra/testbox/cloud-init.yaml` must be replaced with a real password before
   `multipass launch`. Without it, `sudo` prompts will stall automation and any future
   `chpasswd` reset requires serial console access. Fetch a generated password from
   1Password: `op item create --category login --title sagibeast-testbox-os-password
   --generate-password 32,letters,digits`.

2. **Append `ServerAliveInterval 5` to `~/.ssh/config`.** Without it, a `multipass
   exec` or plain SSH session drops silently mid-run, leaving `pytest -m e2e` orphaned
   in the background and the Brain-PG pool unreleased. Add the block once:

   ```text
   Host sagibeast.testbox
       ServerAliveInterval 5
       ServerAliveCountMax 1
   ```

3. **Trust the project step-ca root before the first API call.** `bootstrap.sh` does
   this automatically, but if you skip bootstrap and curl a Brain/Body endpoint directly,
   you will get a TLS certificate error that looks like a service misconfiguration.
   Run `step ca root --ca-url "$SAGIBEAST_CA_URL" | sudo tee
   /usr/local/share/ca-certificates/sagibeast-root.crt && sudo update-ca-certificates`
   exactly once after first boot.

4. **Register the GitHub Actions runner with the `sagibeast-testbox` label.** The
   sagibeast workflows (`post-merge.yml`, `sensors.yml`, `spec-docs.yml`,
   `archive-spec.yml`) route testbox jobs onto `["self-hosted", "sagibeast-testbox"]`
   when `CI_RUNNER=self-hosted`. `sagibeast-testbox` is the runner **name** — it is
   NOT automatically a runner **label**. If the runner is registered without an
   explicit `--labels self-hosted,sagibeast-testbox`, it comes up with only the
   default `self-hosted,Linux,ARM64` set, no job requesting the custom label ever
   schedules, and every such workflow sits `queued` for GitHub's 24 h ceiling before
   being killed as `cancelled` — surfacing a red `sync-status` check on every PR
   (#572). Always pass the label explicitly at registration (see [§6/6](#66-bootstrap-and-verify)),
   and re-assert it after any re-provisioning.

## Navigation

| Your situation | Use this skill |
| --- | --- |
| No testbox exists yet, you need one | **This skill** (`sagibeast-create-testbox`) |
| Testbox exists, you need to SSH in | `sagibeast-connect-testbox` |
| Testbox exists, you need port-forward | `sagibeast-connect-testbox --port-forward` |
| Testbox exists, you need k3d cluster | `sagibeast-connect-testbox --k3d` |
| Testbox exists, you need to sync creds | `sagibeast-connect-testbox --sync-creds` |
| Testbox exists but `multipass list` shows Stopped | `sagibeast-connect-testbox` (it will start first) |
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

### [0/6] Pre-flight checks

Verify all dependencies exist before spending time on provisioning:

```bash
# Multipass runtime
multipass version
# OR for EC2:
aws sts get-caller-identity
# OR for Hetzner:
hcloud version

# 1Password CLI signed in
op whoami

# step-ca root present locally
step ca root --ca-url "$SAGIBEAST_CA_URL"
```

If `SAGIBEAST_CA_URL` is not set, check `infra/testbox/bootstrap.sh` and the project
`.env.local` for the correct URL.

If `op whoami` fails, run `op signin` before continuing.

### [1/6] Install Multipass if missing

```bash
# macOS (Apple Silicon or Intel)
brew install --cask multipass

# Verify
multipass version
```

For EC2 or Hetzner runtimes, skip this step — use the provider CLI instead.

### [2/6] Abort if testbox already exists

```bash
if multipass list | grep -q sagibeast-testbox; then
  echo "ERROR: sagibeast-testbox already exists."
  echo "Use sagibeast-connect-testbox instead."
  exit 1
fi
```

If you need to reprovision from scratch: `multipass delete sagibeast-testbox &&
multipass purge`. This is destructive — confirm first.

### [3/6] Prepare cloud-init

```bash
# Copy cloud-init template
cp infra/testbox/cloud-init.yaml /tmp/sagibeast-cloud-init.yaml

# Substitute OS password (from 1Password)
OS_PASSWORD=$(op item get sagibeast-testbox-os-password --fields password)

# Substitute SSH public key
SSH_PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)

# Apply substitutions
sed -i '' \
  "s|# AGENT_SUBSTITUTE: os-password|${OS_PASSWORD}|g" \
  "s|# AGENT_SUBSTITUTE: ssh-public-key|${SSH_PUB_KEY}|g" \
  /tmp/sagibeast-cloud-init.yaml
```

For k3d parity testing, verify `--with-k3d` is set so `bootstrap.sh` installs k3d.

**Caution:** Replace the AGENT_SUBSTITUTE placeholder before launch — without it, `sudo` prompts stall automation and any future `chpasswd` reset requires serial console access. Use `op item create` to generate and store the password in 1Password first.

### [4/6] Launch the VM

```bash
multipass launch \
  --name sagibeast-testbox \
  --cpus 4 \
  --memory 8G \
  --disk 64G \
  --cloud-init /tmp/sagibeast-cloud-init.yaml \
  ubuntu:24.04

# Wait for Running state
until multipass info sagibeast-testbox | grep -q "State:.*Running"; do
  echo "Waiting for VM to reach Running state..."
  sleep 5
done

echo "VM is Running."
multipass info sagibeast-testbox
```

For EC2: `aws ec2 run-instances --image-id ami-<ubuntu24-arm64> --instance-type m7g.xlarge
--user-data file:///tmp/sagibeast-cloud-init.yaml --block-device-mappings
'[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":64}}]'`

For Hetzner: `hcloud server create --name sagibeast-testbox --type cx31
--image ubuntu-24.04 --user-data-from-file /tmp/sagibeast-cloud-init.yaml`

**Caution:** Minimum 64 GB disk. Ubuntu base (~6 GB) + Docker layer cache (~22 GB) + k3d image cache (~8 GB) + pgvector + bge-m3 indexes (~12 GB) = ~48 GB before swap, test artefacts, or log growth. Load `@references/sizing-guide.md` for the full breakdown.

**Caution:** The testbox k3d is a dev-tier rig — never peer, VPN-join, or network-connect it to the customer K8s tier (ADR-0023 perimeter). A testbox running k3d for shape-parity must remain isolated.

**Caution:** Provision in a dedicated dev VPC with no route to customer-tier networks — if the production customer-facing API is IP-allowlisted from a known CIDR, a testbox in the same subnet could accidentally reach production endpoints.

### [5/6] Configure local SSH

Append once to `~/.ssh/config`:

```text
Host sagibeast.testbox
    HostName <IP-from-multipass-info>
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 5
    ServerAliveCountMax 1
```

For Multipass, retrieve the IP:

```bash
TESTBOX_IP=$(multipass info sagibeast-testbox | grep IPv4 | awk '{print $2}')
echo "Add to ~/.ssh/config: HostName ${TESTBOX_IP}"
```

### [6/6] Bootstrap and verify

```bash
# Copy bootstrap script to the VM
multipass transfer infra/testbox/bootstrap.sh sagibeast-testbox:/home/ubuntu/bootstrap.sh

# Run bootstrap (add --with-k3d if you need k3d)
multipass exec sagibeast-testbox -- bash /home/ubuntu/bootstrap.sh

# Verify step-ca root is trusted
multipass exec sagibeast-testbox -- \
  step certificate verify \
  /etc/ssl/certs/sagibeast-root.crt \
  --ca-url "$SAGIBEAST_CA_URL"

# Smoke: verify pytest can collect (catches pythonpath=["src"] foot-gun)
multipass exec sagibeast-testbox -- bash -c "cd /repo && pytest --collect-only -q"
```

If `step certificate verify` fails, run bootstrap again with `SAGIBEAST_CA_URL` exported.

If `pytest --collect-only` fails with `ModuleNotFoundError`, check that `src/` is on the
testbox's `PYTHONPATH` via `pyproject.toml:pythonpath = ["src"]` and that the project
was installed with `pip install -e .[test]`.

### Register the GitHub Actions runner (label contract)

The sagibeast workflows pin testbox jobs to `["self-hosted", "sagibeast-testbox"]`.
Register the runner with **both** labels explicitly — the custom label is not applied
automatically from the runner name (#572):

```bash
# On the testbox, from the actions-runner install dir.
# Fetch a registration token (scoped to macatocz/sagibeast) on the host first:
REG_TOKEN=$(gh api -X POST repos/macatocz/sagibeast/actions/runners/registration-token --jq '.token')

multipass exec sagibeast-testbox -- bash -c "cd ~/actions-runner && \
  ./config.sh \
    --url https://github.com/macatocz/sagibeast \
    --token ${REG_TOKEN} \
    --name sagibeast-testbox \
    --labels self-hosted,sagibeast-testbox \
    --unattended --replace"

# Verify the label landed (must list sagibeast-testbox, not just the defaults):
gh api repos/macatocz/sagibeast/actions/runners \
  --jq '.runners[] | select(.name=="sagibeast-testbox") | [.name, ([.labels[].name]|join(","))]'
```

The verify line must show `sagibeast-testbox` among the labels. If it shows only
`self-hosted,Linux,ARM64`, the `--labels` flag was dropped and every testbox-routed
workflow will hang `queued` for 24 h — re-run `config.sh` with `--replace`.

**Caution:** Re-provisioning the VM resets the runner registration. Always re-run this
step with the explicit `--labels self-hosted,sagibeast-testbox` after any reprovision —
the label is the load-bearing contract the workflows' `runs-on` expressions depend on.

**Caution:** Use `op run -- <command>` per invocation for tenant credentials — never export tenant API keys, DEKs, or service account tokens as long-lived shell env vars on the testbox. Long-lived env vars are a secret-exfiltration risk on shared testboxes.

**Caution:** Tenant skill encryption keys live in `vault://tenants/{tenant_id}/skills/encryption_key` — never write them to disk on the testbox (ADR-0021 customer IP isolation). Fetch via `op run --` per invocation only.

**Caution:** Each developer's testbox must provision its own Brain-PG container — never point two testboxes at the same Brain-PG. Doing so violates the ADR-0020 bilateral split and contaminates checkpoint rows across developers.

**Caution:** Run `pytest --collect-only -q` before any full E2E suite — this confirms `pythonpath = ["src"]` is resolved. The `pyproject.toml` setting is silently ignored if pytest is invoked from a subdirectory or if the package is not installed with `pip install -e .`. Catching this saves 20+ minutes of a failed E2E run.
