# Deploying the open LLM on vast.ai (automated)

The makato-oss "open" model is served by **vLLM** on the vast.ai dev GPU box. This document
is the runbook for standing it up and the record of *why* the setup is the way it is — the
first manual bring-up took hours of dead ends, and none of that should ever be repeated.

For how to *reach* the instance (SSH, ports, lifecycle) see [`vast-ai-access.md`](./vast-ai-access.md).

## TL;DR

```bash
# On the instance, from the makato-oss repo root, once per fresh/re-provisioned box:
sudo bash infra/bootstrap-vllm.sh          # installs driver, venv, model, systemd unit
# Fresh box: it installs the NVIDIA driver and reboots once; re-run is a no-op after that.

# Every subsequent vast.ai stop/start: nothing to do — systemd auto-starts vLLM on boot.
curl -sf http://localhost:8100/health      # 200 when ready (a few minutes after boot)
```

makato-oss connects via `VLLM_API_BASE=http://localhost:8100` (see `config/config.yml` →
`models.open.api_base`).

## What runs

| Piece | Value |
| --- | --- |
| Model | `bottlecapai/ThinkingCap-Qwen3.6-27B-FP8` (arch `Qwen3_5ForConditionalGeneration`) |
| Serving engine | vLLM **0.27.1**, Python **3.12**, CUDA **13** wheels |
| GPU / driver | RTX 4090 48 GB, NVIDIA driver **≥ 580** (CUDA 13.0) |
| Port | **8100** (not 8000 — see below) |
| Served names | `open`, `qwen3-reasoning` |
| Auto-start | `systemd` unit `vllm.service` (`WantedBy=multi-user.target`) |

## The five things that made this hard (and how the automation handles them)

1. **The model is a hybrid Mamba model, not a plain Qwen3.**
   Its architecture is `Qwen3_5ForConditionalGeneration` (`model_type: qwen3_5`), a
   GatedDeltaNet + attention hybrid. Only vLLM new enough to register `qwen3_5` can serve it
   (≈ 0.24+). Older vLLM fails at load with *"architectures … failed to be inspected"*.

2. **Every vLLM that knows `qwen3_5` is a CUDA 13 build.**
   Its compiled extension links `libcudart.so.13`. `uv --torch-backend=cu128` only changes
   *torch*, not vLLM's own binary, and there is no cu12 vLLM wheel for these versions
   (`wheels.vllm.ai/cu128` → 404). CUDA 13 needs **driver ≥ 580**; the stock box shipped
   driver 535 (CUDA 12.2). → **Bootstrap Phase 1 installs `nvidia-driver-580` and reboots.**
   The driver persists on the instance disk across stop/start, so this is one-time.

3. **FlashInfer is not Python-3.10-safe.**
   `flashinfer/comm/fd_exchange.py` uses `array.array[int]` runtime annotations that raise
   `TypeError: 'type' object is not subscriptable` on 3.10. → **We run on Python 3.12**, where
   the import works natively (no source patch — the earlier `from __future__ import annotations`
   hack is obsolete and must not be reintroduced).

4. **The model JIT-compiles CUDA kernels at startup**, which needs a toolchain that the base
   image lacks:
   - a C compiler + headers → `build-essential` (Phase 2);
   - `ninja` → installed into the venv (Phase 3);
   - **`nvcc` + `CUDA_HOME`** → the only CUDA 13 toolkit present is the one bundled by the pip
     `nvidia-*-cu13` wheels under `…/site-packages/nvidia/cu13`. `vllm-serve.sh` discovers it
     via the bundled `nvcc` and exports `CUDA_HOME`/`PATH`.
   - **FlashInfer's sampler** JIT-compile fails against that pip toolkit
     (*"CUDA compiler and CUDA toolkit headers are incompatible"*). → `vllm-serve.sh` sets
     `VLLM_USE_FLASHINFER_SAMPLER=0` (native PyTorch sampler) and `--enforce-eager` (skips
     torch.compile capture, which triggers more fragile runtime compilation).

5. **Port 8000 is taken.** The co-resident SAGIBEAST dev stack's `fastapi-brain` container
   publishes 8000/8001/8080. vLLM therefore serves on **8100**, and makato-oss points at it via
   `VLLM_API_BASE=http://localhost:8100`. To reclaim 8000, stop that container's 8000 publish
   and set `VLLM_PORT=8000` in the systemd drop-in.

## Files

| File | Role |
| --- | --- |
| `infra/vllm-serve.yaml` | vLLM model/serving config (model, fp8, ctx 65k (≥ 65536 min for po-agent), gpu-util 0.75, served names) |
| `infra/vllm-serve.sh` | launch wrapper — resolves `CUDA_HOME`, sets the workaround env, execs `vllm serve` |
| `infra/vllm.service` | systemd unit — auto-starts the wrapper on every boot |
| `infra/bootstrap-vllm.sh` | idempotent one-time setup: driver → venv → model → systemd |

## Runbook

### Cold start (fresh or re-provisioned instance)

```bash
# 1. Get the repo onto the box (rsync from a laptop, or git clone).
# 2. Install uv if absent:
curl -LsSf https://astral.sh/uv/install.sh | sh
# 3. Bootstrap (installs driver + reboots once on a stock box):
sudo bash infra/bootstrap-vllm.sh
# 4. After the auto-reboot, the unit is already enabled — just wait and check:
curl -sf http://localhost:8100/health
```

### Daily start (box was stopped overnight)

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
sudo bash infra/bootstrap-vllm.sh   # re-run after repo changes; idempotent
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
