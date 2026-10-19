# Install OMP and an open-model vLLM workstation on Vast.ai

Use this guide when you receive a new Vast.ai GPU instance and need to turn it
into a persistent Makato development workstation. The result is:

- A gated open model served locally through vLLM.
- [oh-my-pi (OMP)](https://github.com/can1357/oh-my-pi) configured to use that
  model for every agent role.
- The complete Makato plugin suite installed in OMP.
- A Git-backed target repository ready for interactive or autonomous work.
- An optional systemd-managed Makato board loop that survives instance restarts.

This is an installation guide, not an inventory of a specific machine. Replace
all angle-bracket placeholders before running commands. For general Vast.ai
access and port guidance, see [`vast-ai-access.md`](./vast-ai-access.md).

## Provider profile contract

This box's endpoint and OMP configuration are the checked-in `qwen-vllm` profile
declared in [`config/model-profiles.yml`](../config/model-profiles.yml) (`base_url:
http://localhost:8100/v1`, no credential, `tool_format: qwen3`) — the same profile
`scripts/select-model-profile.sh` and `scripts/resolve-model-profile.py` validate
elsewhere in the suite. `infra/omp-models.yml` / `infra/omp-config.yml` (installed by
`infra/bootstrap-vllm.sh` below) mirror that profile's provider/role documents verbatim
(test-enforced), so there is nothing extra to run here to "activate" the profile; a
bootstrap re-run merges the profile into existing OMP files rather than overwriting them.
`infra/omp-config.yml` also carries `task.agentModelOverrides`, routing every makato
subagent to its shared `"@<role>"` alias and mirroring
[`config/agent-roles.yml`](../config/agent-roles.yml) (test-enforced).

To point a client (including a Mac) at this box instead of running everything on it, see
[`docs/macos-openai-qwen.md`](./macos-openai-qwen.md) § *Remote Linux/Qwen (client-side
from a Mac)* — set `VLLM_API_BASE`/`MAKATO_OPEN_ENDPOINT_URL` to this instance's tunneled
or public address and run the same `qwen-vllm` profile preflight from the client:

```bash
MAKATO_MODEL_PROFILE=qwen-vllm VLLM_API_BASE=http://localhost:8100 \
  bash scripts/preflight-omp-context.sh
```

If you instead want this box to serve as an autonomous *orchestrator* against `api.openai.com`
or a local profile, install a different profile with `scripts/select-model-profile.sh
<profile>`; it merges that profile's roles, tool format, provider and agent-role overrides
into the existing OMP config and preserves everything else — see the root
[`README.md`](../README.md#provider-switching) for the full profile-switch command set.
Nothing below this section assumes a profile other than `qwen-vllm`.

## Supported configuration

The following versions form one tested compatibility set. Upgrade them together
and repeat all validation steps when changing any member.

| Component | Setting |
| --- | --- |
| Operating system | Ubuntu 22.04 |
| GPU | NVIDIA GPU with at least 48 GiB VRAM |
| NVIDIA driver | Major version 580 or newer |
| Model | `bottlecapai/ThinkingCap-Qwen3.6-27B-FP8` |
| vLLM | `0.27.1`, Python 3.12, CUDA 13 PyTorch build |
| vLLM endpoint | `http://localhost:8100/v1` |
| Context window | 65,536 tokens |
| OMP | `18.0.6` |
| Node.js | 24 |
| vLLM tool parser | `qwen3_xml` |
| OMP tool format | `qwen3` |
| OMP completion budget | 8,192 tokens |

Port 8100 is intentionally host-local. Do not publish it through Vast.ai: the
endpoint has no meaningful authentication.

## Required inputs

Collect these values before starting:

- Vast.ai host, SSH port, and private-key path.
- A GitHub account with repository, issue, pull-request, workflow, organization,
  and Projects v2 access.
- Access to the gated Hugging Face model and an approved read token.
- The target development repository, for example `macatocz/sagibeast`.
- The GitHub Projects v2 configuration committed in the target repository's
  `.claude/config.json`.
- At least 45 GiB of free disk space. Keep at least 20 GiB free after setup for
  worktrees, package caches, and model revisions.

Set local connection variables:

```bash
export VAST_HOST="<HOST>"
export VAST_SSH_PORT="<PORT>"
export VAST_SSH_KEY="<PATH_TO_PRIVATE_KEY>"

ssh -p "$VAST_SSH_PORT" -i "$VAST_SSH_KEY" "root@$VAST_HOST"
```

The remaining commands run on the remote instance unless stated otherwise.

## 1. Inspect the new instance

Confirm the operating system, GPU, disk, memory, and occupied ports before
installing anything:

```bash
cat /etc/os-release
uname -r
nvidia-smi
df -h /
free -h
ss -lntp
docker version || true
docker ps || true
```

Stop if the GPU is absent or the disk does not have the required headroom.
Choose a maintenance window if an existing workload is already running: the
driver installation performs one reboot.

Vast.ai images can contain repeated entries in `/etc/environment`. If sourcing
the file fails, normalize it before using `apt`:

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

## 2. Install host tools

Install baseline packages and GitHub CLI from GitHub's maintained repository:

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

Install Node.js 24, uv, and the pinned OMP release:

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="/root/.local/bin:$PATH"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' /root/.profile ||
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.profile

curl -fsSL https://omp.sh/install |
  sh -s -- --binary --ref v18.0.6

node --version
npm --version
uv --version
omp --version
gh --version
jq --version
```

## 3. Authenticate GitHub and clone the repositories

Authenticate interactively. Do not put a personal access token in shell
history, an environment file, or a repository:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth refresh --hostname github.com \
  --scopes repo,project,workflow,read:org
gh auth setup-git
gh auth status --hostname github.com
```

Clone Makato and the target repository into real Git working directories:

```bash
export TARGET_REPO="<OWNER>/<REPOSITORY>"
export TARGET_ROOT="/workspace/<REPOSITORY>"

install -d -m 0755 /workspace
gh repo clone macatocz/makato-oss /root/makato-oss
gh repo clone "$TARGET_REPO" "$TARGET_ROOT"

git -C /root/makato-oss status --short --branch
git -C "$TARGET_ROOT" status --short --branch
test -f "$TARGET_ROOT/.claude/config.json"
```

Configure a GitHub-compatible commit identity:

```bash
GH_LOGIN="$(gh api user --jq .login)"
GH_ID="$(gh api user --jq .id)"
git config --global user.name "$GH_LOGIN"
git config --global user.email \
  "${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
unset GH_LOGIN GH_ID
```

Verify that `.claude/config.json` references the intended Projects v2 board and
target repository:

```bash
jq '{
  owner: .github_project.owner,
  number: .github_project.number,
  status_field: .github_project.status_field_name,
  known_repos: .github_project.known_repos
}' "$TARGET_ROOT/.claude/config.json"
```

## 4. Install Makato plugins in OMP

Register the local Makato checkout as an OMP marketplace and install every
catalog entry at user scope:

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

Compare the installed plugin names with the current marketplace rather than
hard-coding an inventory count:

```bash
jq -r '.plugins[].name' \
  /root/makato-oss/.claude-plugin/marketplace.json | sort \
  > /tmp/makato-marketplace-plugins
omp plugin list | sed -nE 's/^  ([^@]+)@makato-suite.*/\1/p' | sort \
  > /tmp/makato-installed-plugins
diff -u /tmp/makato-marketplace-plugins /tmp/makato-installed-plugins
rm -f /tmp/makato-marketplace-plugins /tmp/makato-installed-plugins
```

After updating the Makato checkout, refresh the OMP cache before starting new
sessions:

```bash
git -C /root/makato-oss pull --ff-only
omp plugin marketplace update makato-suite
omp plugin upgrade --scope user
omp plugin doctor
```

## 5. Store Hugging Face credentials

Request access to the gated model first. Store the token without exposing it in
process arguments or shell history:

```bash
install -d -m 0700 /root/.cache/huggingface
read -rsp 'Hugging Face token: ' HF_TOKEN
printf '\n'
umask 077
printf '%s' "$HF_TOKEN" > /root/.cache/huggingface/token
unset HF_TOKEN
chmod 0600 /root/.cache/huggingface/token
```

## 6. Bootstrap the NVIDIA driver and vLLM

The bootstrap is idempotent and intentionally uses two passes when the driver
must be upgraded.

### Pass 1: driver installation

```bash
export PATH="/root/.local/bin:$PATH"
cd /root/makato-oss
MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh
```

If the loaded driver is older than major version 580, the script installs the
driver and build toolchain, reboots, and exits before creating the Python
environment. This ordering prevents uv from selecting a PyTorch CUDA build for
the old driver.

### Pass 2: model and services

Reconnect after the instance returns:

```bash
export PATH="/root/.local/bin:$PATH"
sh -c '. /etc/environment && echo ENV-OK'
nvidia-smi --query-gpu=name,driver_version,memory.total \
  --format=csv,noheader

tmux new-session -d -s vllm-bootstrap \
  'cd /root/makato-oss &&
   export PATH=/root/.local/bin:$PATH &&
   export HF_HUB_DISABLE_XET=1 &&
   MAKATO_HOME=/root/makato-oss bash infra/bootstrap-vllm.sh \
     2>&1 | tee /var/log/makato-bootstrap.log'
tmux attach -t vllm-bootstrap
```

`HF_HUB_DISABLE_XET=1` uses Hugging Face's resumable HTTP transfer when Xet is
unreliable. The bootstrap always asks Hugging Face to resolve the complete
snapshot, so one cached shard cannot be mistaken for a complete model.

The second pass:

1. Creates `/root/vllm-venv` with Python 3.12 and vLLM 0.27.1.
2. Downloads the complete gated model snapshot.
3. Installs and enables `vllm.service`.
4. If the `omp` binary is present, installs `infra/omp-models.yml` as
   `/root/.omp/agent/models.yml` and `infra/omp-config.yml` as
   `/root/.omp/agent/config.yml` (overridable via `OMP_MODELS_DEST` / `OMP_CONFIG_DEST`),
   verbatim with comments, for each file that is absent or empty.
5. If either file already existed, runs `scripts/select-model-profile.sh qwen-vllm`
   against them with the vLLM venv's Python (which has PyYAML). This restores only the
   keys the `qwen-vllm` profile owns — `providers.local.{baseUrl,apiKey,models}` in
   `models.yml`; the canonical `modelRoles` keys, `tools.format` and the makato agent
   keys of `task.agentModelOverrides` in `config.yml` — and keeps every other setting
   (other providers and their API keys, custom roles, legacy opus/sonnet/haiku aliases,
   other agents' overrides, unrelated settings). YAML comments in a merged file are not
   kept. A merge the resolver refuses (for example, unparseable YAML) leaves both files
   untouched and only logs a warning, so vLLM still starts.

A re-run therefore restores the `qwen-vllm` routing; to route elsewhere afterwards, run
`scripts/select-model-profile.sh <profile>`.
`tests/test_model_profiles.py::test_qwen_vllm_merge_leaves_infra_omp_files_unchanged`
enforces that merging `qwen-vllm` into the checked-in infra files changes nothing, so
fresh and re-run boxes route identically.

OMP v18 reads only provider definitions from `models.yml`. It reads
`modelRoles` and `tools.format` from `config.yml`; putting those settings in
`models.yml` silently leaves role routing and tool formatting inactive.

## 7. Verify vLLM and OMP

Wait for model loading and CUDA kernel compilation:

```bash
systemctl is-enabled vllm
systemctl status vllm --no-pager
journalctl -u vllm -n 100 --no-pager

curl -sf http://localhost:8100/health
curl -s http://localhost:8100/v1/models | jq

cd /root/makato-oss
MAKATO_MODEL_PROFILE=qwen-vllm bash scripts/preflight-omp-context.sh
```

`MAKATO_MODEL_PROFILE` defaults to `qwen-vllm` when unset, so omitting it is equivalent —
setting it explicitly documents which profile (`config/model-profiles.yml`) the check is
validating against. The same profile-aware check is also what Gate 6
(`scripts/preflight-model-runtime.sh`, run by `build-verify` before any autonomous PR/merge)
calls before dispatching the PO-agent:

```bash
MAKATO_MODEL_PROFILE=qwen-vllm bash scripts/preflight-model-runtime.sh
```

The preflight must confirm:

- vLLM reports a 65,536-token context.
- OMP uses `contextWindow: 65536` and `maxTokens: 8192`.
- Every OMP role maps to `local/open`.
- `tools.format` is `qwen3`.

The parser pair is vLLM `qwen3_xml` and OMP `qwen3`. Do not switch vLLM to the
Hermes parser: that path can require a gated chat template not present in an
offline deployment.

Start a new OMP process after installing or upgrading plugins:

```bash
cd "$TARGET_ROOT"

omp --yolo -p \
  'Read skill://makato-guide and reply with exactly MAKATO_SKILL_OK.'

omp --yolo -p \
  'Use the task tool to ask one read-only subagent to reply exactly SUBAGENT_OK, then return exactly SUBAGENT_OK.'

omp --yolo -p \
  'Use a filesystem read tool to read the first heading in AGENTS.md and return only that heading.'
```

The first two commands must return their exact markers. The third must show an
actual filesystem tool call rather than a prose-only guess.

## 8. Prepare the target development repository

Install the target repository's declared development dependencies. For
SAGIBEAST:

```bash
export PATH="/root/.local/bin:$PATH"
uv python install 3.14
uv tool install pre-commit

cd /workspace/sagibeast
make dev-setup
npm --prefix frontend ci
npm --prefix frontend run e2e:install

uv run pytest tests/unit -q --no-header
npm --prefix frontend run typecheck
npm --prefix frontend test
```

If an existing deployment uses fixed Compose project names or published ports,
do not run destructive Compose lifecycle targets from the development checkout.
Use host-side unit, property, lint, typecheck, and frontend tests until the
Compose project name and ports are parameterized per worktree.

## 9. Validate the autonomous loop

Run read-only and dry-run checks first:

```bash
export PATH="/root/.local/bin:$PATH"
export MAKATO_HARNESS_BIN=/root/.local/bin/omp
export MAKATO_LOOP_DISPATCH_REPO="$TARGET_REPO"

cd "$TARGET_ROOT"
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh poll Ready
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run \
  --once --dry-run
```

For a specific disposable Ready issue, validate routing without starting work:

```bash
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh \
  dispatch <ISSUE_NUMBER> --repo "$TARGET_REPO" --dry-run
```

Before enabling a persistent loop, perform one controlled real acceptance run
against an issue that is safe to claim:

```bash
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh run --once
```

Verify that:

- The selected card moves from Ready to In progress.
- The issue receives a live autonomous-progress comment.
- Its workflow state contains a non-null integer `progress_comment_id`.
- The process tree contains `omp --yolo -p`.
- Only one loop process owns the repository state directory.

## 10. Install the autonomous loop service

Replace every placeholder in the following files with values for the target
repository.

Create a root-owned environment file:

```bash
install -d -m 0755 /etc/makato
cat > /etc/makato/target-loop.env <<'EOF'
HOME=/root
PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VLLM_API_BASE=http://localhost:8100
MAKATO_HARNESS_BIN=/root/.local/bin/omp
MAKATO_MODEL_PROFILE=qwen-vllm
MAKATO_LOOP_DISPATCH_REPO=<OWNER>/<REPOSITORY>
MAKATO_LOOP_CONFIG=/workspace/<REPOSITORY>/.claude/config.json
MAKATO_LOOP_STATE_DIR=/workspace/<REPOSITORY>/.claude/state
MAKATO_HALT_FILE=/root/.claude/HALT
MAKATO_SKIP_OPTIONAL_PREFLIGHT=1
SPECS_DIR=/workspace/<REPOSITORY>/specs
EOF
chmod 0600 /etc/makato/target-loop.env
```

Install the systemd unit:

```bash
cat > /etc/systemd/system/makato-target-loop.service <<'EOF'
[Unit]
Description=Makato autonomous development loop
Wants=network-online.target
After=network-online.target vllm.service
Requires=vllm.service

[Service]
Type=simple
User=root
WorkingDirectory=/workspace/<REPOSITORY>
EnvironmentFile=/etc/makato/target-loop.env
ExecStartPre=/usr/bin/test -d /workspace/<REPOSITORY>/.git
ExecStartPre=/root/makato-oss/scripts/preflight-model-runtime.sh
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
systemctl enable --now makato-target-loop.service
systemctl status makato-target-loop.service --no-pager
journalctl -u makato-target-loop.service -n 100 --no-pager
```

`Restart=on-failure` is required. `loop.sh` exits successfully after observing a
HALT, so systemd does not immediately restart it and defeat the kill switch.
While vLLM is warming after boot, the preflight can fail and systemd retries
after 30 seconds.

## 11. Operations and safety

Inspect the loop:

```bash
cd "$TARGET_ROOT"
bash /root/makato-oss/plugins/makato-orchestrate/scripts/loop.sh status
journalctl -u makato-target-loop.service -f
```

Stop all new autonomous dispatch:

```bash
install -d -m 0700 /root/.claude
touch /root/.claude/HALT
systemctl stop makato-target-loop.service
```

Resume only after inspecting the active workflow and logs:

```bash
rm /root/.claude/HALT
systemctl start makato-target-loop.service
```

Never run a second loop against the same repository and state directory.

## 12. Reboot verification

Perform one planned reboot after all checks pass:

```bash
reboot
```

Reconnect and verify persistence:

```bash
nvidia-smi
systemctl is-active vllm
curl -sf http://localhost:8100/health
cd /root/makato-oss && MAKATO_MODEL_PROFILE=qwen-vllm bash scripts/preflight-omp-context.sh
systemctl is-active makato-target-loop.service
```

A normal Vast.ai stop/start should not require reinstallation. A migration or
instance recreation creates a new disk and requires the complete procedure.

## Troubleshooting

### Model download stalls

Set `HF_HUB_DISABLE_XET=1` and rerun the bootstrap. Hugging Face resumes verified
files and downloads missing shards over HTTP.

### vLLM reports missing model shards

Rerun `infra/bootstrap-vllm.sh`. Do not use the presence of one
`.safetensors` file as proof that a sharded snapshot is complete.

### OMP requests more than the 65,536-token context

Check both files:

```bash
grep -E 'contextWindow|maxTokens' /root/.omp/agent/models.yml
grep -E 'default: local/open|format: qwen3' \
  /root/.omp/agent/config.yml
```

OMP v18 requires `contextWindow` and `maxTokens`; the older `context` and
`maxOutput` keys are ignored.

### OMP ignores model roles or tool format

Confirm `modelRoles` and `tools.format` are in
`/root/.omp/agent/config.yml`, not `models.yml`. Rerun the bootstrap to install
the version-controlled files.

### Switching this box to a different provider profile

`scripts/preflight-omp-context.sh` / `scripts/preflight-model-runtime.sh` validate
whichever profile `MAKATO_MODEL_PROFILE` names (default `qwen-vllm`) against
`config/model-profiles.yml` — they do not themselves install a profile. If you
repoint this box at `openai` or `apple-ollama` with `scripts/select-model-profile.sh
<profile>` (which merges that profile into the existing `/root/.omp/agent` config),
update `MAKATO_MODEL_PROFILE` in `/etc/makato/target-loop.env` to match, or the loop's
Gate 6 preflight will report a role/tool-format mismatch against the installed
profile's OMP config. See the root
[`README.md`](../README.md#provider-switching) for the full profile-switch commands
and [`docs/macos-openai-qwen.md`](./macos-openai-qwen.md) for the Mac-client
counterpart of this box.

### vLLM does not start after a driver change

Confirm the loaded driver is major version 580 or newer. Delete and rebuild
`/root/vllm-venv` only if it was created before rebooting into the new driver.

### Docker commands report an API mismatch

Some images temporarily run an older daemon than the installed client. Use a
shell-local `DOCKER_API_VERSION` override only long enough to inspect or stop
the workload. Remove the override after reboot and never persist it without
checking the daemon's minimum API.

## Repository files

| File | Purpose |
| --- | --- |
| `infra/bootstrap-vllm.sh` | Driver, vLLM, complete model snapshot, OMP config, and systemd bootstrap |
| `infra/vllm-serve.yaml` | Model, context, GPU memory, aliases, and tool parser |
| `infra/vllm-serve.sh` | CUDA discovery and vLLM launch wrapper |
| `infra/vllm.service` | Boot-persistent vLLM endpoint |
| `infra/omp-models.yml` | OMP local provider and model limits |
| `infra/omp-config.yml` | OMP role routing, agent-role overrides, and qwen3 tool format |
| `config/model-profiles.yml` | Canonical `openai` \| `qwen-vllm` \| `apple-ollama` profile declarations this box's OMP config mirrors |
| `scripts/resolve-model-profile.py` | Structural profile validation (never emits a credential value) |
| `scripts/select-model-profile.sh` | Merges (or `--dry-run` previews) a profile and the agent-role overrides into `~/.omp/agent/{models,config}.yml` |
| `scripts/preflight-omp-context.sh` | Profile-aware endpoint/auth/tool-format runtime gate |
| `scripts/preflight-model-runtime.sh` | Gate 6 — wraps `preflight-omp-context.sh` + the advisory optional-service checks |
| `scripts/preflight-optional-services.sh` | Advisory Playwright MCP / Langfuse / Postgres / Temporal / Sagibeast checks (PASS/SKIP/WARN, never blocks) |
| `docs/macos-openai-qwen.md` | Mac-client counterpart: Apple-local profile, native OpenAI, and pointing a Mac at this remote endpoint |
