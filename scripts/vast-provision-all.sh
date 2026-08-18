#!/usr/bin/env bash
# =============================================================================
# vast-provision-all.sh — one-command bring-up of the FULL makato + sagibeast
# stack on a fresh or migrated vast.ai GPU box. You give it the box's public IP;
# it does everything else and prints how to connect at the end.
#
# What it does (each step is idempotent — safe to re-run):
#   0. Auto-discovers the SSH port from the vast.ai API by matching the IP
#      (falls back to --port / 22 if `vastai` is not installed).
#   1. Repairs the vast-injected /etc/environment that otherwise breaks apt.
#   2. rsyncs the two (private) repos onto the box (from local checkouts).
#   3. makato-oss vLLM endpoint (only when HF_TOKEN is set — the model is gated):
#      installs the CUDA-13 driver (reboots once), builds the venv, downloads the
#      model, installs the auto-start systemd unit. Skipped with a warning otherwise.
#   4. sagibeast compose stack + admin console + Langfuse, and installs the
#      `sagibeast-stack.service` boot orchestrator so it all returns after a reboot.
#   5. (optional) a Cloudflare *named* tunnel on your domain so the console,
#      Langfuse and the LLM get stable public HTTPS URLs — no vast port changes.
#   6. Prints the connection cheat-sheet.
#
# Usage:
#   ./vast-provision-all.sh <IP> [--port N] [--key PATH] [--domain macato.io]
#                                [--no-tunnel] [--no-llm]
# Environment:
#   HF_TOKEN          approved token for the gated model — REQUIRED to bring up the LLM.
#   CF_TUNNEL_TOKEN   Cloudflare tunnel token for fully non-interactive tunnel setup
#                     (otherwise a one-time browser login URL is printed).
#   MAKATO_SRC        local makato-oss checkout to rsync   (default: ~/GITHUB/makato-oss)
#   SAGIBEAST_SRC     local sagibeast checkout to rsync    (default: ~/GITHUB/sagibeast)
# =============================================================================
set -euo pipefail

# ── args ─────────────────────────────────────────────────────────────────────
HOST="" ; PORT="" ; KEY="${HOME}/.ssh/vast_makato" ; DOMAIN="macato.io"
DO_TUNNEL=1 ; DO_LLM=1
MAKATO_SRC="${MAKATO_SRC:-$HOME/GITHUB/makato-oss}"
SAGIBEAST_SRC="${SAGIBEAST_SRC:-$HOME/GITHUB/sagibeast}"
TUNNEL_NAME="vast-makato"

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="$2"; shift 2;;
    --key)       KEY="$2"; shift 2;;
    --domain)    DOMAIN="$2"; shift 2;;
    --no-tunnel) DO_TUNNEL=0; shift;;
    --no-llm)    DO_LLM=0; shift;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0;;
    -*)          echo "unknown option: $1" >&2; exit 2;;
    *)           HOST="$1"; shift;;
  esac
done
[ -n "$HOST" ] || { echo "usage: $0 <IP> [--port N] [--key PATH] [--domain D] [--no-tunnel] [--no-llm]" >&2; exit 2; }

log()  { echo -e "\033[1;36m[provision $(date -u +%H:%M:%S)]\033[0m $*"; }
warn() { echo -e "\033[1;33m[provision WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[provision FATAL]\033[0m $*" >&2; exit 1; }

# ── Step 0: resolve SSH port via the vast.ai API when not given ───────────────
if [ -z "$PORT" ]; then
  if command -v vastai >/dev/null 2>&1; then
    log "looking up SSH port for $HOST via vastai…"
    PORT="$(vastai show instances --raw 2>/dev/null | python3 -c '
import sys,json
host=sys.argv[1]
try: data=json.load(sys.stdin)
except Exception: data=[]
for inst in data:
    if str(inst.get("public_ipaddr","")).strip()==host:
        for m in (inst.get("ports") or {}).get("22/tcp") or []:
            if m.get("HostPort"): print(m["HostPort"]); sys.exit(0)
' "$HOST" 2>/dev/null || true)"
  fi
  [ -n "$PORT" ] || { warn "could not auto-resolve SSH port; defaulting to 22 (override with --port)"; PORT=22; }
fi
[ -f "$KEY" ] || die "SSH key not found: $KEY (override with --key)"

