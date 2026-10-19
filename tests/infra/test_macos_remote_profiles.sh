#!/usr/bin/env bash
# test_macos_remote_profiles.sh
#
# Platform/profile matrix smoke tests (local-openai-gpt-macos-compatibility,
# Task 5). Exercises scripts/macos-setup.sh, infra/bootstrap-vllm.sh,
# infra/vllm-serve.sh, scripts/preflight-omp-context.sh,
# scripts/preflight-model-runtime.sh, and scripts/preflight-optional-services.sh
# against mocked endpoints and PATH-stubbed commands (uname, curl, lspci,
# nvidia-smi, ssh) — no live network call, no real credential, no real
# provisioning. Tests pass on any OS (the platform under test is simulated
# via a stubbed `uname`, independent of the host actually running this file).
#
# Requires: bash >= 4, python3
#
# Usage:
#   bash tests/infra/test_macos_remote_profiles.sh
#   bash tests/infra/test_macos_remote_profiles.sh --verbose

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASS=0
FAIL=0
SKIP=0

# ── Test framework (assert helpers guard `$VERBOSE && echo` with `|| true` —
#    under `set -e`, an unguarded `false && …` as the last command in an
#    if-branch propagates its exit status and aborts the whole script) ───────
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (needle '$needle' not found)"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (forbidden needle '$needle' WAS found)"
  else
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  fi
}

run_suite() {
  echo ""
  echo "=== $1 ==="
}

# ── Scratch sandbox (repo-local — never /tmp) ─────────────────────────────────
SCRATCH_DIR="$REPO_ROOT/tests/infra/.scratch-macos-remote-profiles-$$"
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR/bin"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

# Symlink every real tool macos-setup.sh looks up into $SCRATCH_DIR/bin,
# except any names passed as extra args — used to simulate "tool X missing"
# without needing to actually uninstall anything on the test host. Always
# includes the core POSIX utilities the scripts under test call externally
# (dirname/head/chmod/mkdir/python3) so PATH can be set to this dir ALONE
# (no real-PATH fallback) — required because macOS ships its own /usr/bin/jq
# and /usr/bin/python3 that would otherwise defeat an "excluded" tool test.
build_full_toolchain_path() {
  local dir="$1"
  shift
  local exclude=("$@")
  mkdir -p "$dir"
  local tool real skip
  for tool in dirname head chmod mkdir ln rm cat \
              brew bash python3 python3.15 node gh jq docker omp npx curl ssh; do
    skip=false
    for e in "${exclude[@]:-}"; do
      [[ "$tool" == "$e" ]] && skip=true
    done
    $skip && continue
    real="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$real" ]] && ln -sf "$real" "$dir/$tool"
  done
}

write_uname_stub() {
  # $1=dir $2=kernel-name (Darwin|Linux) $3=machine (arm64|x86_64, optional)
  local dir="$1" kernel="$2" machine="${3:-arm64}"
  mkdir -p "$dir"
  cat > "$dir/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -s) echo "$kernel" ;;
  -m) echo "$machine" ;;
  *) echo "$kernel" ;;
esac
EOF
  chmod +x "$dir/uname"
}

write_omp_fixture() {
  # $1=dir $2=provider, writes models.yml with one model under
  # providers.<provider>, carrying the context/output budgets that
  # preflight-omp-context.sh reads from that provider's entry; config.yml
  # comes from write_omp_config_for_profile.
  local dir="$1" provider="$2"
  local context_window=65536 max_tokens=8192
  case "$provider" in
    openai)
      context_window=128000
      max_tokens=16384
      ;;
    ollama)
      context_window=32768
      ;;
  esac
  mkdir -p "$dir"
  cat > "$dir/models.yml" <<EOF
providers:
  ${provider}:
    models:
      - id: open
        contextWindow: ${context_window}
        maxTokens: ${max_tokens}
EOF
}

write_omp_config_for_profile() {
  # $1=dir $2=profile-name — regenerates config.yml straight from the real
  # resolver so role mappings always match config/model-profiles.yml exactly.
  local dir="$1" profile="$2"
  python3 "$REPO_ROOT/scripts/resolve-model-profile.py" "$profile" --emit omp-config > "$dir/config.yml"
}

write_curl_stub_json() {
  # $1=path $2=json body to always print (used for the qwen-vllm deep probe)
  cat > "$1" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
$2
JSON
EOF
  chmod +x "$1"
}

write_curl_stub_status() {
  # $1=path $2=http status code to always print (used for openai/ollama probe)
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo -n "$2"
EOF
  chmod +x "$1"
}

