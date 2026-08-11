#!/usr/bin/env bash
# budget-check.sh — Co-located resource budget enforcer for the A6000 instance.
#
# Checks that all three co-located services (makato-oss, sagibeast dev stack,
# vLLM AWQ engine) stay within their resource budgets:
#
#   1. vLLM VRAM consumption <= configured gpu_memory_utilization fraction
#   2. Sagibeast free RAM headroom >= 32 GB
#   3. No recent OOM-kill event in the kernel log
#
# Usage:
#   bash scripts/budget-check.sh          # full check, exits 0 on pass
#   bash scripts/budget-check.sh --vram   # VRAM check only
#   bash scripts/budget-check.sh --ram    # RAM check only
#   bash scripts/budget-check.sh --oom    # OOM-kill check only
#   bash scripts/budget-check.sh --json   # emit JSON result to stdout
#
# Environment variables:
#   VLLM_GPU_BUDGET_FRACTION  — max allowed GPU memory fraction (default: 0.85)
#   SAGIBEAST_MIN_FREE_RAM_GB — min sagibeast RAM headroom in GB (default: 32)
#   BUDGET_OOM_LOOKBACK_MIN   — minutes to look back for OOM events (default: 60)
#
# Exit codes:
#   0 — all budgets within limits
#   1 — one or more budget thresholds breached
#   2 — prerequisite tools missing or insufficient permissions

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
GPU_BUDGET_FRACTION="${VLLM_GPU_BUDGET_FRACTION:-0.85}"
MIN_FREE_RAM_GB="${SAGIBEAST_MIN_FREE_RAM_GB:-32}"
OOM_LOOKBACK_MIN="${BUDGET_OOM_LOOKBACK_MIN:-60}"

# ── Argument parsing ──────────────────────────────────────────────────────────
CHECK_VRAM=true
CHECK_RAM=true
CHECK_OOM=true
EMIT_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vram)   CHECK_VRAM=true;  CHECK_RAM=false; CHECK_OOM=false; shift ;;
    --ram)    CHECK_VRAM=false; CHECK_RAM=true;  CHECK_OOM=false; shift ;;
    --oom)    CHECK_VRAM=false; CHECK_RAM=false; CHECK_OOM=true;  shift ;;
    --json)   EMIT_JSON=true; shift ;;
    *)        echo "[budget-check] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── State ─────────────────────────────────────────────────────────────────────
PASS=true
FINDINGS=()     # human-readable finding strings
JSON_RESULTS=() # per-check JSON objects

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { [[ "$EMIT_JSON" == "false" ]] && echo "[budget-check] $*" || true; }
warn() { [[ "$EMIT_JSON" == "false" ]] && echo "[budget-check] WARN: $*" >&2 || true; }
fail() { PASS=false; FINDINGS+=("$*"); [[ "$EMIT_JSON" == "false" ]] && echo "[budget-check] FAIL: $*" >&2 || true; }

# ── VRAM check ────────────────────────────────────────────────────────────────
check_vram() {
  log "Checking vLLM VRAM usage (budget: ${GPU_BUDGET_FRACTION} of total)..."

  if ! command -v nvidia-smi &>/dev/null; then
    echo "[budget-check] ERROR: required command 'nvidia-smi' not found" >&2
    exit 2
  fi

  # nvidia-smi returns memory as "used MiB / total MiB" per GPU.
  # We sum across all GPUs to support multi-GPU configurations.
  local used_mib total_mib
  used_mib=$(nvidia-smi --query-gpu=memory.used  --format=csv,noheader,nounits 2>/dev/null \
              | awk '{sum+=$1} END {print sum}' || echo "0")
  total_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
              | awk '{sum+=$1} END {print sum}' || echo "0")

  if [[ "$total_mib" -eq 0 ]]; then
    warn "nvidia-smi returned 0 MiB total VRAM — GPU may not be present or driver issue."
    JSON_RESULTS+=("{\"check\":\"vram\",\"status\":\"skip\",\"reason\":\"total_mib=0\"}")
    return
  fi

  # Compute utilisation fraction using awk (avoids bc dependency).
  local utilisation
  utilisation=$(awk "BEGIN {printf \"%.4f\", ${used_mib}/${total_mib}}")

  local budget_mib
  budget_mib=$(awk "BEGIN {printf \"%d\", ${total_mib} * ${GPU_BUDGET_FRACTION}}")

  log "  GPU VRAM: ${used_mib} MiB used / ${total_mib} MiB total"
  log "  Utilisation: ${utilisation} (budget cap: ${GPU_BUDGET_FRACTION})"

  if awk "BEGIN {exit (${used_mib} <= ${budget_mib}) ? 0 : 1}"; then
    log "  VRAM: OK (${used_mib} MiB <= ${budget_mib} MiB budget)"
    JSON_RESULTS+=("{\"check\":\"vram\",\"status\":\"ok\",\"used_mib\":${used_mib},\"total_mib\":${total_mib},\"budget_mib\":${budget_mib},\"utilisation\":${utilisation}}")
  else
    fail "VRAM budget breached: ${used_mib} MiB used exceeds ${budget_mib} MiB (${GPU_BUDGET_FRACTION} * ${total_mib})"
    JSON_RESULTS+=("{\"check\":\"vram\",\"status\":\"fail\",\"used_mib\":${used_mib},\"total_mib\":${total_mib},\"budget_mib\":${budget_mib},\"utilisation\":${utilisation}}")
  fi
}

