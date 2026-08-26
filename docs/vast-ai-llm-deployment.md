# Deploying the open LLM on vast.ai (automated)

The makato-oss "open" model is served by **vLLM** on the vast.ai dev GPU box. This document
is the runbook for standing it up and the record of *why* the setup is the way it is — the
first manual bring-up took hours of dead ends, and none of that should ever be repeated.

For how to *reach* the instance (SSH, ports, lifecycle) see [`vast-ai-access.md`](./vast-ai-access.md).

> **A migrated / re-provisioned instance is a FRESH box.** vast.ai persists the instance disk
> across **stop/start**, so the driver, venv and model survive an overnight stop. It does
> **not** persist across a **migration or re-create** (new host, new SSH port) — the disk is
> reset to the base image. After a migration you must run the full cold-start below again.
> This is the #1 reason "the box was working yesterday" stops being true.

## TL;DR

```bash
# On the instance, from the makato-oss repo root, on a fresh/migrated box:
#   The repo is PRIVATE — clone with credentials or rsync it from a laptop first (see Runbook).
curl -LsSf https://astral.sh/uv/install.sh | sh          # if uv is absent
export PATH="$HOME/.local/bin:$PATH"                     # uv installs here; not on root's PATH

# Pass 1 — installs the CUDA-13 driver + toolchain, then reboots and exits:
sudo -E MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh

# … box reboots. Reconnect once it is back, then Pass 2 — builds venv + model + systemd.
# The model is GATED: supply an approved Hugging Face token (see gotchas):
export PATH="$HOME/.local/bin:$PATH"
HF_TOKEN=hf_xxx sudo -E MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh

curl -sf http://localhost:8100/health                    # 200 when ready (a few min after start)
```

On a box that is **already on driver ≥ 580**, the two passes collapse into one — the driver
phase is skipped and the single invocation does venv + model + systemd with no reboot.

Every subsequent vast.ai **stop/start** needs nothing: `systemd` auto-starts vLLM on boot.
makato-oss connects via `VLLM_API_BASE=http://localhost:8100` (see `config/config.yml` →
`models.open.api_base`).

## What runs

| Piece          | Value                                                                                  |
| -------------- | -------------------------------------------------------------------------------------- |
| Model          | `bottlecapai/ThinkingCap-Qwen3.6-27B-FP8` (arch `Qwen3_5ForConditionalGeneration`) |
| Serving engine | vLLM **0.27.1**, Python **3.12**, CUDA **13** wheels (torch `…+cu13x`)     |
| GPU / driver   | RTX 4090, NVIDIA driver **≥ 580** (CUDA 13.0)                                    |
| Port           | **8100** (not 8000 — see below)                                                 |
| Served names   | `open`, `qwen3-reasoning`                                                          |
| Auto-start     | `systemd` unit `vllm.service` (`WantedBy=multi-user.target`)                     |

## The things that made this hard (and how the automation handles them)

1. **The model is a hybrid Mamba model, not a plain Qwen3.**
   Its architecture is `Qwen3_5ForConditionalGeneration` (`model_type: qwen3_5`), a
   GatedDeltaNet + attention hybrid. Only vLLM new enough to register `qwen3_5` can serve it
   (≈ 0.24+). Older vLLM fails at load with *"architectures … failed to be inspected"*.
2. **Every vLLM that knows `qwen3_5` is a CUDA 13 build.**
   Its compiled extension links `libcudart.so.13`. `uv --torch-backend=cu128` only changes
   *torch*, not vLLM's own binary, and there is no cu12 vLLM wheel for these versions
   (`wheels.vllm.ai/cu128` → 404). CUDA 13 needs **driver ≥ 580**; a fresh box ships driver
   535 (CUDA 12.2). → **Bootstrap Phase 1 installs `nvidia-driver-580`.**
3. **Order matters: install the driver and REBOOT *before* building the venv.**
   `uv --torch-backend=auto` picks torch's CUDA build from the *currently loaded* driver. If
   the venv is built while the box still runs the old 535 module (driver installed but not yet
   rebooted into), uv installs a **cu12 torch** that mismatches vLLM's cu13 binary — a broken
   venv that a later re-run will not repair. → **Phase 1 now reboots and exits immediately
   after installing the driver.** The venv is only ever built on Pass 2, against CUDA 13.
   This is why cold start is two passes on a fresh box.
4. **FlashInfer is not Python-3.10-safe.**
   `flashinfer/comm/fd_exchange.py` uses `array.array[int]` runtime annotations that raise
   `TypeError: 'type' object is not subscriptable` on 3.10. → **We run on Python 3.12**, where
   the import works natively (no source patch — the earlier `from __future__ import annotations`
   hack is obsolete and must not be reintroduced).
