#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXECUTOR="$SCRIPT_DIR/../run-e2e.sh"
SANDBOX="$SCRIPT_DIR/.run-e2e-smoke.$$"
FAKE_BIN="$SANDBOX/bin"
FIXTURE="$SANDBOX/repo"
REMOTE_ROOT="$SANDBOX/remote"
ARTIFACT_ROOT="$SANDBOX/retrieved"
SSH_LOG="$SANDBOX/ssh.log"
RSYNC_LOG="$SANDBOX/rsync.log"
FAIL=0

pass() { printf '  ok  %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$FIXTURE" "$REMOTE_ROOT" "$ARTIFACT_ROOT"

cat >"$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >>"$FAKE_SSH_LOG"
printf ' [%s]' "$@" >>"$FAKE_SSH_LOG"
printf '\n' >>"$FAKE_SSH_LOG"

while (($# > 0)); do
  case "$1" in
    -o | -p | -i | -L)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      shift
      break
      ;;
  esac
done

(($# > 0)) || exit 0
bash -c "$1"
FAKE_SSH

cat >"$FAKE_BIN/rsync" <<'FAKE_RSYNC'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >>"$FAKE_RSYNC_LOG"
printf ' [%s]' "$@" >>"$FAKE_RSYNC_LOG"
printf '\n' >>"$FAKE_RSYNC_LOG"

files_from_stdin=false
declare -a positional=()
while (($# > 0)); do
  case "$1" in
    -e | --rsh)
      shift 2
      ;;
    --files-from=-)
      files_from_stdin=true
      shift
      ;;
    -*)
      shift
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

((${#positional[@]} >= 2)) || exit 2
source_path="${positional[${#positional[@]} - 2]}"
destination="${positional[${#positional[@]} - 1]}"
[[ "$destination" != *:* ]] || destination="${destination#*:}"
mkdir -p "$destination"

if "$files_from_stdin"; then
  while IFS= read -r -d '' relative; do
    mkdir -p "$destination/$(dirname "$relative")"
    cp -a "${source_path}${relative}" "$destination/$relative"
  done
  exit 0
fi

[[ "$source_path" != *:* ]] || source_path="${source_path#*:}"
relative="${source_path#*"/./"}"
[[ "$relative" != "$source_path" ]] || relative="$(basename "$source_path")"
[[ -e "$source_path" ]] || exit 23
mkdir -p "$destination/$(dirname "$relative")"
cp -a "$source_path" "$destination/$relative"
FAKE_RSYNC

chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/rsync"
export PATH="$FAKE_BIN:$PATH"
export FAKE_SSH_LOG="$SSH_LOG"
export FAKE_RSYNC_LOG="$RSYNC_LOG"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email smoke@example.invalid
git -C "$FIXTURE" config user.name "Smoke Test"
printf 'tracked\n' >"$FIXTURE/tracked.txt"
printf 'deleted\n' >"$FIXTURE/deleted.txt"
printf 'ignored.txt\n' >"$FIXTURE/.gitignore"
git -C "$FIXTURE" add tracked.txt deleted.txt .gitignore
git -C "$FIXTURE" commit -qm "fixture"
rm "$FIXTURE/deleted.txt"
printf 'untracked\n' >"$FIXTURE/untracked.txt"
printf 'must-not-sync\n' >"$FIXTURE/ignored.txt"
printf 'fake identity\n' >"$SANDBOX/id"
chmod 600 "$SANDBOX/id"

write_config() {
  local transport="$1"
  local command="$2"
  local forward="${3:-8080:localhost:8080}"
  cat >"$SANDBOX/config.yml" <<EOF
MAKATO_E2E:
  placement: "remote"
  transport: "$transport"
  host: "root@76.71.203.193"
  port: 44220
  identity: "$SANDBOX/id"
  forward:
    - "$forward"
  command: '$command'
  remote_temp_root: "$REMOTE_ROOT"
  artifacts:
    - "results"
  artifact_destination: "$ARTIFACT_ROOT"
EOF
}

run_executor() {
  MAKATO_E2E_REPO_ROOT="$FIXTURE" bash "$EXECUTOR" --config "$SANDBOX/config.yml" \
    >"$SANDBOX/output.log" 2>&1
}

assert_clean() {
  if find "$REMOTE_ROOT" -mindepth 1 -maxdepth 1 -name 'makato-e2e-*' | grep -q .; then
    return 1
  fi
}

echo "T1: direct transport syncs tracked and unignored files"
rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"
write_config direct \
  'test -f tracked.txt && test -f untracked.txt && test ! -e ignored.txt && mkdir -p results && printf direct > results/result.txt'
if run_executor &&
  [[ "$(cat "$ARTIFACT_ROOT/results/result.txt" 2>/dev/null)" == "direct" ]] &&
  assert_clean; then
  pass "direct snapshot, artifact retrieval, and cleanup"
else
  fail "direct execution did not preserve snapshot/artifact/cleanup behavior"
fi

echo "T2: direct transport preserves command failure status"
rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"
write_config direct 'mkdir -p results; printf failed > results/result.txt; exit 37'
set +e
run_executor
status=$?
set -e
if [[ "$status" == "37" ]] &&
  [[ "$(cat "$ARTIFACT_ROOT/results/result.txt" 2>/dev/null)" == "failed" ]] &&
  assert_clean; then
  pass "failure status, artifact retrieval, and cleanup"
else
  fail "expected exit 37 with artifacts and cleanup, got $status"
fi

echo "T3: SSH transport uses hardened options and configured forwarding"
rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"
: >"$SSH_LOG"
: >"$RSYNC_LOG"
write_config ssh \
  'test -f tracked.txt && test -f untracked.txt && test ! -e ignored.txt && mkdir -p results && printf ssh > results/result.txt'
if run_executor &&
  [[ "$(cat "$ARTIFACT_ROOT/results/result.txt" 2>/dev/null)" == "ssh" ]] &&
  grep -qF '[StrictHostKeyChecking=accept-new]' "$SSH_LOG" &&
  grep -qF '[ExitOnForwardFailure=yes]' "$SSH_LOG" &&
  grep -qF '[-p] [44220]' "$SSH_LOG" &&
  grep -qF "[-i] [$SANDBOX/id]" "$SSH_LOG" &&
  grep -qF '[-L] [8080:localhost:8080]' "$SSH_LOG" &&
  grep -qF '[--from0]' "$RSYNC_LOG" &&
  assert_clean; then
  pass "SSH options, snapshot, forwarding, artifacts, and cleanup"
else
  fail "SSH transport contract was not satisfied"
fi

echo "T4: SSH transport preserves a remote failure status"
rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"
write_config ssh 'mkdir -p results; printf remote-failed > results/result.txt; exit 23'
set +e
run_executor
status=$?
set -e
if [[ "$status" == "23" ]] &&
  [[ "$(cat "$ARTIFACT_ROOT/results/result.txt" 2>/dev/null)" == "remote-failed" ]] &&
  assert_clean; then
  pass "remote failure status, artifact retrieval, and cleanup"
else
  fail "expected remote exit 23 with artifacts and cleanup, got $status"
fi

echo "T5: invalid forwarding is rejected before network tools run"
: >"$SSH_LOG"
write_config ssh 'exit 0' '8080:example.com:8080'
set +e
run_executor
status=$?
set -e
if [[ "$status" == "2" ]] && [[ ! -s "$SSH_LOG" ]] &&
  grep -qF 'forward must use local-port:localhost:remote-port' "$SANDBOX/output.log"; then
  pass "unsafe forwarding rejected before SSH"
else
  fail "invalid forwarding was not rejected safely"
fi

echo "T6: configured commands are not exposed in SSH arguments"
rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"
: >"$SSH_LOG"
write_config ssh 'mkdir -p results; printf secret-marker > results/result.txt'
if run_executor &&
  [[ "$(cat "$ARTIFACT_ROOT/results/result.txt" 2>/dev/null)" == "secret-marker" ]] &&
  ! grep -qF 'secret-marker' "$SSH_LOG"; then
  pass "command payload remained off the SSH command line"
else
  fail "configured command leaked into SSH arguments"
fi

echo
if ((FAIL == 0)); then
  echo "All run-e2e smoke tests passed."
  exit 0
fi

echo "$FAIL run-e2e smoke test(s) failed."
exit 1