SSH_OPTS=(-p "$PORT" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
TARGET="root@$HOST"
log "target: ssh -p $PORT -i $KEY $TARGET   domain=$DOMAIN  tunnel=$DO_TUNNEL  llm=$DO_LLM"

# run a script (fed on stdin) on the box; extra args become $1,$2,… remotely
remote()  { ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s" -- "$@"; }
# capture a single-line remote value
rget()    { ssh "${SSH_OPTS[@]}" "$TARGET" "$1" 2>/dev/null; }

wait_for_ssh() {
  log "waiting for the box to come back…"
  local i
  for i in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$TARGET" true 2>/dev/null; then log "box is back (after ~$((i*15))s)."; return 0; fi
    sleep 15
  done
  die "box did not return within ~15 min"
}

ssh "${SSH_OPTS[@]}" "$TARGET" 'echo ok >/dev/null' 2>/dev/null || die "cannot SSH to $TARGET:$PORT with key $KEY"

# ── Step 1: repair /etc/environment (vast re-injects a broken one on every boot) ─
fix_env() {
  log "repairing /etc/environment (quote space-values + de-dupe)…"
  remote <<'RS'
set -e
[ -f /etc/environment ] || exit 0
cp -a /etc/environment "/etc/environment.bak.$(date +%s)" 2>/dev/null || true
python3 - <<'PY'
seen=set(); out=[]
try: lines=open("/etc/environment").read().splitlines()
except Exception: lines=[]
for ln in lines:
    if "=" not in ln: continue
    k,v=ln.split("=",1)
    if k in seen: continue
    seen.add(k)
    if len(v)>=2 and v[0]=='"' and v[-1]=='"': v=v[1:-1]
    out.append('%s="%s"'%(k,v) if " " in v else "%s=%s"%(k,v))
open("/etc/environment","w").write("\n".join(out)+"\n")
PY
sh -c '. /etc/environment && echo "  /etc/environment OK"'
RS
}
fix_env

# ── Step 2: get the repos onto the box (rsync from local; else reuse remote) ───
sync_repo() {
  local src="$1" dst="$2" name="$3"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    log "rsyncing $name  $src  →  $TARGET:$dst"
    rsync -az -e "ssh ${SSH_OPTS[*]}" \
      --exclude '.git' --exclude 'node_modules' --exclude '.claude/worktrees' \
      --exclude '__pycache__' --exclude '*.pyc' --exclude '.venv' --exclude 'dist' --exclude 'build' \
      "$src/" "$TARGET:$dst/"
  elif [ "$(rget "test -e $dst && echo y || echo n")" = "y" ]; then
    warn "$name local checkout not found at $src — reusing existing $dst on the box"
  else
    die "$name not found locally ($src) and not on the box ($dst). Set ${name^^}_SRC to a local checkout."
  fi
}
sync_repo "$MAKATO_SRC"   /root/makato-oss  MAKATO
sync_repo "$SAGIBEAST_SRC" /opt/sagibeast   SAGIBEAST

# ── Step 3: makato-oss vLLM endpoint (gated model → needs HF_TOKEN) ───────────
if [ "$DO_LLM" = 1 ] && [ -n "${HF_TOKEN:-}" ]; then
  log "ensuring uv on the box…"
  remote <<'RS'
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
ls -1 "$HOME/.local/bin/uv" >/dev/null 2>&1 && echo "  uv: $($HOME/.local/bin/uv --version)"
RS
  DRV="$(rget 'nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1')"
  if [ "${DRV:-0}" -lt 580 ] 2>/dev/null; then
    log "driver is ${DRV:-none} (<580) — bootstrap will install CUDA-13 driver and reboot…"
    # Pass 1: installs driver + build-essential, reboots, exits (SSH drops → ignore rc).
    remote "$HF_TOKEN" <<'RS' || true
export PATH="$HOME/.local/bin:$PATH"
HF_TOKEN="$1" sudo -E MAKATO_HOME=/root/makato-oss bash /root/makato-oss/infra/bootstrap-vllm.sh || true
RS
    wait_for_ssh
    fix_env
  fi
  log "bootstrap Pass 2: venv + model (~27 GB) + systemd (runs under tmux, tailing log)…"
  remote "$HF_TOKEN" <<'RS'
export PATH="$HOME/.local/bin:$PATH"
umask 077; printf '%s' "$1" > /root/.hf_token
tmux kill-session -t mkboot 2>/dev/null || true
tmux new-session -d -s mkboot 'export PATH=$HOME/.local/bin:$PATH; HF_TOKEN=$(cat /root/.hf_token) sudo -E MAKATO_HOME=/root/makato-oss bash /root/makato-oss/infra/bootstrap-vllm.sh > /var/log/makato-bootstrap.log 2>&1; echo EXIT=$? >> /var/log/makato-bootstrap.log'
echo "  bootstrap started in tmux 'mkboot' → /var/log/makato-bootstrap.log"
RS
  # poll the bootstrap log until vLLM answers or it errors (up to ~20 min for the 27 GB pull)
  log "waiting for vLLM on :8100 (model download + kernel JIT can take 10-20 min)…"
  for _ in $(seq 1 80); do
    if [ "$(rget 'curl -sf -m3 http://localhost:8100/health >/dev/null 2>&1 && echo up')" = "up" ]; then
      log "vLLM is serving on :8100."; break
    fi
    if [ "$(rget 'grep -c "^EXIT=" /var/log/makato-bootstrap.log 2>/dev/null')" != "0" ] \
       && [ "$(rget 'curl -sf -m3 http://localhost:8100/health >/dev/null 2>&1 && echo up')" != "up" ]; then
      warn "bootstrap finished but vLLM is not up — last log lines:"; rget 'tail -8 /var/log/makato-bootstrap.log'; break
    fi
    sleep 15
  done
else
  [ "$DO_LLM" = 1 ] && warn "HF_TOKEN not set — skipping the LLM (gated model). Re-run with HF_TOKEN=hf_xxx to enable it." \
                     || log "--no-llm given — skipping the LLM."
fi

# ── Step 4: sagibeast stack + boot orchestrator ───────────────────────────────
log "installing sagibeast-stack.service (boot orchestrator) and bringing the stack up…"
remote <<'RS'
set -e
cat > /etc/systemd/system/sagibeast-stack.service <<'UNIT'
[Unit]
Description=SAGIBEAST stack ordered bring-up (idempotent)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/environment
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/sagibeast/scripts/vast-start-sagibeast.sh
TimeoutStartSec=900
[Install]
WantedBy=multi-user.target
UNIT
chmod +x /opt/sagibeast/scripts/vast-start-sagibeast.sh 2>/dev/null || true
systemctl daemon-reload
systemctl enable sagibeast-stack.service >/dev/null 2>&1 || true
# ensure docker itself auto-starts on boot
systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker 2>/dev/null || true
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
# immediate bring-up: compose directly (fast, ordered) rather than the full script's vLLM wait
cd /opt/sagibeast
docker compose -f infra/docker-compose.yml -f infra/docker-compose.dev.yml -f infra/docker-compose.vast.yml \
  up -d --wait --wait-timeout 300 2>&1 | tail -3 || \
docker compose -f infra/docker-compose.yml -f infra/docker-compose.dev.yml -f infra/docker-compose.vast.yml up -d 2>&1 | tail -3
echo "  running containers: $(docker ps -q | wc -l)"
RS

# ── Step 5: Cloudflare named tunnel (optional) ────────────────────────────────
if [ "$DO_TUNNEL" = 1 ]; then
  log "setting up Cloudflare named tunnel '$TUNNEL_NAME' on $DOMAIN…"
  remote <<'RS'
command -v cloudflared >/dev/null 2>&1 || {
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  curl -fsSL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  chmod +x /usr/local/bin/cloudflared
}
echo "  cloudflared: $(cloudflared --version 2>&1 | head -1)"
RS
  # ensure we are authorized to the zone: reuse cert.pem, else token, else interactive login
  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    log "using CF_TUNNEL_TOKEN (dashboard-managed tunnel) — installing as a service…"
    remote "$CF_TUNNEL_TOKEN" <<'RS'
cloudflared service install "$1" 2>&1 | tail -2 || true
systemctl enable --now cloudflared 2>/dev/null || true
RS
    warn "with a dashboard token, configure the public hostnames (sagibeast/langfuse/llm.$DOMAIN) in the Zero Trust dashboard."
  else
    if [ "$(rget 'test -f /root/.cloudflared/cert.pem && echo y || echo n')" != "y" ]; then
      log "no Cloudflare cert on the box — starting a one-time browser login…"
      URL="$(remote <<'RS'
tmux kill-session -t cflogin 2>/dev/null || true
tmux new-session -d -s cflogin "cloudflared tunnel login > /var/log/cf-login.log 2>&1"
sleep 6; grep -Eo 'https://[^ ]+' /var/log/cf-login.log | head -1
RS
)"
      echo ""
      echo "  ┌─────────────────────────────────────────────────────────────────────────┐"
      echo "  │  OPEN THIS URL and authorize the zone '$DOMAIN':"
      echo "  │  $URL"
      echo "  └─────────────────────────────────────────────────────────────────────────┘"
      log "waiting for authorization (cert.pem)…"
      for _ in $(seq 1 40); do
        [ "$(rget 'test -f /root/.cloudflared/cert.pem && echo y || echo n')" = "y" ] && { log "authorized."; break; }
        sleep 15
      done
      [ "$(rget 'test -f /root/.cloudflared/cert.pem && echo y || echo n')" = "y" ] || die "not authorized in time — re-run once you have clicked Authorize."
    fi
    # create tunnel (idempotent) + config + DNS + service
    remote "$DOMAIN" "$TUNNEL_NAME" <<'RS'
set -e
DOMAIN="$1"; NAME="$2"
UUID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$NAME" '$2==n{print $1}' | head -1)"
if [ -z "$UUID" ]; then
  cloudflared tunnel create "$NAME" >/tmp/cf-create.log 2>&1 || true
  UUID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$NAME" '$2==n{print $1}' | head -1)"
fi
[ -n "$UUID" ] || { echo "FATAL: could not create/find tunnel $NAME"; exit 1; }
CRED="/root/.cloudflared/${UUID}.json"
cat > /root/.cloudflared/config.yml <<CFG
tunnel: ${UUID}
credentials-file: ${CRED}
ingress:
  - hostname: sagibeast.${DOMAIN}
    service: http://localhost:8000
  - hostname: langfuse.${DOMAIN}
    service: http://localhost:3000
  - hostname: llm.${DOMAIN}
    service: http://localhost:8100
  - service: http_status:404
CFG
cloudflared tunnel ingress validate >/dev/null 2>&1 && echo "  ingress OK"
for h in sagibeast langfuse llm; do
  cloudflared tunnel route dns "$NAME" "${h}.${DOMAIN}" >/dev/null 2>&1 || true
done
cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=cloudflared tunnel ${NAME}
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config /root/.cloudflared/config.yml --no-autoupdate run ${NAME}
Restart=on-failure
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now cloudflared >/dev/null 2>&1 || systemctl restart cloudflared
sleep 4
echo "  cloudflared: $(systemctl is-active cloudflared)  tunnel UUID: $UUID"
RS
  fi
fi

# ── Step 6: connection cheat-sheet ────────────────────────────────────────────
llm_state="skipped (set HF_TOKEN to enable)"
[ "$(rget 'curl -sf -m3 http://localhost:8100/health >/dev/null 2>&1 && echo up')" = "up" ] && llm_state="serving on :8100"
con_state="$(rget 'curl -s -o /dev/null -m5 -w "%{http_code}" http://localhost:8000/ 2>/dev/null')"
lf_state="$(rget  'curl -s -o /dev/null -m5 -w "%{http_code}" http://localhost:3000/ 2>/dev/null')"

cat <<EOF

============================================================================
  ✅  PROVISIONING DONE — $HOST  (instance reachable on SSH port $PORT)
============================================================================

  SSH:
      ssh -p $PORT -i $KEY root@$HOST

  Local service health on the box:
      console(:8000)=${con_state:-?}   langfuse(:3000)=${lf_state:-?}   vLLM(:8100)=${llm_state}

EOF

if [ "$DO_TUNNEL" = 1 ] && [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
cat <<EOF
  Public HTTPS URLs (stable, survive reboot — Cloudflare named tunnel on $DOMAIN):
      Console   https://sagibeast.$DOMAIN
      Langfuse  https://langfuse.$DOMAIN
      LLM API   https://llm.$DOMAIN            (502 until vLLM is up on :8100)

EOF
fi

cat <<EOF
  No public URLs? Reach services over an SSH tunnel instead:
      ssh -p $PORT -i $KEY -L 8000:localhost:8000 -L 3000:localhost:3000 -L 8100:localhost:8100 root@$HOST
      → console http://localhost:8000/   langfuse http://localhost:3000/   llm http://localhost:8100/v1/models

  Everything auto-starts on reboot: docker + sagibeast-stack.service + cloudflared.service
  + (if enabled) vllm.service. Re-run this script any time — it is idempotent.
============================================================================
EOF
