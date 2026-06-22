# Troubleshooting — sagibeast-connect-testbox

Extended error-diagnosis reference. The inline `SKILL.md` covers the happy path;
this file covers failure patterns that require more than one diagnostic command.

## Error Handling

| Symptom                              | Likely Cause                          | Diagnosis                                            | Fix                                                                              |
| ------------------------------------ | ------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------- |
| `No such VM: sagibeast-testbox`      | Testbox not provisioned               | `multipass list`                                     | Run `/sagibeast-create-testbox` first                                            |
| VM state `Stopped` or `Suspended`   | VM was stopped or host slept          | `multipass info sagibeast-testbox`                   | `multipass start sagibeast-testbox`; wait for `Running`                          |
| SSH session freezes silently        | Missing `ServerAliveInterval`         | Attempt `Enter` key; if no response, check pid       | Add `ServerAliveInterval 5` to `~/.ssh/config`; kill frozen process             |
| `ssh: connect to host … port 22`    | VM starting or IP changed             | `multipass info sagibeast-testbox` → check IP        | Update `HostName` in `~/.ssh/config`; retry after VM is `Running`               |
| `Host key verification failed`      | VM was reprovisioned; key mismatch    | `ssh-keygen -R sagibeast.testbox`                    | Remove stale host key; reconnect to accept new fingerprint                       |
| `op: no account credentials found` | 1Password CLI not signed in           | `op whoami`                                          | `op signin`; re-run credential sync step [4]                                    |
| Credential sync exits 0 but missing | VM not fully `Running` at sync time   | `multipass info`; check uptime inside VM             | Wait for full boot; re-run `op run --` sync                                     |
| step-ca TLS errors on services      | step-ca root not trusted on testbox   | `step certificate verify <url>`                      | Run step-ca trust commands from step [5] of the skill                           |
| `k3d cluster create` fails          | Docker not running or swap enabled    | `docker info`; `cat /proc/swaps`                     | Start Docker; disable swap (`sudo swapoff -a`)                                  |
| `kubectl: command not found`        | kubectl not installed on testbox      | `which kubectl`                                      | `brew install kubectl` or install via cloud-init bootstrap                      |
| k3d port bind error (e.g. 5432)     | Port already in use on testbox        | `ss -tlnp \| grep 5432`                              | Stop conflicting service or change port mapping in `infra/testbox/k3d.yaml`    |
| `KUBECONFIG` points at wrong cluster| Wrong export or shared shell env      | `kubectl config current-context`                     | Export the correct dev-tier kubeconfig; see NEVER [9] in SKILL.md              |
| Two Brain-PG containers visible      | Dev-tier and customer-tier both up    | `docker ps --filter name=brain`                      | Confirm container name has `dev` prefix before port-forwarding; see NEVER [3]  |
| `tenant_skills/<id>/` found mounted | ADR-0021 violation detected           | `ls -la ~/tenant_skills/ 2>/dev/null`                | Abort session; rotate tenant DEK via OpenBao immediately                        |
| VSCode Remote-SSH disconnects loop  | Server process killed by OOM          | `journalctl -u user@1000 -n 50` on testbox           | Increase Multipass memory (`multipass set sagibeast-testbox.memory=16G`)        |
| JetBrains Gateway "IDE not started" | Gateway project path wrong or no JDK  | Check Gateway log under Help → Show Log              | Set remote project path explicitly; ensure JDK 21+ on testbox                  |
| `tmux: no server running`           | No tmux session exists yet            | `tmux ls 2>&1`                                       | `tmux new-session -s e2e` — then run your long process inside it               |
| Port forward exits immediately       | `-N` flag missing from background cmd | Check process: `ps aux \| grep 'ssh -fT'`            | Kill and rerun with `ssh -fNT -L ...`; see NEVER [6] in SKILL.md              |

## Layer-by-layer diagnostic checklist

Run these in order to avoid misdiagnosing a VM-layer problem as a credential problem.

```bash
# Layer 1 — VM state
multipass info sagibeast-testbox

# Layer 2 — SSH transport
ssh -o ConnectTimeout=5 sagibeast.testbox echo OK

# Layer 3 — Credential availability (inside VM)
ssh sagibeast.testbox 'op account list'

# Layer 4 — Service reachability (example: Brain-PG)
ssh sagibeast.testbox 'pg_isready -h 127.0.0.1 -p 5432'
```

If any layer fails, fix it before descending to the next layer.