# =============================================================================
# Suite 1: scripts/macos-setup.sh — platform guard + tool report
# =============================================================================
run_suite "scripts/macos-setup.sh"

MACOS_SETUP="$REPO_ROOT/scripts/macos-setup.sh"
assert_eq "macos-setup.sh exists" "0" "$([[ -f "$MACOS_SETUP" ]] && echo 0 || echo 1)"

# -- Darwin/arm64, full toolchain present --
DARWIN_BIN="$SCRATCH_DIR/darwin-bin"
write_uname_stub "$DARWIN_BIN" "Darwin" "arm64"
build_full_toolchain_path "$DARWIN_BIN"
OUT="$(PATH="$DARWIN_BIN:$PATH" bash "$MACOS_SETUP" --dry-run 2>&1)" && RC=0 || RC=$?
assert_eq "Darwin/arm64 + full toolchain: exit 0" "0" "$RC"
assert_contains "Darwin/arm64: reports Darwin arm64" "$OUT" "Darwin arm64"
assert_contains "Darwin/arm64: never installs CUDA/vLLM locally" "$OUT" "never installs CUDA/vLLM locally"
assert_not_contains "Darwin/arm64: does not attempt CUDA install" "$OUT" "nvidia-driver"

# -- Darwin, one required tool (jq) missing --
DARWIN_MISSING_JQ="$SCRATCH_DIR/darwin-missing-jq"
write_uname_stub "$DARWIN_MISSING_JQ" "Darwin" "arm64"
build_full_toolchain_path "$DARWIN_MISSING_JQ" jq
# PATH is the stub dir ALONE (no real-PATH fallback) — macOS ships its own
# /usr/bin/jq, which would otherwise silently satisfy `command -v jq` and
# defeat this "jq missing" scenario.
OUT="$(PATH="$DARWIN_MISSING_JQ" bash "$MACOS_SETUP" --dry-run 2>&1)" && RC=0 || RC=$?
assert_eq "Darwin missing jq: exit 1 (actionable)" "1" "$RC"
assert_contains "Darwin missing jq: MISSING line names jq" "$OUT" "MISSING: jq"
assert_contains "Darwin missing jq: gives brew install hint" "$OUT" "brew install jq"

# -- Non-Darwin (Linux) refuses with actionable diagnostic --
LINUX_BIN="$SCRATCH_DIR/linux-bin"
write_uname_stub "$LINUX_BIN" "Linux" "x86_64"
OUT="$(PATH="$LINUX_BIN:$PATH" bash "$MACOS_SETUP" --dry-run 2>&1)" && RC=0 || RC=$?
assert_eq "Linux host: exit 1" "1" "$RC"
assert_contains "Linux host: names macOS/Darwin-only" "$OUT" "macOS (Darwin) clients only"
assert_contains "Linux host: points to bootstrap-vllm.sh" "$OUT" "infra/bootstrap-vllm.sh"

# -- Usage error --
OUT="$(bash "$MACOS_SETUP" --this-flag-does-not-exist 2>&1)" && RC=0 || RC=$?
assert_eq "unknown flag: exit 2 (usage error)" "2" "$RC"

# =============================================================================
# Suite 2: infra/bootstrap-vllm.sh — Linux/NVIDIA guard
# =============================================================================
run_suite "infra/bootstrap-vllm.sh"

BOOTSTRAP="$REPO_ROOT/infra/bootstrap-vllm.sh"

# -- Darwin refuses --
OUT="$(PATH="$DARWIN_BIN:$PATH" bash "$BOOTSTRAP" 2>&1)" && RC=0 || RC=$?
assert_eq "Darwin: bootstrap-vllm.sh exits nonzero" "1" "$RC"
assert_contains "Darwin: names Linux-only requirement" "$OUT" "only runs on Linux"
assert_contains "Darwin: points to macos-setup.sh" "$OUT" "scripts/macos-setup.sh"

# -- Linux, no lspci available: guard passes through to the next check --
OUT="$(PATH="$LINUX_BIN:$PATH" bash "$BOOTSTRAP" 2>&1)" && RC=0 || RC=$?
assert_eq "Linux (no lspci): still fails, but past the platform guard" "1" "$RC"
assert_contains "Linux (no lspci): reaches the root-privilege check, not a platform error" "$OUT" "must run as root"

