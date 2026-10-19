#!/usr/bin/env bash
# One-time (idempotent) bootstrap for the makato-oss open LLM endpoint on a fresh or
# re-provisioned vast.ai GPU VM. Turns a bare vastai/kvm Ubuntu box into a machine that
# auto-serves ThinkingCap-Qwen3.6-27B-FP8 via vLLM on every boot.
#
# It is safe to re-run: every phase checks its own end-state and skips work already done.
#
# Usage (from the repo root on the instance):
#     sudo MAKATO_HOME=/root/makato-oss bash infra/bootstrap-vllm.sh
#
# Phases:
#   1. NVIDIA driver >= 580 (CUDA 13) — required by any vLLM new enough to know the
#      `qwen3_5` architecture. Installs + reboots once if the box is on an older driver.
#   2. Build toolchain (gcc) — the model JIT-compiles CUDA kernels at startup.
#   3. Python 3.12 venv + pinned vLLM (cu13 wheels via uv --torch-backend=auto).
#   4. Model weights (~27 GB FP8) into the HF cache — skipped if already present.
#   5. systemd unit install + enable, so the endpoint auto-starts on every boot.
#   6. omp provider + settings config — installs infra/omp-{models,config}.yml
#      to ~/.omp/agent/ on a fresh box, or merges the qwen-vllm profile into the
#      existing files, when the oh-my-pi harness is present (skipped otherwise).
#
# The full "why" behind the version pins and workarounds is in
# docs/vast-ai-llm-deployment.md.
set -euo pipefail

# ── Platform guard ────────────────────────────────────────────────────────────
# This script provisions a Linux/NVIDIA CUDA toolchain and is remote-Linux-only.
# macOS/Apple Silicon clients use scripts/macos-setup.sh instead, which never
# attempts CUDA/vLLM installation locally.
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "[bootstrap ERROR] infra/bootstrap-vllm.sh provisions a Linux/NVIDIA CUDA toolchain and only runs on Linux — detected '$OS_NAME'." >&2
    echo "[bootstrap ERROR] On macOS/Apple Silicon, use scripts/macos-setup.sh (no CUDA/vLLM is installed locally there)." >&2
    exit 1
fi
# When lspci is available, fail fast on a Linux box with no NVIDIA GPU at all
# instead of wasting time apt-installing a driver that has nothing to bind to.
# Skipped (not a hard requirement) when lspci itself is not installed.
if command -v lspci >/dev/null 2>&1 && ! lspci 2>/dev/null | grep -qi nvidia; then
    echo "[bootstrap ERROR] no NVIDIA GPU detected via lspci — this script requires a Linux/NVIDIA GPU instance." >&2
    exit 1
fi

MAKATO_HOME="${MAKATO_HOME:-/root/makato-oss}"
VLLM_VENV="${VLLM_VENV:-/root/vllm-venv}"
VLLM_PORT="${VLLM_PORT:-8100}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
# Pinned for reproducibility: 0.27.1 is a known-good vLLM that supports the qwen3_5 arch.
# Bumping this is a deliberate, tested change — newer vLLM has broken the toolchain before.
VLLM_VERSION="${VLLM_VERSION:-0.27.1}"
MIN_DRIVER_MAJOR="${MIN_DRIVER_MAJOR:-580}"

log() { echo "[bootstrap $(date -u +%H:%M:%S)] $*"; }
die() { echo "[bootstrap ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root (sudo)"
[ -f "$MAKATO_HOME/infra/vllm-serve.yaml" ] || die "MAKATO_HOME=$MAKATO_HOME has no infra/vllm-serve.yaml — clone/rsync makato-oss there first"
command -v uv >/dev/null || die "uv not found — install it first (curl -LsSf https://astral.sh/uv/install.sh | sh)"

MODEL="$(sed -nE 's/^model:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$MAKATO_HOME/infra/vllm-serve.yaml" | head -1)"
[ -n "$MODEL" ] || die "could not read model: from infra/vllm-serve.yaml"

