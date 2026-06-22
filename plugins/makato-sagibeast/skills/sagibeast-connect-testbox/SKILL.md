---
name: sagibeast-connect-testbox
description: Connect to or resume a sagibeast testbox VM — SSH, port-forward, credential sync, k3d. Use for: connect to testbox, ssh to testbox, port forward, sync creds, resume testbox, k3d testbox.
version: "1.0.0"
argument-hint: "port-forward <local>:<remote> | --sync-creds | --k3d | --step-ca | --ide vscode | --ide jetbrains | --tmux"
allowed-tools: Bash Read Write
---

# Connect Testbox

Connects to an existing sagibeast testbox VM. See `/sagibeast-create-testbox` to provision
a new VM. The default sagibeast inner loop uses Docker Compose locally (Track 1); provision
a testbox only when the scenario genuinely requires it.

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

## Workflow

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

For cloud VMs:

```bash
# AWS
aws ec2 start-instances --instance-ids <instance-id>
aws ec2 wait instance-running --instance-ids <instance-id>

# Hetzner
hcloud server power-on sagibeast-testbox
```

For extended error diagnosis, load `@references/troubleshooting.md`.

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

**Caution:** `ServerAliveInterval 5` is required — without it, testbox VMs drop idle TCP connections silently; the session freezes rather than disconnecting, requiring a kill of the SSH process and a second session to recover.

**Caution:** Use `tmux new-session -s e2e` before starting any long-running process (`pytest -m e2e`, `k3d cluster create`, `langgraph dev`) — SSH sends SIGHUP to the foreground process group on disconnect. `tmux attach -t e2e` after a drop is the only reliable recovery path.

**Caution:** On connect, check for mounted tenant skill trees: `ls ~/tenant_skills/ 2>/dev/null` — if found, abort the session immediately and rotate the tenant DEK via OpenBao. Testboxes may be accessible to multiple team members; tenant skill encryption keys must never leave vault (ADR-0021).

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

**Caution:** Before forwarding 5432, confirm the container name includes `dev` (`docker ps --filter name=brain`) — the bilateral PG split (ADR-0020) means two Brain-PG instances exist in staging; forwarding the wrong one silently exposes customer Class A/B data over an unencrypted local port.

**Caution:** Always use `-fNT` together for background tunnels — without `-N`, SSH opens a shell alongside the tunnel; closing the shell does not close the tunnel, leaving leaked open ports on the testbox.

### [4] Credential sync

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

**Caution:** Confirm the VM is fully `Running` before syncing credentials — a starting VM may accept the SSH connection but silently fail writes to the runtime environment; the sync command may exit 0 while credentials are absent.

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
kubectl get nodes
```

Delete the ephemeral kubeconfig file on the testbox after export:

```bash
ssh sagibeast.testbox "rm /tmp/sagibeast-dev.kubeconfig"
```

**Caution:** Never set `KUBECONFIG` to the production Mac Studio brain-only cluster from a testbox — the ADR-0023 deployment runs a dedicated brain-only K8s cluster with real customer checkpoint data; cross-connecting it from a shared testbox violates the ADR-0023 perimeter and risks data exfiltration. The testbox k3d is dev-tier only.

**Caution:** Create per-developer namespaces (`kubectl create namespace dev-<yourname>`) and set the namespace before any `kubectl apply` — a shared default namespace means one developer's apply can overwrite another's Deployment and Brain-PG fixtures.

### [7] SSH agent forwarding

```bash
ssh-add ~/.ssh/id_ed25519
```

The `~/.ssh/config` block (step [2]) sets `ForwardAgent yes`. This enables git operations
inside the testbox without copying private keys onto it.

**Caution:** Only add the specific key needed (`ssh-add ~/.ssh/id_ed25519`) — never `ssh-add -A`; adding all identities grants every process on the testbox access to every SSH key on your local agent, and testboxes may be shared during pair sessions.

**Caution:** `ForwardAgent yes` in `~/.ssh/config` is required — without it, the 1Password SSH socket forwarding fails with an opaque "no suitable identity" error that looks identical to expired credentials.

### [8] IDE remote development

**VSCode Remote-SSH**: Install the Remote-SSH extension → Connect to Host →
`sagibeast.testbox`. Ports opened in VSCode terminals are auto-forwarded.

**JetBrains Gateway**: Requires JetBrains Ultimate license. Install Gateway →
New Connection → SSH → `sagibeast.testbox` → select key `~/.ssh/id_ed25519`.
