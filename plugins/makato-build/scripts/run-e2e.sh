#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_ROOT="${MAKATO_E2E_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
CONFIG_FILE="${MAKATO_E2E_CONFIG:-$REPO_ROOT/config/config.yml}"
WORK_DIR=""
SSH_HOST=""
TRANSPORT=""
TEMP_ROOT=""
declare -a SSH_BASE=()
declare -a FORWARDS=()
declare -a ARTIFACTS=()

usage() {
  cat <<'EOF'
Usage: run-e2e.sh [--config PATH]

Run the full E2E command from the MAKATO_E2E configuration. Environment
variables named MAKATO_E2E_<FIELD> override configuration values.
EOF
}

die() {
  printf 'run-e2e: %s\n' "$1" >&2
  exit 2
}

yaml_scalar() {
  local key="$1"
  awk -v wanted="$key" '
    /^MAKATO_E2E:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]#]/ { exit }
    in_section && $0 ~ "^  " wanted ":[[:space:]]*" {
      value=$0
      sub("^  " wanted ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value=substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$CONFIG_FILE"
}

yaml_list() {
  local key="$1"
  awk -v wanted="$key" '
    /^MAKATO_E2E:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]#]/ { exit }
    in_section && $0 ~ "^  " wanted ":[[:space:]]*$" { in_list=1; next }
    in_list && /^    -[[:space:]]*/ {
      value=$0
      sub(/^    -[[:space:]]*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value=substr(value, 2, length(value) - 2)
      }
      print value
      next
    }
    in_list && $0 !~ /^    / { exit }
  ' "$CONFIG_FILE"
}

scalar_setting() {
  local env_name="$1"
  local key="$2"
  local fallback="${3:-}"
  local value

  if declare -p "$env_name" >/dev/null 2>&1; then
    printf '%s' "${!env_name}"
    return
  fi
  value="$(yaml_scalar "$key")"
  printf '%s' "${value:-$fallback}"
}

list_setting() {
  local env_name="$1"
  local key="$2"
  local -a loaded=()

  if declare -p "$env_name" >/dev/null 2>&1; then
    IFS=',' read -r -a loaded <<<"${!env_name}"
    printf '%s\n' "${loaded[@]}"
  else
    yaml_list "$key"
  fi
}

validate_relative_path() {
  local value="$1"
  [[ -n "$value" ]] || die "artifact paths must not be empty"
  [[ "$value" != /* ]] || die "artifact paths must be relative"
  [[ "$value" != ".." && "$value" != ../* && "$value" != */../* && "$value" != */.. ]] ||
    die "artifact paths must not contain '..'"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "artifact paths may contain only letters, digits, '.', '_', '/', and '-'"
}

