#!/usr/bin/env bash
# macos-setup.sh — non-secret macOS setup/preflight for Makato OSS Apple
# Silicon clients (local-openai-gpt-macos-compatibility, Task 5).
#
# Reports (and, with --install, installs via Homebrew) the tools an Apple
# Silicon client needs — Homebrew Bash (>=4; the macOS-shipped /bin/bash is
# 3.2 and unsupported by this repo's scripts), Python 3.14, Node.js, gh, jq,
# OMP (oh-my-pi), and Docker Desktop — then checks/installs the selected
# model profile via scripts/select-model-profile.sh.
#
# This command NEVER attempts CUDA/vLLM installation. That remains the
# remote Linux/NVIDIA-only path (infra/bootstrap-vllm.sh); running this
# script never provisions a GPU endpoint.
#
# Usage:
#   bash scripts/macos-setup.sh                  # --dry-run (default): report only
#   bash scripts/macos-setup.sh --install         # brew-install missing tools + install the model profile
#   bash scripts/macos-setup.sh --profile openai  # check/install a specific profile (default: qwen-vllm)
#
# Env overrides: MAKATO_MODEL_PROFILE, MODEL_PROFILES_FILE, MAKATO_PYTHON_BIN.
#
# Exit codes:
#   0  all required tools present (dry-run) / installed successfully (--install),
#      and the model profile validated/installed cleanly
#   1  running on a non-Darwin host, a required tool is missing (dry-run), an
#      install step failed (--install), or profile validation/install failed
#   2  usage error
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT_PROFILE="${REPO_ROOT}/scripts/select-model-profile.sh"