5. **The model JIT-compiles CUDA kernels at startup**, which needs a toolchain the base image
   lacks:

   - a C compiler + headers → `build-essential` (installed in the Phase 1 apt pass);
   - `ninja` → installed into the venv (Phase 3);
   - **`nvcc` + `CUDA_HOME`** → the only CUDA 13 toolkit present is the one bundled by the pip
     `nvidia-*-cu13` wheels under `…/site-packages/nvidia/cu13`. `vllm-serve.sh` discovers it
     via the bundled `nvcc` and exports `CUDA_HOME`/`PATH`.
   - **FlashInfer's sampler** JIT-compile fails against that pip toolkit
     (*"CUDA compiler and CUDA toolkit headers are incompatible"*). → `vllm-serve.sh` sets
     `VLLM_USE_FLASHINFER_SAMPLER=0` (native PyTorch sampler) and `--enforce-eager` (skips
     torch.compile capture, which triggers more fragile runtime compilation).
6. **The model repo is GATED.** `bottlecapai/ThinkingCap-Qwen3.6-27B-FP8` now requires
   approval — `hf download` returns *"Access denied. This repository requires approval."*
   without an approved token. → **Provide `HF_TOKEN` on Pass 2** (see gotchas).
7. **Port 8000 is taken.** The co-resident SAGIBEAST dev stack's `fastapi-brain` container
   publishes 8000/8001/8080. vLLM therefore serves on **8100**, and makato-oss points at it via
   `VLLM_API_BASE=http://localhost:8100`. To reclaim 8000, stop that container's 8000 publish
   and set `VLLM_PORT=8000` in the systemd drop-in.

## Files

| File                        | Role                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------- |
| `infra/vllm-serve.yaml`   | vLLM model/serving config (model, fp8, ctx 65k (≥ 65536 min for po-agent), gpu-util 0.75, served names) |
| `infra/vllm-serve.sh`     | launch wrapper — resolves `CUDA_HOME`, sets the workaround env, execs `vllm serve`                   |
| `infra/vllm.service`      | systemd unit — auto-starts the wrapper on every boot                                                    |
| `infra/bootstrap-vllm.sh` | idempotent setup: driver → reboot → venv → model → systemd                                          |

## Runbook

### Cold start (fresh, migrated, or re-provisioned instance)

```bash
# 1. Get the repo onto the box. It is PRIVATE, so either:
#    (a) rsync from a laptop that has it checked out —
#        rsync -az --exclude .git --exclude node_modules \
#          -e "ssh -p <PORT> -i ~/.ssh/vast_makato" \
#          ~/GITHUB/makato-oss/ root@<HOST>:/root/makato-oss/
#    (b) or `git clone` with a token / deploy key configured on the box.

# 2. Install uv if absent and put it on PATH (it installs to ~/.local/bin, not root's PATH):
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# 3. Pass 1 — driver + toolchain, then auto-reboot (skipped if already on driver >= 580):
cd /root/makato-oss
sudo -E MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh
#    Run long/heavy passes under tmux so an SSH drop can't kill them:
#      tmux new -s mkboot 'cd /root/makato-oss && export PATH=$HOME/.local/bin:$PATH && \
#        HF_TOKEN=hf_xxx sudo -E MAKATO_HOME=$PWD bash infra/bootstrap-vllm.sh 2>&1 | tee /var/log/makato-bootstrap.log'

# 4. Reconnect after the reboot, then Pass 2 — venv + model + systemd (needs the gated token):
export PATH="$HOME/.local/bin:$PATH"
cd /root/makato-oss
HF_TOKEN=hf_xxx sudo -E MAKATO_HOME="$PWD" bash infra/bootstrap-vllm.sh

# 5. Verify (weights ~27 GB load + kernel JIT take a few minutes on first start):
curl -sf http://localhost:8100/health && curl -s http://localhost:8100/v1/models
```

> `sudo -E` preserves `HF_TOKEN` and `PATH` into the root environment — without `-E`, `sudo`
> strips them and the model download fails on the gate again.

### Daily start (box was stopped overnight, disk intact)

```bash
vastai start instance <ID>     # from your laptop; disk (driver+venv+model) is intact
# nothing else — vllm.service starts on boot. Verify:
curl -sf http://localhost:8100/health && curl -s http://localhost:8100/v1/models
```

### Manage / debug

