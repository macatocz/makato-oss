# Connecting to the vast.ai dev instance

The makato + SAGIBEAST all-in-one dev box runs on a single vast.ai GPU **VM** instance
(RTX 4090 48 GB, Ubuntu 22.04 `vastai/kvm` image). This doc covers how to reach it. For the
architecture and provisioning rationale see the SAGIBEAST deployment plan
(`sagibeast/specs/research-llm-hosting/06-vast-ai-deployment-plan.md`).

> Instance IP, ports, and ID are **ephemeral** — they change every time the box is destroyed and
> re-provisioned (vast.ai cannot resize in place). Always re-read the current values with the
> `vastai` CLI rather than hardcoding them.

## Prerequisites

- **vastai CLI** authenticated against the team account that holds the credit:

  ```bash
  pipx install vastai            # or: uv tool install vastai
  vastai set api-key <TEAM_API_KEY>
  vastai show user               # confirm can_pay=True and non-zero credit
  ```

- **SSH key** `~/.ssh/vast_makato` on your machine. The matching public key must be attached to
  the instance. Team accounts cannot store account-level SSH keys, so the key is attached
  per-instance at/after create time:

  ```bash
  vastai attach ssh <INSTANCE_ID> "$(cat ~/.ssh/vast_makato.pub)"
  ```

## Find the current instance

```bash
vastai show instances                       # list: ID, status, ssh_host/ssh_port
vastai show instance <INSTANCE_ID> --raw    # full detail incl. public_ipaddr and port map
```

Read three things from the output: `public_ipaddr`, the **host port mapped to `22/tcp`** (under
`ports`), and the host ports mapped to the service ports you want to reach (`8080`, `3000`, `8000`).

## SSH access

vast.ai exposes two SSH paths. The **proxy** (`ssh_host:ssh_port`, e.g. `ssh1.vast.ai:31744`) is
often blocked by corporate firewalls on its high port. The **direct** path — the instance's
`public_ipaddr` on the host port mapped to `22/tcp` — is the reliable one:

```bash
# direct (recommended): <IP> + host port mapped to 22/tcp
ssh -i ~/.ssh/vast_makato -p <DIRECT_SSH_PORT> root@<IP>
```

If corporate egress also blocks the direct high port, fall back to the proxy or run the vast.ai
commands from a network that allows it.

## Reaching the stack services

The SAGIBEAST dev stack binds inside the VM on `:8080` (backend console), `:3000` (Langfuse). The
vLLM OpenAI endpoint is on `:8100` (port 8000 is taken by the SAGIBEAST fastapi-brain container).
Those are published to per-instance host ports by vast.ai (see the `ports` map). Prefer an **SSH
tunnel** — it avoids the firewall and lets you use the canonical localhost ports in a browser:

```bash
ssh -i ~/.ssh/vast_makato -p <DIRECT_SSH_PORT> \
    -L 8080:localhost:8080 \
    -L 3000:localhost:3000 \
    -L 8100:localhost:8100 \
    root@<IP>
# then open http://localhost:8080/console/health  and  http://localhost:3000  (Langfuse)
# vLLM health: curl -sf http://localhost:8100/health
```

## Lifecycle & cost control

- The instance runs continuously; nothing stops it on a schedule. Billing (compute and disk)
  continues while the instance exists.
- A GitHub Action in the SAGIBEAST repo (`vast-cheap-scan.yml`) hourly-scans for a cheaper
  VM-capable RTX 4090 48 GB host (all-in ≤ $0.60/h) and opens a GitHub issue when one appears.
- To fully stop costs (including disk), **destroy** the instance — but then it must be
  re-provisioned and re-bootstrapped:

  ```bash
  vastai destroy instance <INSTANCE_ID>
  ```

## Moving to a new instance

Do not re-provision a box that serves real data with `scripts/vast-provision-all.sh` — it refuses
hosts that carry `/etc/default/sagibeast`. To move a live deployment to another instance, follow
the makato-sagibeast skill
[`sagibeast-migrate-instance`](../plugins/makato-sagibeast/skills/sagibeast-migrate-instance/SKILL.md)
(owner decisions up front, warm then cold sync with manifest proof, short cutover, source kept as
rollback).
