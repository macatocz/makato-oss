#!/usr/bin/env bash
# Launch wrapper for the open vLLM endpoint, invoked by the vllm.service systemd unit
# (and runnable by hand for debugging). It resolves the runtime environment that the
# ThinkingCap-Qwen3.6-27B (arch `qwen3_5`, a hybrid Mamba/GatedDeltaNet model) needs on
# a vast.ai RTX 4090 box, then execs `vllm serve` against infra/vllm-serve.yaml.
#
# Why a wrapper instead of a bare ExecStart line: the model JIT-compiles CUDA kernels at
# startup (GatedDeltaNet + attention), which requires nvcc on PATH and a valid CUDA_HOME.
# The only CUDA 13 toolkit on the box is the one bundled inside the venv by the pip
# `nvidia-*-cu13` wheels, so CUDA_HOME must point there and cannot be hard-coded (the
# site-packages path embeds the Python minor version, e.g. python3.12).
#
# See docs/vast-ai-llm-deployment.md for the full rationale behind every flag here.
set -euo pipefail

# ── Platform guard ────────────────────────────────────────────────────────────
# This wrapper launches a CUDA-JIT-compiling vLLM build and only runs on
# Linux/NVIDIA. It never attempts CUDA setup on Apple Silicon — macOS clients
# use an OpenAI-compatible profile (apple-ollama or openai) instead; see
# scripts/macos-setup.sh and config/model-profiles.yml.
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "vllm-serve: this wrapper provisions a Linux/NVIDIA CUDA runtime and only runs on Linux — detected '$OS_NAME'." >&2
    echo "vllm-serve: on macOS/Apple Silicon, select the 'apple-ollama' or 'openai' model profile instead (scripts/select-model-profile.sh)." >&2
    exit 1
fi
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo "vllm-serve: nvidia-smi not found or no NVIDIA GPU responding — this wrapper requires a Linux/NVIDIA GPU instance." >&2
    echo "vllm-serve: run infra/bootstrap-vllm.sh first if the driver has not been installed yet." >&2
    exit 1
fi

MAKATO_HOME="${MAKATO_HOME:-/root/makato-oss}"
VLLM_VENV="${VLLM_VENV:-/root/vllm-venv}"
VLLM_PORT="${VLLM_PORT:-8100}"

if [ ! -x "$VLLM_VENV/bin/vllm" ]; then
    echo "vllm-serve: no vllm binary at $VLLM_VENV/bin/vllm — run infra/bootstrap-vllm.sh first" >&2
    exit 1
fi

# The GatedDeltaNet kernels invoke nvcc at first inference. The pip nvidia-cu13 wheels ship
# a complete-enough CUDA 13 toolkit under site-packages/nvidia/cu13/{bin,include,lib}; point
# CUDA_HOME at it. Discover it via the bundled nvcc so the path stays Python-version-agnostic.
NVCC_PATH="$(find "$VLLM_VENV" -name nvcc -path '*cu13*' 2>/dev/null | head -1 || true)"
if [ -n "$NVCC_PATH" ]; then
    CUDA_HOME="$(dirname "$(dirname "$NVCC_PATH")")"
    export CUDA_HOME
    export PATH="$VLLM_VENV/bin:$CUDA_HOME/bin:$PATH"
else
    # No bundled toolkit found — let vLLM fall back to a system CUDA_HOME if one exists.
    export PATH="$VLLM_VENV/bin:$PATH"
fi

# FlashInfer's sampling kernels JIT-compile against a bundled cccl that is incompatible with
# the pip nvcc ("CUDA compiler and CUDA toolkit headers are incompatible"). Disabling the
# FlashInfer sampler makes vLLM use its native PyTorch sampler — correct, marginally slower,
# and free of the runtime compile. Override VLLM_USE_FLASHINFER_SAMPLER=1 only after a proper
# CUDA 13 toolkit is installed system-wide.
export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"

# --enforce-eager disables torch.compile / CUDA graph capture. It is kept on for reliable,
# fast startup on this hybrid model: capture triggers additional runtime compilation that has
# repeatedly failed on this box. Set VLLM_ENFORCE_EAGER=0 to attempt compiled mode once the
# toolchain is fully validated (higher throughput, slower and riskier startup).
EAGER_ARGS=(--enforce-eager)
if [ "${VLLM_ENFORCE_EAGER:-1}" = "0" ]; then
    EAGER_ARGS=()
fi

cd "$MAKATO_HOME"
echo "vllm-serve: starting vllm on :$VLLM_PORT (venv=$VLLM_VENV, CUDA_HOME=${CUDA_HOME:-unset}, flashinfer_sampler=$VLLM_USE_FLASHINFER_SAMPLER, eager=${VLLM_ENFORCE_EAGER:-1})"
exec "$VLLM_VENV/bin/vllm" serve --config infra/vllm-serve.yaml --port "$VLLM_PORT" "${EAGER_ARGS[@]}"
