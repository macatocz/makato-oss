# Vast.ai OMP + local LLM development workstation plan

This plan turns the Vast.ai GPU instance into a self-contained SAGIBEAST development
workstation:

- vLLM serves the repository's open model locally.
- [oh-my-pi (OMP)](https://github.com/can1357/oh-my-pi) is the agent harness.
- Every Makato marketplace plugin is available to OMP.
- A Git-backed SAGIBEAST checkout is the workspace for interactive and autonomous work.
- `makato-orchestrate` can poll the SAGIBEAST GitHub Project and launch headless OMP
  sessions through its loop scripts.

For general Vast.ai lifecycle and port information, also see
[`vast-ai-access.md`](./vast-ai-access.md).

> **Plan status:** re-analysed against the live instance on 2026-08-26 through
> `ssh -p 59889 root@92.180.27.84`. The IP and SSH port are instance-specific and will
> change after a Vast.ai migration or re-create.

## Goal and completion definition

The installation is complete only when all of the following are true:

1. OMP can call the local `open` model through vLLM with a 65,536-token context.
2. OMP discovers all 14 Makato plugins, their 82 current skills, and their 27 current
   custom agents.
3. `/workspace/sagibeast` is a clean Git checkout with authenticated GitHub push,
   Projects v2, issue, pull-request, and workflow access.
4. SAGIBEAST's Python 3.14 and Node 24 development commands pass from that checkout.
5. A headless `omp --yolo -p ...` smoke test can read a Makato skill and invoke a
   subagent tool.
6. `loop.sh` can poll and dry-run the SAGIBEAST board, and its systemd service survives
   a normal instance stop/start.
7. The global `~/.claude/HALT` kill switch stops new autonomous dispatch.

This is goal-mode infrastructure work. It does not change SAGIBEAST product behavior.

## Verified remote baseline

The previous runbook described a working post-bootstrap box. That is not the current
state. The live audit found:

| Surface | Verified state on 2026-08-26 |
| --- | --- |
| OS | Ubuntu 22.04, kernel `5.15.0-1067-kvm` |
| GPU | One RTX 4090 exposed with 49,140 MiB VRAM, compute capability 8.9 |
| Driver | `535.183.01`; below the CUDA 13 / vLLM requirement |
| Host resources | 98 GiB RAM, no swap; root disk 97 GiB with 67 GiB free |
| vLLM | No `vllm.service`; port 8100 closed |
| OMP | Not installed; `/root/.omp` absent |
| Required loop tools | `gh`, `jq`, `uv`, Node, npm, and pnpm absent |
| Present tools | Git 2.34.1, Python 3.10.12, tmux, Docker client 29.1.3 |
| Docker compatibility | Client API 1.52, daemon API 1.43; commands fail unless `DOCKER_API_VERSION=1.43` |
| SAGIBEAST runtime | 19 containers running; ports 8000, 8080, 3000, and 5432 already occupied |
| Runtime source | Containers bind-mount `/opt/sagibeast`; it is a plain deployment snapshot, not Git |
| Extra snapshot | `/root/sagibeast` exists but is also not Git and is not the live containers' source |
| GitHub access | No `gh` installation and no usable GitHub SSH credential |
| Makato checkout | `/root/makato-oss` absent |
| Vast environment | `/etc/environment` contains duplicated Vast-injected keys but currently sources successfully |

The current containers prove the box is not empty, but they do **not** make it a safe
development checkout. Autonomous agents must never treat `/opt/sagibeast` or
`/root/sagibeast` as their Git root.

## Target layout

| Path or service | Purpose |
| --- | --- |
| `/root/makato-oss` | Git checkout that owns vLLM config and Makato loop scripts |
| `/workspace/sagibeast` | Clean SAGIBEAST Git checkout and autonomous loop working directory |
| `/opt/sagibeast` | Existing live deployment snapshot; kept separate from agent worktrees |
| `/root/.local/bin/omp` | Pinned OMP executable |
| `/root/.omp/agent/models.yml` | OMP local OpenAI-compatible provider and model definition |
| `/root/.omp/agent/config.yml` | OMP roles mapped to `local/open` with qwen3 tool formatting |
| `/root/.omp/plugins` | OMP marketplace registry, cache, and enabled-plugin state |
| `/root/vllm-venv` | Isolated Python 3.12 vLLM environment |
| `/root/.cache/huggingface` | Gated model token and approximately 27 GiB model cache |
| `vllm.service` | Local OpenAI-compatible model endpoint on port 8100 |
| `makato-sagibeast-loop.service` | Long-running, single-threaded autonomous board poller |
| `/workspace/sagibeast/.claude/state` | Loop PID, status, watchdog, and audit state |
| `/root/.claude/HALT` | Host-global autonomous kill switch |

The existing SSH tunnel remains:

```bash
ssh -p 59889 -i ~/.ssh/vast_makato root@92.180.27.84 \
  -L 8080:localhost:8080
```

OMP and vLLM communicate entirely on the remote host; no tunnel for port 8100 is
required and port 8100 must not be added to Vast.ai's public port mappings.

## Implementation plan

### Phase 0 - Capture state and reserve a maintenance window

Upgrading the NVIDIA driver reboots the instance. The running SAGIBEAST stack will be
unavailable during that reboot and while its containers recover.

```bash
export DOCKER_API_VERSION=1.43

date -Is
nvidia-smi
df -h /
free -h
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker compose ls
```

Do not begin unless at least 45 GiB is free. The model needs about 27 GiB, and OMP,
Python 3.14, the SAGIBEAST virtual environment, frontend dependencies, build caches,
and Git worktrees need operating headroom.

### Phase 1 - Repair the base environment and install host tools

#### 1.1 Normalise Vast.ai's duplicated environment file

Vast.ai may re-inject duplicate keys on reboot. Back up the file, keep the first value
for each key, and quote values containing spaces:

```bash
cp -a /etc/environment "/etc/environment.bak.$(date +%s)"
python3 - <<'PY'
seen = set()
out = []
for line in open("/etc/environment", encoding="utf-8").read().splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key in seen:
        continue
    seen.add(key)
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    rendered = f'{key}="{value}"' if " " in value else f"{key}={value}"
    out.append(rendered)
open("/etc/environment", "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
sh -c '. /etc/environment && echo ENV-OK'
```

Repeat the `ENV-OK` check after the driver reboot. Do not run `apt` while this check
fails.

#### 1.2 Install baseline packages and a current GitHub CLI

Ubuntu 22.04's stock `gh` package is too old for the Projects v2 operations used by
Makato. Use GitHub's maintained apt repository:

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg git jq tmux build-essential

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf '%s\n' \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh
```

Use a shell-local Docker client/daemon compatibility override until the planned reboot
restarts the daemon at the installed version:

```bash
export DOCKER_API_VERSION=1.43
docker version
```

#### 1.3 Install Node 24, uv, and pinned OMP

Node is required by the SAGIBEAST frontend and the Playwright MCP declared by
`makato-ux`.

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="/root/.local/bin:$PATH"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' /root/.profile ||
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.profile

# Audited current OMP release on 2026-08-26. Upgrade only after the smoke gates below.
curl -fsSL https://omp.sh/install |
  sh -s -- --binary --ref v18.0.6

node --version
npm --version
uv --version
omp --version
gh --version
jq --version
```

The official OMP installer supports `--binary --ref`; pinning avoids an unreviewed
harness update changing headless behavior during an autonomous run.

### Phase 2 - Authenticate GitHub and create real checkouts

Authenticate interactively once. Do not place a PAT in shell history, an environment
file, or the repository:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth refresh --hostname github.com --scopes repo,project,workflow,read:org
gh auth setup-git

gh auth status --hostname github.com
gh project view 1 --owner macatocz
gh repo view macatocz/sagibeast
gh repo view macatocz/makato-oss
```

Create separate Git checkouts. Do not initialise Git inside either deployment
snapshot:

```bash
install -d -m 0755 /workspace
gh repo clone macatocz/makato-oss /root/makato-oss
gh repo clone macatocz/sagibeast /workspace/sagibeast

git -C /root/makato-oss status --short --branch
git -C /workspace/sagibeast status --short --branch
git -C /workspace/sagibeast remote -v
```

Configure a GitHub-compatible commit identity from the authenticated account:

```bash
GH_LOGIN="$(gh api user --jq .login)"
GH_ID="$(gh api user --jq .id)"
git config --global user.name "$GH_LOGIN"
git config --global user.email "${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
unset GH_LOGIN GH_ID
```

The SAGIBEAST checkout must contain its committed `.claude/config.json`. Verify the
cached project metadata before any autonomous dispatch:

```bash
jq '{
  project,
  owner: .github_project.owner,
  number: .github_project.number,
  status_field: .github_project.status_field_name,
  known_repos: .github_project.known_repos
}' /workspace/sagibeast/.claude/config.json
```

Expected owner/project is `macatocz` / `1`, and `known_repos` must include
`macatocz/sagibeast`.

### Phase 3 - Install the complete Makato suite into OMP

OMP is compatible with the Claude plugin marketplace format used by
`.claude-plugin/marketplace.json`. Register the local Makato checkout and install
every catalog entry at user scope:

```bash
export PATH="/root/.local/bin:$PATH"