# ── Phase 1: NVIDIA driver >= CUDA 13 ─────────────────────────────────────────
driver_major=0
if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    driver_major="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)"
fi
if [ "${driver_major:-0}" -ge "$MIN_DRIVER_MAJOR" ] 2>/dev/null; then
    log "driver phase: driver major $driver_major >= $MIN_DRIVER_MAJOR (CUDA 13 capable) — skip"
else
    log "driver phase: installing nvidia-driver-$MIN_DRIVER_MAJOR (current major: ${driver_major:-none})"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # DKMS needs headers for the running kernel to build the driver module. We also pull
    # build-essential (Phase 2's toolchain) in this SAME apt pass so the post-reboot re-run
    # needs no apt at all — some re-provisioned vast.ai boxes ship a broken /etc/environment
    # that makes apt fail (see docs/vast-ai-llm-deployment.md → "gotchas").
    apt-get install -y "linux-headers-$(uname -r)" "nvidia-driver-$MIN_DRIVER_MAJOR" build-essential
    # Reboot NOW, before building the venv. If we let Phases 3+ run on the still-loaded old
    # driver, `uv --torch-backend=auto` detects the OLD CUDA version and installs a torch that
    # mismatches vLLM's CUDA-13 binary → a broken venv that a later re-run will not repair.
    # Exiting here guarantees the venv is only ever built against the CUDA 13 driver.
    log "driver phase: installed. Rebooting now to load the new kernel module."
    log "IMPORTANT: RE-RUN this script once the box is back — it will skip the driver and"
    log "           build the venv + model + systemd against the correct CUDA 13 runtime."
    sleep 3
    reboot
    exit 0
fi

# ── Phase 2: build toolchain (nvcc host compiler + linker for kernel JIT) ──────
# gcc is the host compiler nvcc drives; ninja is installed into the venv in Phase 3.
if command -v gcc >/dev/null 2>&1; then
    log "build-toolchain phase: gcc present — skip"
else
    log "build-toolchain phase: installing build-essential"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y build-essential
fi

# ── Phase 3: Python venv + vLLM ───────────────────────────────────────────────
if [ -x "$VLLM_VENV/bin/vllm" ] && "$VLLM_VENV/bin/python" -c 'import vllm' >/dev/null 2>&1; then
    log "vllm phase: $("$VLLM_VENV"/bin/python -c 'import vllm; print("vllm "+vllm.__version__)') already installed — skip"
else
    log "vllm phase: creating Python $PYTHON_VERSION venv and installing vllm==$VLLM_VERSION (cu13)"
    uv venv "$VLLM_VENV" --python "$PYTHON_VERSION"
    # --torch-backend=auto detects the driver and selects the matching CUDA build of torch.
    # ninja is required by the runtime kernel JIT; huggingface_hub provides the `hf` CLI.
    uv pip install --python "$VLLM_VENV/bin/python" --torch-backend=auto \
        "vllm==$VLLM_VERSION" huggingface_hub ninja
    log "vllm phase: $("$VLLM_VENV"/bin/python -c 'import vllm,torch; print("vllm "+vllm.__version__+" / torch "+torch.__version__)')"
fi

# ── Phase 4: model weights ────────────────────────────────────────────────────
# Always ask huggingface_hub to resolve the complete repository. It reuses verified cache
# entries, while a glob for one safetensors file can mistake an interrupted sharded-model
# download for a complete snapshot.
log "model phase: ensuring the complete $MODEL snapshot is cached (~27 GB on a cold box)"
# The repo is GATED: you must request access on its HF page AND provide an HF token with
# that access. `hf` reads HF_TOKEN from the env or ~/.cache/huggingface/token. Fail early
# with an actionable message instead of vLLM later dying on missing weights.
if ! "$VLLM_VENV/bin/hf" download "$MODEL"; then
    die "model download failed. $MODEL is gated — request access at
        https://huggingface.co/$MODEL then re-run with an approved token:
            HF_TOKEN=hf_xxx sudo -E MAKATO_HOME=$MAKATO_HOME bash infra/bootstrap-vllm.sh"