# -- Linux, lspci present but no NVIDIA device --
LINUX_NO_GPU="$SCRATCH_DIR/linux-no-gpu"
write_uname_stub "$LINUX_NO_GPU" "Linux" "x86_64"
cat > "$LINUX_NO_GPU/lspci" <<'EOF'
#!/usr/bin/env bash
echo "00:00.0 Host bridge: Intel Corporation Device 1234"
EOF
chmod +x "$LINUX_NO_GPU/lspci"
OUT="$(PATH="$LINUX_NO_GPU:$PATH" bash "$BOOTSTRAP" 2>&1)" && RC=0 || RC=$?
assert_eq "Linux, no NVIDIA GPU: exits nonzero" "1" "$RC"
assert_contains "Linux, no NVIDIA GPU: names NVIDIA requirement" "$OUT" "NVIDIA GPU"

# =============================================================================
# Suite 3: infra/vllm-serve.sh — platform/runtime diagnostics
# =============================================================================
run_suite "infra/vllm-serve.sh"

VLLM_SERVE="$REPO_ROOT/infra/vllm-serve.sh"

# -- Darwin refuses, suggests an OpenAI-compatible profile instead --
OUT="$(PATH="$DARWIN_BIN:$PATH" bash "$VLLM_SERVE" 2>&1)" && RC=0 || RC=$?
assert_eq "Darwin: vllm-serve.sh exits nonzero" "1" "$RC"
assert_contains "Darwin: names Linux/NVIDIA requirement" "$OUT" "Linux/NVIDIA"
assert_contains "Darwin: suggests apple-ollama/openai profile" "$OUT" "apple-ollama"

# -- Linux, no nvidia-smi --
OUT="$(PATH="$LINUX_BIN:$PATH" bash "$VLLM_SERVE" 2>&1)" && RC=0 || RC=$?
assert_eq "Linux, no nvidia-smi: exits nonzero" "1" "$RC"
assert_contains "Linux, no nvidia-smi: names nvidia-smi" "$OUT" "nvidia-smi"

# -- Linux, nvidia-smi present, no vllm venv (pre-existing behaviour preserved) --
LINUX_WITH_GPU="$SCRATCH_DIR/linux-with-gpu"
write_uname_stub "$LINUX_WITH_GPU" "Linux" "x86_64"
cat > "$LINUX_WITH_GPU/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "fake nvidia-smi"
exit 0
EOF
chmod +x "$LINUX_WITH_GPU/nvidia-smi"
OUT="$(PATH="$LINUX_WITH_GPU:$PATH" bash "$VLLM_SERVE" 2>&1)" && RC=0 || RC=$?
assert_eq "Linux + nvidia-smi, no venv: exits nonzero" "1" "$RC"
assert_contains "Linux + nvidia-smi: names bootstrap-vllm.sh" "$OUT" "infra/bootstrap-vllm.sh"

# =============================================================================
# Suite 4: profile matrix — scripts/preflight-omp-context.sh
# =============================================================================
run_suite "scripts/preflight-omp-context.sh (profile matrix)"

PREFLIGHT_CTX="$REPO_ROOT/scripts/preflight-omp-context.sh"

# -- qwen-vllm: deep context-window probe, backward-compatible default --
QWEN_OMP="$SCRATCH_DIR/omp-qwen"
write_omp_fixture "$QWEN_OMP" "local"
write_omp_config_for_profile "$QWEN_OMP" "qwen-vllm"
QWEN_CURL_BIN="$SCRATCH_DIR/qwen-curl-bin"
mkdir -p "$QWEN_CURL_BIN"
write_curl_stub_json "$QWEN_CURL_BIN/curl" '{"data":[{"id":"open","max_model_len":65536}]}'
OUT="$(PATH="$QWEN_CURL_BIN:$PATH" OMP_MODELS_FILE="$QWEN_OMP/models.yml" OMP_CONFIG_FILE="$QWEN_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=qwen-vllm bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "qwen-vllm: exit 0" "0" "$RC"
assert_contains "qwen-vllm: reports context_length" "$OUT" "context_length=65536"

# -- openai: credential present, endpoint reachable --
OPENAI_OMP="$SCRATCH_DIR/omp-openai"
write_omp_fixture "$OPENAI_OMP" "openai"
write_omp_config_for_profile "$OPENAI_OMP" "openai"
STATUS_CURL_BIN="$SCRATCH_DIR/status-curl-bin"
mkdir -p "$STATUS_CURL_BIN"
write_curl_stub_status "$STATUS_CURL_BIN/curl" "200"
OUT="$(PATH="$STATUS_CURL_BIN:$PATH" OMP_MODELS_FILE="$OPENAI_OMP/models.yml" OMP_CONFIG_FILE="$OPENAI_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=openai OPENAI_API_KEY="sk-TESTONLY-do-not-leak-1234567890" bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "openai + credential + reachable: exit 0" "0" "$RC"
assert_contains "openai: reports provider=openai" "$OUT" "provider=openai"
assert_not_contains "openai: never echoes the credential value" "$OUT" "sk-TESTONLY-do-not-leak-1234567890"