omp plugin marketplace add /root/makato-oss

jq -r '.plugins[].name' /root/makato-oss/.claude-plugin/marketplace.json |
while IFS= read -r plugin; do
  omp plugin install --scope user "${plugin}@makato-suite"
done

omp plugin list
omp plugin doctor
```

The audited checkout contains 14 plugins, 82 skills, and 27 custom agents:

```bash
test "$(jq '.plugins | length' \
  /root/makato-oss/.claude-plugin/marketplace.json)" -eq 14

test "$(find /root/makato-oss/plugins -type f \
  -path '*/skills/*/SKILL.md' | wc -l)" -eq 82

test "$(find /root/makato-oss/plugins -type f \
  -path '*/agents/*.md' | wc -l)" -eq 27
```

Those numbers are an audit baseline, not permanent product constants. If the Makato
checkout intentionally adds or removes capabilities, update the expected inventory
in this document in the same change.

After a Makato update, refresh OMP's marketplace cache before starting new sessions:

```bash
git -C /root/makato-oss pull --ff-only
omp plugin marketplace update makato-suite
omp plugin upgrade --scope user
omp plugin doctor
```

### Phase 4 - Upgrade the GPU driver and bootstrap vLLM

The model is
`bottlecapai/ThinkingCap-Qwen3.6-27B-FP8`. Its `qwen3_5` architecture requires the
pinned vLLM 0.27.1 CUDA 13 build and NVIDIA driver major 580 or newer.

#### 4.1 Store the gated Hugging Face token without shell-history exposure

Request model access first, then:

```bash
install -d -m 0700 /root/.cache/huggingface
read -rsp 'Hugging Face token: ' HF_TOKEN
printf '\n'
umask 077
printf '%s' "$HF_TOKEN" > /root/.cache/huggingface/token
unset HF_TOKEN
chmod 0600 /root/.cache/huggingface/token
```

#### 4.2 Run bootstrap pass 1

```bash
export PATH="/root/.local/bin:$PATH"
cd /root/makato-oss
MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh
```

On the audited driver 535 host this installs driver 580 plus the build toolchain,
reboots immediately, and exits before creating the vLLM environment. That ordering is
mandatory: creating the environment while the old kernel module is loaded installs an
incompatible CUDA build of PyTorch.

#### 4.3 Reconnect and run bootstrap pass 2

```bash
ssh -p 59889 -i ~/.ssh/vast_makato root@92.180.27.84 \
  -L 8080:localhost:8080

