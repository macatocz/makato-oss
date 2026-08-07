---
name: sagibeast-connect-testbox
description: "Connect to or resume a sagibeast testbox VM — SSH, port-forward, credential sync, k3d. Use for: connect to testbox, ssh to testbox, port forward, sync creds, resume testbox, k3d testbox."
version: "1.1.0"
argument-hint: "port-forward <local>:<remote> | --sync-creds | --k3d | --step-ca | --ide vscode | --ide jetbrains | --tmux"
allowed-tools: Bash Read Write
metadata:
  Authors: Zdenek Stary
  last_updated: "2026-08-05"
---

# Connect Testbox

Connects to an existing sagibeast testbox VM. See `/sagibeast-create-testbox` to provision
a new VM. The default sagibeast inner loop uses Docker Compose locally (L2 — ADR-0024);
provision a testbox only when the scenario genuinely requires it.

## When to Use

- Testbox exists (or is stopped) and you need an SSH session
- You need to port-forward a service from the testbox to localhost
- You need to sync 1Password credentials into the testbox runtime
- You need to bootstrap a k3d cluster on an existing testbox
- You need IDE remote development (VSCode, JetBrains) on the testbox

## When NOT to Use

- No testbox exists yet → run `sagibeast-create-testbox` first
- Running local E2E via Docker Compose (Track 1) — no testbox needed
- You need to provision or reprovision a testbox from scratch

## Philosophy

The testbox is the escape hatch for scenarios that cannot run on a developer's Mac directly:
ARM64 K8s tier-parity validation, long-running E2E suites that must survive a laptop closing,
or isolating tenants from the developer's local Brain-PG. Unlike a direct connection to a
production node, the testbox is ephemeral and holds no customer data — it is disposable.

The connection workflow exists because this bridge has three independent failure modes — VM
state, SSH transport, and credential sync — that manifest with near-identical symptoms but
require completely different fixes. Resolving them in order (state → transport → credentials
→ services) is the only reliable path to a working session.

## Mindset: Think in Layers

Treat every connection failure as a layer problem. Ask at each layer before digging deeper:

1. **VM layer** — Is the testbox actually running? (`multipass info sagibeast-testbox`) A
   stopped VM accepts TCP but produces confusing partial errors.
2. **Transport layer** — Does `ssh sagibeast.testbox` establish a session? Missing keep-alive
   is the most common cause of frozen sessions that look like live connections.
3. **Credential layer** — Are 1Password-sourced credentials present inside the VM? Sync is
   on-demand, not automatic on resume.
4. **Service layer** — Does the target service respond? TLS errors point to step-ca, not
   network issues.

Skipping layers wastes time — a step-ca TLS error after 5 minutes of diagnosis is often a
missing `update-ca-certificates` from 20 seconds of work.

The `@references/troubleshooting.md` layer-by-layer diagnostic checklist mirrors this model
with runnable commands for each layer.

## Navigation

| Goal                               | Argument / Step                                 |
| ---------------------------------- | ----------------------------------------------- |
| Open SSH session                   | `ssh sagibeast.testbox` (no argument)           |
| Forward a local port               | `port-forward <local>:<remote>`                 |
| Sync 1Password credentials         | `--sync-creds`                                  |
| Bootstrap k3d cluster              | `--k3d`                                         |
| Trust step-ca root (first time)    | `--step-ca`                                     |
| Set up VSCode remote dev           | `--ide vscode`                                  |
| Set up JetBrains Gateway           | `--ide jetbrains`                               |
| Attach to existing tmux session    | `--tmux`                                        |
| Resume stopped testbox first       | See step [1] below                              |

## Arguments

