#!/usr/bin/env bash
# verify-production-isolation.sh — snapshot and verify production makato install integrity.
#
# Part of the harness-independence MVP proof (issue #7). Guards against accidental
# mutation of shared paths (Claude Code settings, HALT file, production makato root)
# during a makato-oss autonomous run.
#
# Usage:
#   verify-production-isolation.sh --capture   # baseline: snapshot checksums to disk
#   verify-production-isolation.sh --check     # verify: diff current state against snapshot
#
# Shared paths guarded:
#   ~/.claude/settings.json
#   ~/.claude/settings.local.json
#   ~/.claude/HALT
#   $MAKATO_PRODUCTION_ROOT (when set — the upstream production makato repo root)
#
# Baseline file:
#   ~/.claude/makato-oss-isolation-baseline.sha256
#   Override with MAKATO_ISOLATION_BASELINE env var (used by tests).
#
# Exit codes:
#   0   success (--capture: snapshot written; --check: no drift detected)
#   1   usage error or drift detected (--check only)

set -euo pipefail

BASELINE_FILE="${MAKATO_ISOLATION_BASELINE:-$HOME/.claude/makato-oss-isolation-baseline.sha256}"

# ---------------------------------------------------------------------------
# _guarded_paths — list of paths to include in the snapshot.
# Each entry is emitted on its own line, skipping entries that do not exist.
# ---------------------------------------------------------------------------
_guarded_paths() {
  local paths=(
    "$HOME/.claude/settings.json"
    "$HOME/.claude/settings.local.json"
    "$HOME/.claude/HALT"
  )
  if [[ -n "${MAKATO_PRODUCTION_ROOT:-}" ]]; then
    paths+=("$MAKATO_PRODUCTION_ROOT")
  fi
  for p in "${paths[@]}"; do
    echo "$p"
  done
}

# ---------------------------------------------------------------------------
# _checksum_path <path> — emit a stable "checksum  path" line for <path>.
# Uses sha256sum when available, falls back to shasum -a 256 (macOS).
# Directories: checksum the sorted list of tracked paths (git ls-files) so
# adding/removing/modifying any file changes the checksum.
# Missing files are represented as "ABSENT  <path>".
# ---------------------------------------------------------------------------
_checksum_path() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    echo "ABSENT  $p"
    return
  fi
  if [[ -d "$p" ]]; then
    # Directory: hash the sorted file list + individual file hashes for mutation detection.
    local dir_hash
    dir_hash="$(
      git -C "$p" ls-files --cached --others --exclude-standard 2>/dev/null \
        | sort \
        | xargs -I{} sh -c 'test -f "$1" && sha256sum "$1" 2>/dev/null || true' _ {} \
        | sha256sum 2>/dev/null || \
      find "$p" -type f | sort \
        | xargs sha256sum 2>/dev/null \
        | sha256sum
    )" 2>/dev/null
    echo "${dir_hash%% *}  $p"
  else
    local file_hash
    if command -v sha256sum >/dev/null 2>&1; then
      file_hash="$(sha256sum "$p")"
    else
      file_hash="$(shasum -a 256 "$p")"
    fi
    echo "${file_hash%% *}  $p"
  fi
}

# ---------------------------------------------------------------------------
# _capture — snapshot all guarded paths to the baseline file.
# ---------------------------------------------------------------------------
_capture() {
  mkdir -p "$(dirname "$BASELINE_FILE")"
  {
    echo "# makato-oss isolation baseline — captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r path; do
      _checksum_path "$path"
    done < <(_guarded_paths)
  } > "$BASELINE_FILE"
  echo "verify-production-isolation: baseline captured → $BASELINE_FILE"
  echo "verify-production-isolation: paths guarded:"
  while IFS= read -r path; do
    echo "  $path"
  done < <(_guarded_paths)
}

# ---------------------------------------------------------------------------
# _check — verify current state against the baseline file.
# ---------------------------------------------------------------------------
_check() {
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "verify-production-isolation: ERROR — no baseline file found at $BASELINE_FILE" >&2
    echo "verify-production-isolation: run with --capture first" >&2
    exit 1
  fi

  local drift=0
  echo "verify-production-isolation: checking against $BASELINE_FILE"

  while IFS= read -r path; do
    current="$(_checksum_path "$path")"
    # Find the matching baseline line (grep by path suffix for portability).
    baseline="$(grep -F "  $path" "$BASELINE_FILE" 2>/dev/null | head -1 || true)"

    if [[ -z "$baseline" ]]; then
      echo "  DRIFT  $path — not in baseline (new path)" >&2
      drift=$((drift + 1))
    elif [[ "$current" != "$baseline" ]]; then
      echo "  DRIFT  $path — checksum changed" >&2
      echo "    baseline: ${baseline%% *}" >&2
      echo "    current:  ${current%% *}" >&2
      drift=$((drift + 1))
    else
      echo "  ok     $path"
    fi
  done < <(_guarded_paths)

  if [[ $drift -gt 0 ]]; then
    echo "verify-production-isolation: FAIL — $drift path(s) drifted from baseline" >&2
    exit 1
  fi
  echo "verify-production-isolation: PASS — all guarded paths match baseline"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
  --capture) _capture ;;
  --check)   _check   ;;
  *)
    echo "Usage: $(basename "$0") --capture | --check" >&2
    echo "  --capture  snapshot current state as baseline" >&2
    echo "  --check    verify current state matches baseline" >&2
    exit 1
    ;;
esac