sh -c '. /etc/environment && echo ENV-OK'
export PATH="/root/.local/bin:$PATH"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

tmux new-session -d -s vllm-bootstrap \
  'cd /root/makato-oss &&
   export PATH=/root/.local/bin:$PATH &&
   export HF_HUB_DISABLE_XET=1 &&
   MAKATO_HOME=/root/makato-oss bash infra/bootstrap-vllm.sh \
     2>&1 | tee /var/log/makato-bootstrap.log'
tmux attach -t vllm-bootstrap
```

Pass 2 creates `/root/vllm-venv`, downloads the model, installs and enables
`vllm.service`, and installs both OMP v18 configuration files because OMP is
already on `PATH`:

- `infra/omp-models.yml` to `/root/.omp/agent/models.yml` for providers.
- `infra/omp-config.yml` to `/root/.omp/agent/config.yml` for roles and tools.
The audited host's Xet transfer stalled with half-closed connections; disabling Xet keeps
the resumable download on Hugging Face's standard HTTP path.

#### 4.4 Verify the endpoint and OMP model contract

```bash
systemctl is-enabled vllm
systemctl status vllm --no-pager
journalctl -u vllm -n 100 --no-pager

curl -sf http://localhost:8100/health
curl -s http://localhost:8100/v1/models | jq
cd /root/makato-oss
scripts/preflight-omp-context.sh

test -f /root/.omp/agent/models.yml
test -f /root/.omp/agent/config.yml
grep -E 'baseUrl: http://localhost:8100/v1|contextWindow: 65536|maxTokens: 8192' \
  /root/.omp/agent/models.yml