fi
log "model phase: complete snapshot available"

# ── Phase 5: systemd service ──────────────────────────────────────────────────
log "systemd phase: installing and enabling vllm.service (auto-start on boot)"
install -m 0644 "$MAKATO_HOME/infra/vllm.service" /etc/systemd/system/vllm.service
# Reflect the resolved paths/port into a drop-in so the unit stays generic in the repo.
mkdir -p /etc/systemd/system/vllm.service.d
cat > /etc/systemd/system/vllm.service.d/10-paths.conf <<EOF
[Service]
Environment=MAKATO_HOME=$MAKATO_HOME
Environment=VLLM_VENV=$VLLM_VENV
Environment=VLLM_PORT=$VLLM_PORT
ExecStart=
ExecStart=$MAKATO_HOME/infra/vllm-serve.sh
EOF
chmod +x "$MAKATO_HOME/infra/vllm-serve.sh"
systemctl daemon-reload
systemctl enable vllm.service

# ── Phase 6: omp (oh-my-pi) model config ──────────────────────────────────────
# The harness binary is provisioned separately (not by this script), but its
# model config is version-controlled here so a re-provision restores the correct
# endpoint/model/token-budget instead of an ad-hoc hand-edited file. Guarded on
# omp being present so boxes that only serve vLLM are unaffected.
OMP_MODELS_DEST="${OMP_MODELS_DEST:-/root/.omp/agent/models.yml}"
OMP_CONFIG_DEST="${OMP_CONFIG_DEST:-/root/.omp/agent/config.yml}"
if command -v omp >/dev/null 2>&1; then
    omp_existing=false
    if [ -s "$OMP_MODELS_DEST" ]; then
        omp_existing=true
    else
        log "omp phase: installing provider config at $OMP_MODELS_DEST"
        install -D -m 0644 "$MAKATO_HOME/infra/omp-models.yml" "$OMP_MODELS_DEST"
    fi
    if [ -s "$OMP_CONFIG_DEST" ]; then
        omp_existing=true
    else
        log "omp phase: installing role/tool settings at $OMP_CONFIG_DEST"
        install -D -m 0644 "$MAKATO_HOME/infra/omp-config.yml" "$OMP_CONFIG_DEST"
    fi
    if [ "$omp_existing" = true ]; then
        # Overwriting would discard settings added on the box since the last run, so restore
        # only the keys the qwen-vllm profile owns via the installer's merge. The vLLM venv's
        # Python already has the PyYAML the merge needs. A refused merge (the resolver prints
        # why and writes nothing) must not keep the vLLM endpoint from starting below.
        log "omp phase: merging the qwen-vllm profile into the existing OMP config (other settings kept)"
        if ! MAKATO_PYTHON_BIN="$VLLM_VENV/bin/python" OMP_MODELS_FILE="$OMP_MODELS_DEST" OMP_CONFIG_FILE="$OMP_CONFIG_DEST" \
            bash "$MAKATO_HOME/scripts/select-model-profile.sh" qwen-vllm; then
            log "omp phase: WARNING merge refused — $OMP_MODELS_DEST and $OMP_CONFIG_DEST left untouched; fix them and re-run"
        fi
    fi
else
    log "omp phase: omp not installed — skip (install the harness, then re-run to provision OMP config)"
fi

# Phase 1 reboots-and-exits when it installs the driver, so by the time control reaches
# here the driver is already CUDA 13 capable and the venv/model/systemd are all in place.
log "systemd phase: (re)starting vllm.service now"
systemctl restart vllm.service
log "DONE. Weights load + kernel JIT take a couple of minutes on first start."
log "Verify with:  curl -sf http://localhost:$VLLM_PORT/health && curl -s http://localhost:$VLLM_PORT/v1/models"
