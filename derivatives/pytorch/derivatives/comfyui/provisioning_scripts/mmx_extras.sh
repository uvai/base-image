#!/usr/bin/env bash
# mmx_extras.sh — browser terminal + direct NAS output sync for the MiniMax instance.
# v3: the NAS setup runs as a fully detached worker (setsid+nohup) so it
# survives Vast reaping the on-start process group mid-boot — the failure mode
# observed 2026-08-06 where setup died silently between steps.
#
# Env (Vast template):
#   TS_AUTHKEY    Tailscale auth key (ephemeral, reusable, tag:vastbox)
#   NAS_KEY_B64   base64 (single line) of the private key authorized on the NAS
#   NAS_DEST      e.g. alchera@100.81.253.103:/volume1/homes/alchera/vast
#
# Logs: /workspace/extras_setup.log (setup), /workspace/nas_sync.log (per-pass).

set -u
LOG=/workspace/extras_setup.log
mkdir -p /workspace
echo "=== mmx_extras $(date -u +%FT%TZ) ===" >> "$LOG"

# ---------- ttyd (quick, do inline) ------------------------------------------
{
    if ! command -v ttyd >/dev/null 2>&1; then
        curl -fsSL -o /usr/local/bin/ttyd \
            https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 \
            && chmod +x /usr/local/bin/ttyd
    fi
    if command -v ttyd >/dev/null 2>&1 && ! pgrep -x ttyd >/dev/null; then
        nohup ttyd -p 7681 -i 127.0.0.1 -W tmux new -A -s vgo >/tmp/ttyd.log 2>&1 &
        echo "[extras] ttyd on 127.0.0.1:7681"
    fi
} >> "$LOG" 2>&1

# ---------- NAS sync: hand everything to a detached worker --------------------
if [ -z "${TS_AUTHKEY:-}" ] || [ -z "${NAS_KEY_B64:-}" ] || [ -z "${NAS_DEST:-}" ]; then
    echo "[extras] TS_AUTHKEY/NAS_KEY_B64/NAS_DEST not all set — skipping NAS sync" >> "$LOG"
    exit 0
fi

WORKER=/root/nas_worker.sh
cat > "$WORKER" <<'WEOF'
#!/usr/bin/env bash
# nas_worker.sh — detached: deps, tailscale, key, session folder, sync loop.
set -u
LOG=/workspace/extras_setup.log
log() { echo "[nas-worker] $*" >> "$LOG"; }

log "started (pid $$)"

# deps
command -v rsync >/dev/null 2>&1 || apt-get install -y -qq rsync >>"$LOG" 2>&1
command -v nc    >/dev/null 2>&1 || apt-get install -y -qq netcat-openbsd >>"$LOG" 2>&1

# tailscale
if ! command -v tailscale >/dev/null 2>&1; then
    log "installing tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh >>"$LOG" 2>&1 \
        || { log "ERROR: tailscale install failed"; exit 1; }
fi
if ! pgrep -x tailscaled >/dev/null; then
    nohup tailscaled --state=/root/ts.state \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:1055 >/tmp/tailscaled.log 2>&1 &
    sleep 3
fi
tailscale up --authkey="$TS_AUTHKEY" \
    --hostname="mmx-vast-$(hostname | tr -c 'a-zA-Z0-9\n' -)" >>"$LOG" 2>&1 \
    || { log "ERROR: tailscale up failed (see /tmp/tailscaled.log)"; exit 1; }
log "tailnet joined as $(tailscale ip -4 2>/dev/null | head -1)"

# NAS key
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if ! echo "$NAS_KEY_B64" | base64 -d > /root/.ssh/mmx_nas_key 2>/dev/null \
   || ! grep -q "BEGIN OPENSSH PRIVATE KEY" /root/.ssh/mmx_nas_key; then
    log "ERROR: NAS_KEY_B64 does not decode to an OpenSSH key"; exit 1
fi
chmod 600 /root/.ssh/mmx_nas_key

NAS_USERHOST="${NAS_DEST%%:*}"
NAS_BASE="${NAS_DEST#*:}"
NAS_SSH="ssh -i /root/.ssh/mmx_nas_key -o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p' -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"

# session folder (sticky per instance)
NEB_FILE=/root/.neb_session
if [ -f "$NEB_FILE" ]; then
    NEB=$(cat "$NEB_FILE")
    log "resuming session $NEB"
else
    LAST=$(eval "$NAS_SSH" "$NAS_USERHOST" "\"ls -1d $NAS_BASE/neb* 2>/dev/null\"" \
           | grep -oE 'neb[0-9]+$' | grep -oE '[0-9]+' | sort -n | tail -1)
    NEB="neb$(( ${LAST:-0} + 1 ))"
    eval "$NAS_SSH" "$NAS_USERHOST" "\"mkdir -p $NAS_BASE/$NEB\"" \
        || { log "ERROR: cannot create $NAS_BASE/$NEB"; exit 1; }
    echo "$NEB" > "$NEB_FILE"
    log "session folder: $NAS_BASE/$NEB"
fi

# sync loop with heartbeat
mkdir -p /workspace/ComfyUI/output
log "sync loop starting -> $NAS_BASE/$NEB (every 60s)"
while true; do
    if eval rsync -a --partial -e "\"$NAS_SSH\"" \
        /workspace/ComfyUI/output/ "$NAS_USERHOST:$NAS_BASE/$NEB/" >/dev/null 2>&1; then
        echo "$(date '+%F %T') pass ok -> $NEB" >> /workspace/nas_sync.log
    else
        echo "$(date '+%F %T') pass FAILED" >> /workspace/nas_sync.log
    fi
    sleep 60
done
WEOF
chmod +x "$WORKER"

# export env for the worker, then fully detach it from this process group
export TS_AUTHKEY NAS_KEY_B64 NAS_DEST
setsid nohup "$WORKER" >/dev/null 2>&1 < /dev/null &
echo "[extras] nas_worker detached (pid $!)" >> "$LOG"