# -- openai: credential MISSING --
OUT="$(PATH="$STATUS_CURL_BIN:$PATH" OMP_MODELS_FILE="$OPENAI_OMP/models.yml" OMP_CONFIG_FILE="$OPENAI_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=openai env -u OPENAI_API_KEY bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "openai, missing credential: exit 1 (actionable)" "1" "$RC"
assert_contains "openai, missing credential: names OPENAI_API_KEY" "$OUT" "OPENAI_API_KEY"
assert_contains "openai, missing credential: value not shown" "$OUT" "value not shown"

# -- apple-ollama: no credential required --
OLLAMA_OMP="$SCRATCH_DIR/omp-ollama"
write_omp_fixture "$OLLAMA_OMP" "ollama"
write_omp_config_for_profile "$OLLAMA_OMP" "apple-ollama"
OUT="$(PATH="$STATUS_CURL_BIN:$PATH" OMP_MODELS_FILE="$OLLAMA_OMP/models.yml" OMP_CONFIG_FILE="$OLLAMA_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=apple-ollama bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "apple-ollama, no credential: exit 0" "0" "$RC"
assert_contains "apple-ollama: reports provider=ollama" "$OUT" "provider=ollama"

# -- malformed/unsupported profile name --
OUT="$(MAKATO_MODEL_PROFILE=totally-bogus-profile bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "malformed profile: exit 1" "1" "$RC"
assert_contains "malformed profile: names it unsupported" "$OUT" "Unsupported provider profile"

# -- unreachable endpoint --
UNREACHABLE_CURL_BIN="$SCRATCH_DIR/unreachable-curl-bin"
mkdir -p "$UNREACHABLE_CURL_BIN"
write_curl_stub_status "$UNREACHABLE_CURL_BIN/curl" "000"
OUT="$(PATH="$UNREACHABLE_CURL_BIN:$PATH" OMP_MODELS_FILE="$OPENAI_OMP/models.yml" OMP_CONFIG_FILE="$OPENAI_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=openai OPENAI_API_KEY="sk-TESTONLY-2" bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "openai, unreachable endpoint: exit 1" "1" "$RC"
assert_contains "openai, unreachable endpoint: names it unreachable" "$OUT" "unreachable"

# -- tool_format mismatch (OMP config declares the wrong tools.format) --
MISMATCH_OMP="$SCRATCH_DIR/omp-mismatch"
write_omp_fixture "$MISMATCH_OMP" "openai"
write_omp_config_for_profile "$MISMATCH_OMP" "openai"
sed -i.bak 's/format: openai/format: qwen3/' "$MISMATCH_OMP/config.yml" && rm -f "$MISMATCH_OMP/config.yml.bak"
OUT="$(PATH="$STATUS_CURL_BIN:$PATH" OMP_MODELS_FILE="$MISMATCH_OMP/models.yml" OMP_CONFIG_FILE="$MISMATCH_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=openai OPENAI_API_KEY="sk-TESTONLY-3" bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "tool_format mismatch: exit 1" "1" "$RC"
assert_contains "tool_format mismatch: names tools.format" "$OUT" "tools.format"

# -- installer-merged OMP files: each check reads only its own YAML block --
# select-model-profile.sh merges into the user's files, so same-named keys in
# other blocks (a fallback chain's `default`, another provider's budgets,
# another section's `format`) can precede the ones preflight must read.
MERGED_OMP="$SCRATCH_DIR/omp-merged"
mkdir -p "$MERGED_OMP"
cat > "$MERGED_OMP/config.yml" <<'EOF'
retry:
  fallbackChains:
    default: decoy/fallback
lint:
  format: decoy
modelRoles:
  web: decoy/web
EOF
cat > "$MERGED_OMP/models.yml" <<'EOF'
providers:
  decoy:
    models:
      - id: tiny
        contextWindow: 1024
        maxTokens: 999999
EOF
OMP_MODELS_FILE="$MERGED_OMP/models.yml" OMP_CONFIG_FILE="$MERGED_OMP/config.yml" OPENAI_API_KEY="sk-TESTONLY-4" \
  bash "$REPO_ROOT/scripts/select-model-profile.sh" openai >/dev/null 2>&1 && RC=0 || RC=$?