| Argument                        | Behaviour                                                       |
| ------------------------------- | --------------------------------------------------------------- |
| `port-forward <local>:<remote>` | Open SSH tunnel; e.g. `5432:5432`                              |
| `--sync-creds`                  | Sync secrets via `op run -- env-file .env.testbox.runtime`     |
| `--k3d`                         | Bootstrap k3d cluster from `infra/testbox/k3d.yaml`           |
| `--step-ca`                     | Trust the project step-ca root certificate                      |
| `--ide vscode`                  | Guide for VSCode Remote-SSH setup                               |
| `--ide jetbrains`               | Guide for JetBrains Gateway setup                               |
| `--tmux`                        | `ssh sagibeast.testbox -t tmux attach -t e2e`                  |
| (none)                          | Open interactive SSH session only                               |

## No-Argument Routing

If invoked without an argument, use `AskUserQuestion` to route the caller before proceeding:

```
What do you need to do with the testbox?
  1. Open an SSH session
  2. Forward a port (e.g. Brain-PG 5432, Temporal 7233)
  3. Sync 1Password credentials into the testbox
  4. Bootstrap a k3d cluster
  5. Set up IDE remote development (VSCode or JetBrains)
  6. Attach to an existing tmux session
```

Execute only the steps relevant to the selected mode; do not run the full workflow.

## Anti-Patterns

Read before executing the workflow. Each item is a non-obvious failure mode that wastes
significant time when encountered mid-session.

**NEVER-1 — Omit `ServerAliveInterval 5` from `~/.ssh/config`.**
Without it, testbox VMs drop idle TCP connections silently; the session freezes rather than
disconnecting, requiring a kill of the SSH process and a second session to recover. There is
no symptom that distinguishes a frozen session from a working one without this guard.

**NEVER-2 — Start long-running processes without tmux.**
`pytest -m e2e`, `k3d cluster create`, and `langgraph dev` run in the foreground of the SSH
session. SSH sends SIGHUP to the foreground process group on disconnect; the process is killed
with no output. Use `tmux new-session -s e2e` before any long-running command; `tmux attach
-t e2e` is the only reliable recovery path after an accidental disconnect.

**NEVER-3 — Port-forward 5432 without confirming the `dev` container.**
The bilateral PG split (ADR-0020) means Brain-PG (Class A) and Body-PG (Class B) are separate
instances. Forwarding the wrong one silently exposes customer data over an unencrypted local
port. Always confirm the container name includes `dev` (`docker ps --filter name=brain`) before
forwarding 5432.

**NEVER-4 — Ignore mounted tenant skill trees on connect.**
If `ls ~/tenant_skills/ 2>/dev/null` returns entries, abort immediately and rotate the tenant
DEK via OpenBao. Testboxes may be accessible to multiple team members; tenant skill encryption
keys must never leave vault (ADR-0021). Proceed only after confirming the directory is absent.

**NEVER-5 — Run background port forward without `-fNT` together.**
Without `-N`, SSH opens a shell alongside the tunnel; closing that shell does not close the
tunnel, leaving leaked open ports on the testbox. The correct form is always `ssh -fNT -L ...`.

**NEVER-6 — Sync credentials before the VM is fully `Running`.**
A starting VM may accept the SSH connection but silently fail writes to the runtime environment.
`op run --` exits 0 while credentials are absent — the credential layer appears healthy but
service calls fail opaquely. Confirm `multipass info` shows `Running` and uptime before syncing.

**NEVER-7 — Cross-connect the testbox k3d to the production Mac Studio cluster.**
The ADR-0023 deployment runs a dedicated brain-only K8s cluster with real customer checkpoint
data. Setting `KUBECONFIG` to the production cluster from a shared testbox violates the
ADR-0023 perimeter and risks data exfiltration. The testbox k3d is dev-tier only; always
export and use `~/.kube/sagibeast-dev.kubeconfig`.

**NEVER-8 — Apply to the k3d `default` namespace without creating a developer namespace.**
A shared default namespace means one developer's `kubectl apply` can silently overwrite
another's Deployment and Brain-PG fixtures. Create `kubectl create namespace dev-<yourname>`
and set it as the default before any `kubectl apply`.