grep -E 'default: local/open|format: qwen3' /root/.omp/agent/config.yml
```

Expected served names include `open` and `qwen3-reasoning`. The preflight must report
`context_length=65536`.

OMP uses the OpenAI-compatible provider from `infra/omp-models.yml` and reads
role routing plus tool format from `infra/omp-config.yml`; OMP v18 ignores those
settings when they are placed in `models.yml`. Do not set `MAKATO_OPEN_ENDPOINT_URL`
or a legacy `ANTHROPIC_BASE_URL` for this local path. Likewise, do not change
vLLM to the `hermes` tool parser. The tested pair is:

- vLLM `tool_call_parser: qwen3_xml`
- OMP `tools.format: qwen3`

The Hermes parser attempts to fetch a gated `chat_template.json` that this offline
deployment does not have.

After the reboot, also confirm the pre-existing stack recovered:

```bash
unset DOCKER_API_VERSION
rm -f /etc/profile.d/docker-api-compat.sh
docker version
docker ps --filter label=com.docker.compose.project=sagibeast \
  --format 'table {{.Names}}\t{{.Status}}'
```

### Phase 5 - Prepare the SAGIBEAST development checkout

SAGIBEAST requires Python 3.14 and uses Node for its frontend:

```bash
export PATH="/root/.local/bin:$PATH"

uv python install 3.14
uv tool install pre-commit
cd /workspace/sagibeast
make dev-setup
npm --prefix frontend ci
npm --prefix frontend run e2e:install
```

Run the smallest host-side baseline that proves the agent can develop the repository:

```bash
cd /workspace/sagibeast
uv run pytest tests/unit -q --no-header
npm --prefix frontend run typecheck
npm --prefix frontend test
```

#### Existing-stack isolation rule

The current SAGIBEAST Compose files declare the fixed project name `sagibeast` and
fixed host ports. `stack-up`, `stack-down`, `stack-reset`, and `stack-test-up` from a
second checkout will operate on or replace the live 19-container deployment rather
than create an isolated stack.

Therefore:

- `/opt/sagibeast` remains the live stack source.
- `/workspace/sagibeast` is the Git and agent workspace.
- Host-side unit, property, lint, typecheck, and frontend tests are safe.
- Agents may connect to the already-running development services for non-destructive
  integration checks.
- An acceptance plan must not invoke a Compose lifecycle target unless it explicitly
  declares that the live development stack may be replaced for that task.
- `stack-reset` is never allowed in autonomous mode on this host.
- Human interactive Compose work and the autonomous loop must not run concurrently.
  Create `/root/.claude/HALT`, stop the loop service, and wait for the active workflow
  to clear first.

True per-worktree full-stack isolation requires a separate SAGIBEAST change to
parameterise the Compose project name and all published host ports. Until that lands,
the fixed-name stack is a shared, serial resource. This constraint does not prevent
Makato skills, agents, local model use, host tests, pull requests, or worktrees from
running.

### Phase 6 - Prove OMP skills, tools, and headless mode

Start a new OMP process after installing or upgrading plugins; active sessions do not
fully reload every plugin capability.

```bash
cd /workspace/sagibeast

omp --yolo -p \
  'Read skill://makato-guide and reply with exactly MAKATO_SKILL_OK.'

omp --yolo -p \
  'Use the task tool to ask one read-only subagent to reply exactly SUBAGENT_OK, then return exactly SUBAGENT_OK.'
```

Both commands must exit zero and return the requested marker. The first proves Makato
skill discovery through OMP. The second proves the subagent surface used by Makato's
PO-agent and implementation agents.

Also verify the model can issue a harmless tool call from the SAGIBEAST checkout:

```bash
omp --yolo -p \
  'Use a filesystem read tool to read the first heading in AGENTS.md and return only that heading.'
```

A prose-only guess is not a pass; the session log must show the tool call.

### Phase 7 - Validate and install the autonomous loop

#### 7.1 Read-only and dry-run gates

```bash
export PATH="/root/.local/bin:$PATH"
export MAKATO_HARNESS_BIN=/root/.local/bin/omp
export MAKATO_LOOP_DISPATCH_REPO=macatocz/sagibeast

cd /workspace/sagibeast
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh poll Ready
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run \
  --once --dry-run
```

The preflight must find `jq`, `gh`, Git, and Python; `gh auth status` must pass; board
polling must return JSON; and dry-run output must name OMP with `--yolo -p` without
launching an implementation.

For a specific issue, validate routing without dispatch:

```bash
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh \
  dispatch <ISSUE_NUMBER> --repo macatocz/sagibeast --dry-run