validate_inputs() {
  local forward artifact local_port remote_port

  [[ -f "$CONFIG_FILE" ]] || die "configuration file not found"
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "repository root is not a git worktree"
  [[ "$PLACEMENT" == "local" || "$PLACEMENT" == "remote" ]] ||
    die "placement must be 'local' or 'remote'"
  [[ "$TRANSPORT" == "direct" || "$TRANSPORT" == "ssh" ]] ||
    die "transport must be 'direct' or 'ssh'"
  [[ -n "$E2E_COMMAND" && "$E2E_COMMAND" != *$'\n'* && "$E2E_COMMAND" != *$'\r'* ]] ||
    die "command must be a non-empty single line"
  [[ "$TEMP_ROOT" == /* && "$TEMP_ROOT" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "remote_temp_root must be an absolute path without shell metacharacters"
  [[ "$TEMP_ROOT" != *"/../"* && "$TEMP_ROOT" != */.. ]] ||
    die "remote_temp_root must not contain '..'"
  [[ "$ARTIFACT_DESTINATION" != *$'\n'* && "$ARTIFACT_DESTINATION" != *$'\r'* ]] ||
    die "artifact_destination contains invalid characters"

  for artifact in "${ARTIFACTS[@]}"; do
    validate_relative_path "$artifact"
  done

  if [[ "$TRANSPORT" == "ssh" ]]; then
    [[ "$SSH_HOST" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] ||
      die "host must use the user@host form"
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] ||
      ((10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535)); then
      die "port must be between 1 and 65535"
    fi
    if [[ -n "$SSH_IDENTITY" ]]; then
      [[ -r "$SSH_IDENTITY" && -f "$SSH_IDENTITY" ]] ||
        die "configured SSH identity is not a readable file"
    fi
    for forward in "${FORWARDS[@]}"; do
      [[ "$forward" =~ ^[0-9]+:(localhost|127\.0\.0\.1):[0-9]+$ ]] ||
        die "forward must use local-port:localhost:remote-port"
      local_port="${forward%%:*}"
      remote_port="${forward##*:}"
      if ((10#$local_port < 1 || 10#$local_port > 65535 ||
        10#$remote_port < 1 || 10#$remote_port > 65535)); then
        die "forward ports must be between 1 and 65535"
      fi
    done
  fi
}

build_ssh_options() {
  SSH_BASE=(
    ssh
    -o BatchMode=yes
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=accept-new
    -p "$SSH_PORT"
  )
  [[ -z "$SSH_IDENTITY" ]] || SSH_BASE+=(-i "$SSH_IDENTITY")
}

safe_work_dir() {
  [[ -n "$WORK_DIR" ]] || return 1
  [[ "$WORK_DIR" == "${TEMP_ROOT%/}"/makato-e2e-* ]]
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  safe_work_dir || return 0

  if [[ "$TRANSPORT" == "ssh" ]]; then
    "${SSH_BASE[@]}" "$SSH_HOST" "rm -rf -- '$WORK_DIR'" >/dev/null 2>&1 || true
  else
    rm -rf -- "$WORK_DIR"
  fi
  WORK_DIR=""
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
on_exit() {
  local status=$?
  trap - EXIT
  cleanup
  exit "$status"
}

create_work_dir() {
  if [[ "$TRANSPORT" == "ssh" ]]; then
    WORK_DIR="$("${SSH_BASE[@]}" "$SSH_HOST" \
      "umask 077; mktemp -d '${TEMP_ROOT%/}/makato-e2e-XXXXXXXX'")"
  else
    WORK_DIR="$(mktemp -d "${TEMP_ROOT%/}/makato-e2e-XXXXXXXX")"
  fi
  safe_work_dir || die "temporary workspace did not match the configured safe prefix"
}

rsync_shell() {
  local quoted
  printf -v quoted '%q ' "${SSH_BASE[@]}"
  printf '%s' "${quoted% }"
}

filter_existing_snapshot_files() {
  local path

  while IFS= read -r -d '' path; do
    if [[ -e "$REPO_ROOT/$path" || -L "$REPO_ROOT/$path" ]]; then
      printf '%s\0' "$path"
    fi
  done
}

sync_snapshot() {
  local destination="$WORK_DIR/"
  local -a args=(rsync -a --from0 --files-from=- --relative)

  if [[ "$TRANSPORT" == "ssh" ]]; then
    args+=(-e "$(rsync_shell)")
    destination="${SSH_HOST}:${WORK_DIR}/"
  fi

  git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -z |
    filter_existing_snapshot_files |
    "${args[@]}" "$REPO_ROOT/" "$destination"
}

run_direct() {
  (
    cd "$WORK_DIR"
    exec bash -s <<<"$E2E_COMMAND"
  )
}

run_ssh() {
  local encoded remote_command forward
  local -a command_ssh=("${SSH_BASE[@]}")

  for forward in "${FORWARDS[@]}"; do
    command_ssh+=(-L "$forward")
  done

  encoded="$(printf '%s' "$E2E_COMMAND" | base64 | tr -d '\n')"
  remote_command="bash -s -- '$WORK_DIR'"
  {
    printf 'encoded_command=%q\n' "$encoded"
    cat <<'REMOTE_SCRIPT'
set -euo pipefail
work_dir="$1"
command="$(printf '%s' "$encoded_command" | base64 --decode)"
cd "$work_dir"
exec bash -lc "$command"
REMOTE_SCRIPT
  } | "${command_ssh[@]}" "$SSH_HOST" "$remote_command"
}

retrieve_artifacts() {
  local artifact source_path
  local -a args=(rsync -a --relative)

  (( ${#ARTIFACTS[@]} > 0 )) || return 0
  mkdir -p "$ARTIFACT_DESTINATION"

  if [[ "$TRANSPORT" == "ssh" ]]; then
    args+=(-e "$(rsync_shell)")
  fi

  for artifact in "${ARTIFACTS[@]}"; do
    if [[ "$TRANSPORT" == "ssh" ]]; then
      "${SSH_BASE[@]}" "$SSH_HOST" "test -e '$WORK_DIR/$artifact'" >/dev/null 2>&1 ||
        continue
      source_path="${SSH_HOST}:${WORK_DIR}/./${artifact}"
    else
      [[ -e "$WORK_DIR/$artifact" ]] || continue
      source_path="$WORK_DIR/./$artifact"
    fi
    "${args[@]}" "$source_path" "$ARTIFACT_DESTINATION/" ||
      printf 'run-e2e: warning: could not retrieve an artifact\n' >&2
  done
}

while (($# > 0)); do
  case "$1" in
    --config)
      (($# >= 2)) || die "--config requires a path"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument"
      ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || die "configuration file not found"
PLACEMENT="$(scalar_setting MAKATO_E2E_PLACEMENT placement)"
TRANSPORT="$(scalar_setting MAKATO_E2E_TRANSPORT transport)"
SSH_HOST="$(scalar_setting MAKATO_E2E_HOST host)"
SSH_PORT="$(scalar_setting MAKATO_E2E_PORT port)"
SSH_IDENTITY="$(scalar_setting MAKATO_E2E_IDENTITY identity)"
E2E_COMMAND="$(scalar_setting MAKATO_E2E_COMMAND command)"
TEMP_ROOT="$(scalar_setting MAKATO_E2E_REMOTE_TEMP_ROOT remote_temp_root /tmp)"
ARTIFACT_DESTINATION="$(scalar_setting MAKATO_E2E_ARTIFACT_DESTINATION artifact_destination .makato/e2e-artifacts)"
while IFS= read -r value; do
  [[ -n "$value" ]] && FORWARDS+=("$value")
done < <(list_setting MAKATO_E2E_FORWARD forward)
while IFS= read -r value; do
  [[ -n "$value" ]] && ARTIFACTS+=("$value")
done < <(list_setting MAKATO_E2E_ARTIFACTS artifacts)

if [[ "$ARTIFACT_DESTINATION" != /* ]]; then
  ARTIFACT_DESTINATION="$REPO_ROOT/$ARTIFACT_DESTINATION"
fi

validate_inputs
[[ "$TRANSPORT" != "ssh" ]] || build_ssh_options
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

create_work_dir
printf 'run-e2e: preparing isolated %s workspace\n' "$PLACEMENT"
sync_snapshot

set +e
if [[ "$TRANSPORT" == "ssh" ]]; then
  run_ssh
else
  run_direct
fi
COMMAND_STATUS=$?
set -e

set +e
retrieve_artifacts
exit "$COMMAND_STATUS"