```bash
systemctl status vllm            # state
journalctl -u vllm -f            # live log (also /var/log/vllm-serve.log)
systemctl restart vllm           # bounce
sudo -E MAKATO_HOME=/root/makato-oss bash infra/bootstrap-vllm.sh   # re-run after repo changes; idempotent
```

### Smoke test the endpoint

```bash
curl -s http://localhost:8100/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"open","messages":[{"role":"user","content":"Řekni ahoj česky."}],"max_tokens":64}'
```

Run `scripts/preflight-omp-context.sh` as a pre-dispatch sanity check to confirm the model's
context window meets the 65536 minimum before starting the po-agent.

## Gotchas

- **Migration ≠ stop/start.** See the note at the top: a migrated/re-created instance loses
  the whole disk (driver, venv, 27 GB model, systemd unit) and needs a full cold start. Only a
  plain stop/start keeps them.
- **Gated model → `HF_TOKEN` required.** Request access at
  `https://huggingface.co/bottlecapai/ThinkingCap-Qwen3.6-27B-FP8`, then pass an approved token
  on Pass 2: `HF_TOKEN=hf_xxx sudo -E … bash infra/bootstrap-vllm.sh`. `hf` also reads
  `~/.cache/huggingface/token` if you `hf auth login` first. `sudo` without `-E` drops the token.
- **A re-provisioned box may have a broken `/etc/environment` that breaks apt.** vast.ai injects
  container env into `/etc/environment` as bare `KEY=VALUE` lines, but writes the SSH public key
  **unquoted and with spaces** (`PUBLIC_KEY=ssh-ed25519 AAAA… label`) and often **duplicates the
  whole block**. Because `/etc/environment` is `.`-sourced by some dpkg post-install scripts
  (`update-info-dir`), the space-split value is executed as a command → *"AAAA…: not found"* →
  exit 127 → **`apt-get` aborts mid-configure**. It is re-injected on **every boot**. Fix before
  any apt use (quotes values with spaces, de-dupes keys):

  ```bash
  cp -a /etc/environment /etc/environment.bak.$(date +%s)
  python3 - <<'PY'
  seen=set(); out=[]
  for ln in open('/etc/environment').read().splitlines():
      if '=' not in ln: continue
      k,v=ln.split('=',1)
      if k in seen: continue
      seen.add(k)
      if len(v)>=2 and v[0]=='"' and v[-1]=='"': v=v[1:-1]
      out.append('%s="%s"'%(k,v) if ' ' in v else '%s=%s'%(k,v))
  open('/etc/environment','w').write('\n'.join(out)+'\n')
  PY
  sh -c '. /etc/environment && echo ENV-OK'
  ```

  The bootstrap does all its apt work (driver + `build-essential`) in one Phase-1 pass and then
  reboots, so as long as you fix `/etc/environment` **before** Pass 1, Pass 2 needs no apt and is
  unaffected by the re-injection. The running `vllm.service` is also unaffected — bash and
  systemd do not source `/etc/environment` (only PAM login + some apt hooks do).
- **`uv` is not on root's PATH.** The installer drops it at `~/.local/bin/uv`; export
  `PATH="$HOME/.local/bin:$PATH"` before the bootstrap or it dies with *"uv not found"*.
- **po-agent requires max_model_len ≥ 65536** — `max_model_len: 32768` overflows on the first
  request (prompt hits ~16 385 tokens from issue #42); `max_model_len: 40960` overflows after
  the first tool-call round (~24 577 tokens). `max_model_len: 65536` is the confirmed minimum.
  Root cause: omp requests `max_model_len / 2` output tokens, and makato skill files push the
  accumulated context past the window midpoint quickly in multi-turn exchanges. Additionally,
  `tool_call_parser: qwen3_xml` is required — `hermes` fetches `chat_template.json` from a
  gated Hugging Face repo at startup and fails offline. Set `TRANSFORMERS_OFFLINE=1` in
  `vllm.service` to prevent that HF fetch when the chat template is loaded.
- **Do not `pkill -f "vllm serve"`** — the pattern matches the shell running the command and
  kills your own SSH session. Use `systemctl stop vllm` or `tmux kill-session`.
- **The model is multimodal** (vision encoder present). We serve it as text; that is fine and
  needs no `--trust-remote-code`.
- **First start after a reboot is slow** (weights ~28 GiB + kernel JIT): allow a few minutes.
  `TimeoutStartSec=900` in the unit covers this.
- **Bumping `VLLM_VERSION`** in `bootstrap-vllm.sh` is a tested change, not a casual one — newer
  vLLM has repeatedly moved the CUDA/Python floor and broken this box.