```

#### 7.2 Run the real makato-oss project 6 acceptance dispatch

The installation acceptance run uses the Makato checkout and its committed project 6
configuration. Do not start the long-running SAGIBEAST service concurrently:

```bash
export PATH="/root/.local/bin:$PATH"
export MAKATO_HARNESS_BIN=/root/.local/bin/omp
export MAKATO_LOOP_DISPATCH_REPO=macatocz/makato-oss
export MAKATO_LOOP_CONFIG=/root/makato-oss/.claude/config.json
export MAKATO_LOOP_STATE_DIR=/root/makato-oss/.claude/state
export MAKATO_HALT_FILE=/root/.claude/HALT
export SPECS_DIR=/root/makato-oss/specs

cd /root/makato-oss
test "$(jq -r '.github_project.number' .claude/config.json)" -eq 6
bash plugins/makato-orchestrate/scripts/loop.sh poll Ready | jq
bash plugins/makato-orchestrate/scripts/loop.sh run --once
```

At execution time, project 6 issue 64 was the Ready item. Its earlier run had left the
plan only on a previous instance, so the exact provenance-derived folder
`specs/64-makato-orchestrate-open-model-run-po/` had to be restored before retrying; do
not create a second seed folder for the same issue.

Verify that the selected card is claimed and an OMP po-agent is running:

```bash
gh project item-list 6 --owner macatocz --format json --limit 9999 \
  --jq '.items[] | select(.content.number == 64) | {status,title}'
systemctl status makato-issue64-retry.service --no-pager
```

The card must report `In progress`, and the process tree must include
`omp --yolo -p ... makato-orchestrate:po-agent`. This proves a real project item was
taken for work rather than only exercising dry-run routing.

#### 7.3 Install a systemd service

Keep non-secret runtime values in a root-owned environment file:

```bash
install -d -m 0755 /etc/makato
cat > /etc/makato/sagibeast-loop.env <<'EOF'
HOME=/root
PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VLLM_API_BASE=http://localhost:8100
MAKATO_HARNESS_BIN=/root/.local/bin/omp
MAKATO_LOOP_DISPATCH_REPO=macatocz/sagibeast
MAKATO_LOOP_CONFIG=/workspace/sagibeast/.claude/config.json
MAKATO_LOOP_STATE_DIR=/workspace/sagibeast/.claude/state
MAKATO_HALT_FILE=/root/.claude/HALT
SPECS_DIR=/workspace/sagibeast/specs
EOF
chmod 0600 /etc/makato/sagibeast-loop.env
```

Install the service:

```bash
cat > /etc/systemd/system/makato-sagibeast-loop.service <<'EOF'
[Unit]
Description=Makato autonomous SAGIBEAST development loop
Wants=network-online.target
After=network-online.target docker.service vllm.service
Requires=vllm.service

[Service]
Type=simple
User=root
WorkingDirectory=/workspace/sagibeast
EnvironmentFile=/etc/makato/sagibeast-loop.env
ExecStartPre=/usr/bin/test -d /workspace/sagibeast/.git
ExecStartPre=/root/makato-oss/scripts/preflight-omp-context.sh
ExecStart=/bin/bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run
Restart=on-failure
RestartSec=30
KillMode=control-group
TimeoutStopSec=90
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now makato-sagibeast-loop.service
systemctl status makato-sagibeast-loop.service --no-pager
journalctl -u makato-sagibeast-loop.service -n 100 --no-pager
```

`Restart=on-failure` is intentional. `loop.sh` exits zero when a HALT condition is
observed, so systemd must not immediately restart it and defeat the kill switch. If
vLLM is still warming, the endpoint preflight fails and systemd retries after 30
seconds.

#### 7.4 Operations

```bash
# Live loop state
cd /workspace/sagibeast
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh status
journalctl -u makato-sagibeast-loop.service -f

# Global stop
install -d -m 0700 /root/.claude
touch /root/.claude/HALT
systemctl stop makato-sagibeast-loop.service