**NEVER-9 — Run `ssh-add -A` for agent forwarding.**
Adding all identities grants every process on the testbox access to every SSH key on your
local agent; testboxes may be shared during pair sessions. Only add the specific key needed:
`ssh-add ~/.ssh/id_ed25519`.

**NEVER-10 — Remove `ForwardAgent yes` from `~/.ssh/config` to "harden" the connection.**
Without it, the 1Password SSH socket forwarding fails with an opaque "no suitable identity"
error that looks identical to expired credentials. The two failure modes are indistinguishable
without knowing that ForwardAgent controls socket availability.

## Workflow

> For any connection failure at any step, load `@references/troubleshooting.md`.
> Do NOT load it on the happy path — it adds diagnostic depth not needed when each step
> succeeds.

### [1] Check and resume if stopped

```bash
multipass info sagibeast-testbox
```

If state is `Stopped`:

```bash
multipass start sagibeast-testbox
# Wait until status shows Running
multipass info sagibeast-testbox
```

If no VM exists at all → run `/sagibeast-create-testbox` first.

For cloud VMs (AWS or Hetzner), start the instance via standard CLI
(`aws ec2 start-instances` / `hcloud server power-on`) and wait for `Running` state before
continuing. Note: cloud IPs change on restart — update `HostName` in `~/.ssh/config` after
every start; Multipass manages this automatically via `sagibeast.testbox` hostname resolution.

### [2] SSH connection

```bash
ssh sagibeast.testbox
```

**Ensure SSH keep-alive is configured** (`~/.ssh/config`):

```text
Host sagibeast.testbox
    HostName <testbox-ip>
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 5
    ServerAliveCountMax 1
    ForwardAgent yes
```

Append this block once via `sagibeast-create-testbox` step [5]; it is idempotent.

→ NEVER-1: missing `ServerAliveInterval 5` causes silent session freeze.
→ NEVER-4: check for mounted tenant skill trees immediately after connect.
→ NEVER-10: `ForwardAgent yes` is required for 1Password SSH socket forwarding.

### [3] Port forwarding

**Interactive (foreground):**

```bash
ssh -L <local>:localhost:<remote> sagibeast.testbox
```

**Background (non-interactive):**

```bash
ssh -fNT -L <local>:localhost:<remote> sagibeast.testbox
```

Common port mappings (dev-tier only):

| Service         | Local  | Remote | Notes                                    |
| --------------- | ------ | ------ | ---------------------------------------- |
| Brain-PG        | 5432   | 5432   | dev-tier Brain-PG only                  |
| Body-PG         | 5433   | 5433   | dev-tier Body-PG only                   |
| Temporal        | 7233   | 7233   | workflow engine gRPC                     |
| Langfuse        | 3000   | 3000   | tracing UI                               |
| Brain API       | 8000   | 8000   | FastAPI Brain                            |
| Body API        | 8001   | 8001   | FastAPI Body                             |

To stop a background forward:

```bash
ps aux | grep 'ssh -fNT' | awk '{print $2}' | xargs kill
```

→ NEVER-3: confirm `dev` container before forwarding 5432.
→ NEVER-5: always use `-fNT` together for background tunnels.

### [4] Credential sync

**Prerequisite — `.env.testbox.runtime`:** This file is not committed to git and is not
created automatically. It must exist in the project root on your local machine before
running credential sync. Each line maps an environment variable name to a 1Password secret
reference (`op://vault/item/field` format). Copy the template from your team's 1Password
vault under the `sagibeast-testbox` item.

```bash
op run -- env-file .env.testbox.runtime -- ssh sagibeast.testbox
```

Or, to write an ephemeral `.env` inside the testbox:

```bash
op run --env-file .env.testbox.runtime -- bash -c \
  'ssh sagibeast.testbox "cat > ~/.env.runtime" < <(env)'
```

Credentials are short-lived and in-memory only. Do NOT write them to disk permanently
on the testbox.