MODE="dry-run"
PROFILE="${MAKATO_MODEL_PROFILE:-qwen-vllm}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --install)
      MODE="install"
      shift
      ;;
    --profile)
      [ $# -ge 2 ] || { echo "macos-setup: --profile requires a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    *)
      echo "macos-setup: unknown argument '$1'" >&2
      echo "Usage: $0 [--dry-run|--install] [--profile <name>]" >&2
      exit 2
      ;;
  esac
done

# ── Platform guard ────────────────────────────────────────────────────────────
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Darwin" ]; then
  echo "ERROR: scripts/macos-setup.sh is for macOS (Darwin) clients only — detected '${OS_NAME}'." >&2
  echo "  Remote Linux/NVIDIA provisioning uses infra/bootstrap-vllm.sh instead." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "WARN: detected architecture '${ARCH}' — Apple Silicon (arm64) is the primary supported target; Intel Macs may need manual adjustment."
fi

echo "=== macOS setup/preflight (Darwin ${ARCH}, mode=${MODE}, profile=${PROFILE}) ==="
echo "This command never installs CUDA/vLLM locally — remote Linux/NVIDIA provisioning is a separate path (infra/bootstrap-vllm.sh)."
echo ""

FAIL=0

# check_tool: $1=display name, $2=binary to look up, $3=brew formula ("" = no
# tracked formula), $4=version command (optional), $5="cask" to brew-install
# via --cask instead of a formula.
check_tool() {
  local name="$1" bin="$2" formula="$3" vercmd="${4:-}" kind="${5:-}"
  if command -v "$bin" >/dev/null 2>&1; then
    local ver=""
    if [ -n "$vercmd" ]; then
      ver=" ($($vercmd 2>&1 | head -1))"
    fi
    echo "PASS: ${name} found at $(command -v "$bin")${ver}"
    return 0
  fi

  if [ "$MODE" = "install" ] && [ -n "$formula" ]; then
    local -a brew_flags=()
    local brew_display="brew install"
    if [ "$kind" = "cask" ]; then
      brew_flags+=(--cask)
      brew_display+=" --cask"
    fi
    echo "INSTALLING: ${name} via '${brew_display} ${formula}'"
    if brew install "${brew_flags[@]}" "$formula"; then
      echo "PASS: ${name} installed"
      return 0
    fi
    echo "ERROR: ${name} install failed (${brew_display} ${formula})" >&2
    FAIL=$((FAIL + 1))
    return 1
  fi

  if [ -n "$formula" ]; then
    local -a brew_flags=()
    local brew_display="brew install"
    if [ "$kind" = "cask" ]; then
      brew_flags+=(--cask)
      brew_display+=" --cask"
    fi
    echo "MISSING: ${name} — install with: ${brew_display} ${formula}" >&2
  else
    echo "MISSING: ${name} — no brew formula tracked here; see its own installation docs" >&2
  fi
  FAIL=$((FAIL + 1))
  return 1
}

# ── Homebrew (required for every other check/install below) ──────────────────
if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew not found. Install it first: https://brew.sh" >&2
  exit 1
fi
echo "PASS: Homebrew found at $(command -v brew)"

# ── Bash >= 4 (macOS ships /bin/bash 3.2) ─────────────────────────────────────
BASH_BIN="$(command -v bash || true)"
if [ -z "$BASH_BIN" ]; then
  echo "MISSING: Bash — install with: brew install bash" >&2
  FAIL=$((FAIL + 1))
else
  BASH_MAJOR="$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}"')"
  if [ "$BASH_MAJOR" -ge 4 ]; then
    echo "PASS: Bash ${BASH_MAJOR}.x found at ${BASH_BIN}"
  elif [ "$MODE" = "install" ]; then
    echo "INSTALLING: Bash via 'brew install bash'"
    if brew install bash; then
      echo "PASS: Bash installed — ensure /opt/homebrew/bin precedes /usr/bin on PATH to use it as 'bash'"
    else
      echo "ERROR: Bash install failed (brew install bash)" >&2
      FAIL=$((FAIL + 1))
    fi
  else
    echo "MISSING: Bash on PATH is ${BASH_MAJOR}.x (need >=4) at ${BASH_BIN} — install with: brew install bash" >&2
    echo "  Then ensure /opt/homebrew/bin precedes /usr/bin on PATH." >&2
    FAIL=$((FAIL + 1))
  fi
fi

# ── Required tools ─────────────────────────────────────────────────────────────
check_tool "Python 3.14" python3.14 "python@3.14" "python3.14 --version" || true
check_tool "Node.js"     node       "node"         "node --version"       || true
check_tool "GitHub CLI"  gh         "gh"           "gh --version"         || true
check_tool "jq"          jq         "jq"           "jq --version"         || true
check_tool "OMP (oh-my-pi)" omp     ""             "omp --version"        || true

# Docker Desktop: brew cask installs the app, but a running daemon requires
# the app to be launched — that is checked separately and only WARNs.
check_tool "Docker Desktop" docker "docker" "docker --version" "cask" || true
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "PASS: Docker Desktop daemon is running"
  else
    echo "WARN: Docker Desktop is installed but its daemon is not running — start it with: open -a Docker"
  fi
fi

# ── Model profile check/install ───────────────────────────────────────────────
echo ""
if [ ! -f "$SELECT_PROFILE" ]; then
  echo "ERROR: profile installer not found at ${SELECT_PROFILE}" >&2
  FAIL=$((FAIL + 1))
elif [ "$MODE" = "install" ]; then
  echo "=== installing model profile '${PROFILE}' ==="
  if ! bash "$SELECT_PROFILE" "$PROFILE"; then
    echo "ERROR: profile install failed for '${PROFILE}' — see output above" >&2
    FAIL=$((FAIL + 1))
  fi
else
  echo "=== model profile '${PROFILE}' (dry-run — nothing written) ==="
  if ! bash "$SELECT_PROFILE" "$PROFILE" --dry-run; then
    echo "ERROR: profile '${PROFILE}' failed dry-run validation — see output above" >&2
    FAIL=$((FAIL + 1))
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: ${FAIL} check(s) did not pass — see MISSING/ERROR lines above" >&2
  exit 1
fi
echo "OK: macOS setup/preflight passed (mode=${MODE}, profile=${PROFILE})"
