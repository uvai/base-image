#!/usr/bin/env bash
# mmx_extras.sh — browser terminal + direct NAS output sync for the MiniMax instance.
# Run from the Vast on-start after minimax_onstart.sh.
#
# Env (Vast template):
#   TS_AUTHKEY    Tailscale auth key (ephemeral, reusable, tag:vastbox)
#   NAS_KEY_B64   base64 of a dedicated private SSH key authorized on the NAS
#   NAS_DEST      e.g. alchera@100.x.y.z:/volume1/homes/alchera/vast
#
# Behaviour: joins the tailnet (userspace networking — no /dev/net/tun needed),
# picks the next nebN folder on the NAS, then rsyncs /workspace/ComfyUI/output
# there every 60s for the life of the instance. ttyd serves a browser terminal
# on 127.0.0.1:7681 (reached via vgo's tunnel).

set -u
LOG=/workspace/extras_setup.log
exec >> "$LOG" 2>&1
echo "=== mmx_extras $(date -u +%FT%TZ) ==="

# ---------- ttyd (browser terminal) ------------------------------------------
if ! command -v ttyd >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/ttyd \
        https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 \
        && chmod +x /usr/local/bin/ttyd \
        || echo "[extras] WARN: ttyd download failed"
fi
if command -v ttyd >/dev/null 2>&1 && ! pgrep -x ttyd >/dev/null; then
    nohup ttyd -p 7681 -i 127.0.0.1 -W tmux new -A -s vgo >/tmp/ttyd.log 2>&1 &
    echo "[extras] ttyd on 127.0.0.1:7681"
fi

# ---------- NAS sync via Tailscale --------------------------------------------
if [ -z "${TS_AUTHKEY:-}" ] || [ -z "${NAS_KEY_B64:-}" ] || [ -z "${NAS_DEST:-}" ]; then
    echo "[extras] TS_AUTHKEY/NAS_KEY_B64/NAS_DEST not all set — skipping NAS sync"
    exit 0
fi

# deps
command -v rsync >/dev/null 2>&1 || apt-get install -y -qq rsync
command -v nc >/dev/null 2>&1 || apt-get install -y -qq netcat-openbsd

# tailscale
if ! command -v tailscale >/dev/null 2>&1; then
    echo "[extras] installing tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 \
        || { echo "[extras] ERROR: tailscale install failed"; exit 0; }
fi
if ! pgrep -x tailscaled >/dev/null; then
    nohup tailscaled --state=/root/ts.state \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:1055 >/tmp/tailscaled.log 2>&1 &
    sleep 3
fi
tailscale up --authkey="$TS_AUTHKEY" --hostname="mmx-vast-$(hostname | tr -c 'a-zA-Z0-9\n' -)" \
    || { echo "[extras] ERROR: tailscale up failed"; exit 0; }
echo "[extras] tailnet joined as $(tailscale ip -4 2>/dev/null | head -1)"

# NAS ssh key
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$NAS_KEY_B64" | base64 -d > /root/.ssh/mmx_nas_key
chmod 600 /root/.ssh/mmx_nas_key

NAS_USERHOST="${NAS_DEST%%:*}"
NAS_BASE="${NAS_DEST#*:}"
# userspace networking: reach tailnet IPs via the local SOCKS5 proxy
NAS_SSH="ssh -i /root/.ssh/mmx_nas_key -o ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p' -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

# session folder: next nebN on the NAS, sticky for this instance
NEB_FILE=/root/.neb_session
if [ -f "$NEB_FILE" ]; then
    NEB=$(cat "$NEB_FILE")
else
    LAST=$(eval "$NAS_SSH" "$NAS_USERHOST" "\"ls -1d $NAS_BASE/neb* 2>/dev/null\"" \
           | grep -oE 'neb[0-9]+$' | grep -oE '[0-9]+' | sort -n | tail -1)
    NEB="neb$(( ${LAST:-0} + 1 ))"
    eval "$NAS_SSH" "$NAS_USERHOST" "\"mkdir -p $NAS_BASE/$NEB\"" \
        || { echo "[extras] ERROR: cannot create $NAS_BASE/$NEB on NAS"; exit 0; }
    echo "$NEB" > "$NEB_FILE"
fi
echo "[extras] session folder: $NAS_BASE/$NEB"

# sync loop (background, lives as long as the instance)
mkdir -p /workspace/ComfyUI/output
nohup bash -c '
NAS_SSH="'"$NAS_SSH"'"
while true; do
    rsync -a --partial -e "$NAS_SSH" \
        /workspace/ComfyUI/output/ "'"$NAS_USERHOST"':'"$NAS_BASE"'/'"$NEB"'/" \
        >> /workspace/nas_sync.log 2>&1 \
        || echo "$(date "+%F %T") sync pass failed" >> /workspace/nas_sync.log
    sleep 60
done' >/dev/null 2>&1 &
echo "[extras] NAS sync loop started (every 60s) -> $NAS_BASE/$NEB"