# Resume after inspecting the active workflow and logs
rm /root/.claude/HALT
systemctl start makato-sagibeast-loop.service
```

The loop is single-threaded and claims the Projects v2 card before dispatch. Do not
run a second loop against the same repository/state directory.

## Acceptance mapping

| Acceptance criterion | Evidence |
| --- | --- |
| AC-1: CUDA-compatible local model is healthy | Driver major >= 580; `vllm.service` enabled; `/health` is 200 |
| AC-2: OMP model contract is correct | `models.yml` defines the local provider and token limits; `config.yml` maps every role to `local/open` with qwen3 tools |
| AC-3: Complete Makato capability set is installed | 14 plugins; audited 82 skills and 27 agents; `omp plugin doctor` passes |
| AC-4: SAGIBEAST is directly developable | Clean `/workspace/sagibeast/.git`; GitHub auth/scopes pass; Python and frontend baselines pass |
| AC-5: Headless agent tooling works | `MAKATO_SKILL_OK`, `SUBAGENT_OK`, and filesystem tool-call smokes pass |
| AC-6: Autonomous board loop is launchable | Project 6 issue 64 moves Ready → In progress under a real OMP po-agent; service is active |
| AC-7: Safety controls work | HALT exits loop without restart; one PID/state directory; shared Compose rule documented |
| AC-8: Stop/start persistence works | After a test reboot, Docker, vLLM, and loop service recover without reinstall |

Do not mark the installation complete until every row has concrete command output
captured in the operator log.

## Reboot verification

After all acceptance checks pass, perform one planned reboot:

```bash
reboot
```

Reconnect and verify:

```bash
nvidia-smi
systemctl is-active vllm
curl -sf http://localhost:8100/health
cd /root/makato-oss && scripts/preflight-omp-context.sh
systemctl is-active makato-sagibeast-loop.service
docker ps --filter label=com.docker.compose.project=sagibeast \
  --format 'table {{.Names}}\t{{.Status}}'
```

An overnight Vast.ai stop/start should need no reinstall. A migration or instance
re-create is different: it resets this disk, so repeat the complete plan.

## Known constraints and failure handling

- **Disk is adequate but not abundant.** The audited 67 GiB free is enough for the
  approximately 27 GiB model and development dependencies, but old worktrees, model
  revisions, Docker images, and caches must be reaped. Keep at least 20 GiB free after
  installation.
- **Driver installation is a two-pass operation.** Never build `/root/vllm-venv`
  before rebooting into driver 580 or newer.
- **The model is gated.** An approved Hugging Face token is required for the initial
  download. Do not pass it literally on a command line.
- **First model start is slow.** Loading weights and JIT-compiling kernels can take
  several minutes. `TimeoutStartSec=900` in `vllm.service` covers this.
- **Port 8000 is occupied.** vLLM intentionally uses 8100; SAGIBEAST owns 8000/8001/8080.
- **The initial Docker API mismatch is transient.** Use `DOCKER_API_VERSION=1.43` only
  before the maintenance reboot. The rebooted daemon reports API 1.52 and rejects that
  override, so remove it before installing long-running services.
- **Do not use `pkill -f "vllm serve"`.** It can match and kill the invoking shell. Use
  `systemctl stop vllm`.
- **Do not develop in deployment snapshots.** `/opt/sagibeast` and `/root/sagibeast`
  have no Git history. Autonomous work belongs in `/workspace/sagibeast` and its Git
  worktrees.
- **Do not run destructive Compose targets autonomously.** The fixed project name and
  ports make the live stack a shared resource; `stack-reset` would destroy it.
- **Do not expose vLLM publicly.** OMP and SAGIBEAST reach it on localhost. The API has
  no meaningful authentication.
- **Version bumps are tested changes.** OMP, vLLM, the model, tool parser, context
  length, CUDA driver floor, and Node major are a compatibility set, not independent
  casual upgrades.

## Files implementing this plan

| Repository file | Role |
| --- | --- |
| `infra/bootstrap-vllm.sh` | Idempotent driver, venv, model, systemd, and OMP-model bootstrap |
| `infra/vllm-serve.yaml` | Model, FP8, 65k context, memory, aliases, and qwen3 tool parser |
| `infra/vllm-serve.sh` | CUDA discovery and vLLM launch wrapper |
| `infra/vllm.service` | Boot-persistent local endpoint |
| `infra/omp-models.yml` | OMP local provider, context, and output limits |
| `infra/omp-config.yml` | OMP model-role routing and qwen3 tool format |
| `scripts/preflight-omp-context.sh` | Hard gate before PO-agent dispatch |
| `plugins/makato-orchestrate/scripts/loop.sh` | Board poller and OMP headless dispatcher |
| `plugins/makato-orchestrate/scripts/functions.sh` | Dispatch, watchdog, auth, mutex, and recovery logic |