→ NEVER-6: confirm VM is fully `Running` before syncing — sync may exit 0 while creds absent.

### [5] Trust step-ca root (run once per testbox)

```bash
step ca root | sudo tee /usr/local/share/ca-certificates/sagibeast-root.crt
sudo update-ca-certificates
```

Verify:

```bash
step certificate verify <service-url>
```

### [6] k3d cluster bootstrap

```bash
# On the testbox — after SSH in
k3d cluster create --config /path/to/sagibeast/infra/testbox/k3d.yaml
```

Or, if you have the repo on the testbox already:

```bash
k3d cluster create --config infra/testbox/k3d.yaml
```

Export kubeconfig back to your local machine (no checked-in kubeconfigs):

```bash
# On testbox
k3d kubeconfig get sagibeast-dev > /tmp/sagibeast-dev.kubeconfig

# On local machine
scp sagibeast.testbox:/tmp/sagibeast-dev.kubeconfig ~/.kube/sagibeast-dev.kubeconfig
export KUBECONFIG=~/.kube/sagibeast-dev.kubeconfig
```

Delete the ephemeral kubeconfig file on the testbox after export:

```bash
ssh sagibeast.testbox "rm /tmp/sagibeast-dev.kubeconfig"
```

→ NEVER-7: never cross-connect this k3d kubeconfig to the production Mac Studio cluster.
→ NEVER-8: create a per-developer namespace before any `kubectl apply`.

### [7] SSH agent forwarding

```bash
ssh-add ~/.ssh/id_ed25519
```

The `~/.ssh/config` block (step [2]) sets `ForwardAgent yes`. This enables git operations
inside the testbox without copying private keys onto it.

→ NEVER-9: only add the specific key needed — never `ssh-add -A` on a shared testbox.

### [8] IDE remote development

**VSCode Remote-SSH**: Install the Remote-SSH extension → Connect to Host →
`sagibeast.testbox`. Ports opened in VSCode terminals are auto-forwarded to localhost
without a separate `port-forward` step.

*Failure: VSCode Remote-SSH disconnects in a loop* — The `vscode-server` process was killed
by OOM. Diagnose with `journalctl -u user@1000 -n 50` on the testbox. Fix: increase Multipass
memory (`multipass set sagibeast-testbox.memory=16G`) and reconnect.

**JetBrains Gateway**: Requires JetBrains Ultimate license. Install Gateway →
New Connection → SSH → `sagibeast.testbox` → select key `~/.ssh/id_ed25519`.

*Failure: Gateway shows "IDE not started"* — Either the remote project path is wrong or JDK
21+ is absent on the testbox. Check the Gateway log under Help → Show Log; set the remote
project path explicitly and ensure `java --version` returns 21+ on the testbox.

→ NEVER-2: start long-running E2E processes inside `tmux` before connecting your IDE.

## Output Audit Entry

Emit a JSONL audit entry at session start (`connect`) and at the beginning of each major step
executed. Use the `event` values below — one line per step reached:

```json
{"event": "sagibeast-connect-testbox.connect", "testbox": "sagibeast-testbox", "state": "Running"}
{"event": "sagibeast-connect-testbox.port-forward", "local": "<local>", "remote": "<remote>"}
{"event": "sagibeast-connect-testbox.sync-creds", "status": "ok"}
{"event": "sagibeast-connect-testbox.k3d", "config": "infra/testbox/k3d.yaml", "status": "ok"}
{"event": "sagibeast-connect-testbox.step-ca", "status": "ok"}
{"event": "sagibeast-connect-testbox.ide", "ide": "vscode|jetbrains", "status": "ok"}
{"event": "sagibeast-connect-testbox.tmux", "session": "e2e", "status": "ok"}
```

Always emit `sagibeast-connect-testbox.connect` first. Emit subsequent entries only for the
steps actually executed in the session — omit steps that were skipped.