assert_eq "merge openai into OMP files with decoy blocks: exit 0" "0" "$RC"
OUT="$(PATH="$STATUS_CURL_BIN:$PATH" OMP_MODELS_FILE="$MERGED_OMP/models.yml" OMP_CONFIG_FILE="$MERGED_OMP/config.yml" \
  MAKATO_MODEL_PROFILE=openai OPENAI_API_KEY="sk-TESTONLY-4" bash "$PREFLIGHT_CTX" 2>&1)" && RC=0 || RC=$?
assert_eq "merged OMP files with decoy blocks: exit 0" "0" "$RC"
assert_contains "merged OMP files: budgets come from the profile's provider" "$OUT" "contextWindow=128000, maxTokens=16384"
assert_contains "merged OMP files: tools.format comes from the tools block" "$OUT" "tools.format=openai"

# =============================================================================
# Suite 5: scripts/preflight-model-runtime.sh — Gate 6 orchestrator
# =============================================================================
run_suite "scripts/preflight-model-runtime.sh (Gate 6)"

GATE6="$REPO_ROOT/scripts/preflight-model-runtime.sh"

OUT="$(PATH="$QWEN_CURL_BIN:$PATH" OMP_MODELS_FILE="$QWEN_OMP/models.yml" OMP_CONFIG_FILE="$QWEN_OMP/config.yml" \
  MAKATO_SKIP_OPTIONAL_PREFLIGHT=1 bash "$GATE6" 2>&1)" && RC=0 || RC=$?
assert_eq "Gate 6, qwen-vllm, required-only: exit 0" "0" "$RC"
assert_contains "Gate 6: reports overall pass" "$OUT" "Gate 6 model-runtime preflight passed"
assert_not_contains "Gate 6, required-only: skips the optional section" "$OUT" "optional-service checks"

OUT="$(MAKATO_MODEL_PROFILE=totally-bogus-profile bash "$GATE6" 2>&1)" && RC=0 || RC=$?
assert_eq "Gate 6, malformed profile: exit 1" "1" "$RC"
assert_contains "Gate 6, malformed profile: fails structural validation" "$OUT" "failed structural validation"

# =============================================================================
# Suite 6: scripts/preflight-optional-services.sh — endpoint classification,
# skip semantics, and secret redaction
# =============================================================================
run_suite "scripts/preflight-optional-services.sh"

OPTIONAL="$REPO_ROOT/scripts/preflight-optional-services.sh"

# -- default: nothing configured — every unconfigured service is an explicit SKIP --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_eq "optional services, nothing configured: exit 0 (advisory only)" "0" "$RC"
assert_contains "optional services: Langfuse explicit SKIP" "$OUT" "SKIP: Langfuse OTLP"
assert_contains "optional services: Postgres explicit SKIP" "$OUT" "SKIP: Postgres"
assert_contains "optional services: Temporal explicit SKIP" "$OUT" "SKIP: Temporal"
assert_contains "optional services: Sagibeast explicit SKIP" "$OUT" "SKIP: Sagibeast"
assert_not_contains "optional services: never a bare 'healthy' claim" "$OUT" "healthy"

# -- Langfuse: local endpoint, unreachable --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null LANGFUSE_OTLP_ENDPOINT="http://localhost:59999/api/public/otel/v1/traces" \
  bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_contains "Langfuse local unreachable: WARN" "$OUT" "WARN: Langfuse OTLP"
assert_contains "Langfuse local unreachable: labelled local" "$OUT" "(local)"

# -- Langfuse: remote-looking endpoint, unreachable — still labelled remote --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null LANGFUSE_OTLP_ENDPOINT="http://langfuse.example.invalid:1/otel" \
  bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_contains "Langfuse remote endpoint: labelled remote" "$OUT" "(remote)"

# -- Postgres: embedded credential is redacted, never printed in the clear --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null POSTGRES_URL="postgres://dbuser:SuperSecretDbPass1@localhost:59998/langfuse" \
  bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_not_contains "Postgres: credential never echoed in the clear" "$OUT" "SuperSecretDbPass1"
assert_contains "Postgres: connection string is redacted" "$OUT" "[REDACTED]@localhost:59998"

# -- Temporal: malformed address (no port) is an actionable WARN, not silent --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null TEMPORAL_ADDRESS="localhost" bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_contains "Temporal malformed address: WARN with actionable reason" "$OUT" "must be host:port"

# -- Sagibeast/testbox: no alias configured -> explicit SKIP (never silently healthy) --
OUT="$(SAGIBEAST_SSH_CONFIG=/dev/null bash "$OPTIONAL" 2>&1)" && RC=0 || RC=$?
assert_contains "Sagibeast, no alias: explicit SKIP" "$OUT" "SKIP: Sagibeast/testbox"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