# ── RAM check ─────────────────────────────────────────────────────────────────
check_ram() {
  log "Checking sagibeast RAM headroom (min: ${MIN_FREE_RAM_GB} GB)..."

  if [[ ! -r /proc/meminfo ]]; then
    warn "/proc/meminfo not readable — RAM check skipped (non-Linux host?)"
    JSON_RESULTS+=("{\"check\":\"ram\",\"status\":\"skip\",\"reason\":\"proc_meminfo_unreadable\"}")
    return
  fi

  # MemAvailable is the kernel's estimate of immediately available RAM,
  # accounting for reclaimable caches — more accurate than MemFree alone.
  local avail_kb
  avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

  if [[ -z "$avail_kb" ]]; then
    warn "MemAvailable not found in /proc/meminfo — falling back to MemFree"
    avail_kb=$(awk '/^MemFree:/ {print $2}' /proc/meminfo || echo "0")
  fi

  local avail_gb
  avail_gb=$(awk "BEGIN {printf \"%.1f\", ${avail_kb}/1048576}")

  log "  Available RAM: ${avail_gb} GB (min required: ${MIN_FREE_RAM_GB} GB)"

  if awk "BEGIN {exit (${avail_gb} >= ${MIN_FREE_RAM_GB}) ? 0 : 1}"; then
    log "  RAM: OK (${avail_gb} GB >= ${MIN_FREE_RAM_GB} GB required)"
    JSON_RESULTS+=("{\"check\":\"ram\",\"status\":\"ok\",\"available_gb\":${avail_gb},\"min_required_gb\":${MIN_FREE_RAM_GB}}")
  else
    fail "RAM headroom insufficient: ${avail_gb} GB available, need >= ${MIN_FREE_RAM_GB} GB for sagibeast"
    JSON_RESULTS+=("{\"check\":\"ram\",\"status\":\"fail\",\"available_gb\":${avail_gb},\"min_required_gb\":${MIN_FREE_RAM_GB}}")
  fi
}

# ── OOM-kill check ────────────────────────────────────────────────────────────
check_oom() {
  log "Checking for OOM-kill events in the last ${OOM_LOOKBACK_MIN} minutes..."

  # dmesg is the most reliable source for OOM events on Linux.
  # Fall back gracefully on macOS / systems without dmesg access.
  if ! command -v dmesg &>/dev/null; then
    warn "dmesg not available — OOM check skipped."
    JSON_RESULTS+=("{\"check\":\"oom\",\"status\":\"skip\",\"reason\":\"dmesg_unavailable\"}")
    return
  fi

  # Calculate the earliest timestamp to consider.
  # util-linux dmesg --since accepts ISO 8601 format (e.g. 2026-08-11T10:00:00).
  # GNU date --date is Linux-specific; fall back to the full ring buffer on macOS/BSD.
  local oom_events=0
  local since_ts=""
  since_ts=$(date --date="${OOM_LOOKBACK_MIN} minutes ago" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null) || since_ts=""

  if [[ -n "${since_ts}" ]] && dmesg --since "${since_ts}" &>/dev/null 2>&1; then
    oom_events=$(dmesg --since "${since_ts}" 2>/dev/null \
                  | grep -c "Out of memory\|oom_kill_process\|Killed process" || true)
  else
    # Fallback: scan the full dmesg ring buffer (macOS, older util-linux, or GNU date unavailable).
    oom_events=$(dmesg 2>/dev/null \
                  | grep -c "Out of memory\|oom_kill_process\|Killed process" || true)
    [[ $oom_events -gt 0 ]] && warn "Using full dmesg buffer (--since unavailable or timestamp conversion failed)"
  fi

  log "  OOM events detected: ${oom_events}"

  if [[ "$oom_events" -eq 0 ]]; then
    log "  OOM: OK (no OOM-kill events detected)"
    JSON_RESULTS+=("{\"check\":\"oom\",\"status\":\"ok\",\"events_detected\":0}")
  else
    fail "OOM-kill detected: ${oom_events} OOM event(s) in the last ${OOM_LOOKBACK_MIN} minutes"
    JSON_RESULTS+=("{\"check\":\"oom\",\"status\":\"fail\",\"events_detected\":${oom_events}}")
  fi
}

# ── Execute selected checks ───────────────────────────────────────────────────
[[ "$CHECK_VRAM" == "true" ]] && check_vram
[[ "$CHECK_RAM"  == "true" ]] && check_ram
[[ "$CHECK_OOM"  == "true" ]] && check_oom

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$EMIT_JSON" == "true" ]]; then
  # Emit a JSON object with overall status and per-check results.
  local_status="ok"
  [[ "$PASS" == "false" ]] && local_status="fail"

  # Join JSON_RESULTS array into a comma-separated list.
  results_json=""
  for r in "${JSON_RESULTS[@]}"; do
    results_json="${results_json},${r}"
  done
  results_json="${results_json#,}"  # strip leading comma

  echo "{\"status\":\"${local_status}\",\"checks\":[${results_json}]}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "$PASS" == "true" ]]; then
  log "All budget checks passed."
  exit 0
else
  [[ "$EMIT_JSON" == "false" ]] && {
    echo "[budget-check] Budget breach summary:" >&2
    for f in "${FINDINGS[@]}"; do
      echo "  - $f" >&2
    done
  }
  exit 1
fi
