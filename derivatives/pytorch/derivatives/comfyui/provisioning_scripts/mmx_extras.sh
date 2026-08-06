#!/usr/bin/env bash
# mmx_extras.sh — Syncthing + browser terminal (ttyd) for the MiniMax instance.
# Run from the Vast on-start after minimax_onstart.sh. Everything binds to
# 127.0.0.1 only — reached via SSH tunnel (vgo handles the forwards).
#
# Env (set in the Vast template):
#   SYNC_PEER_ID       your Mac/NAS Syncthing device ID (required to sync)
#   SYNCTHING_ID_URL   optional secret URL to a tgz of cert.pem+key.pem giving
#                      every instance the SAME device identity, so your Mac
#                      trusts it once and future rentals sync automatically.
#                      Without it, each new instance needs a one-click accept
#                      on your Mac.
#
# Sync layout: /workspace/ComfyUI/output shared send-only as folder id "mmx-out".

set -u
ST_HOME=/root/st
LOG=/workspace/extras_setup.log
exec >> "$LOG" 2>&1
echo "=== mmx_extras $(date -u +%FT%TZ) ==="

# ---------- ttyd (browser terminal) ------------------------------------------
if ! command -v ttyd >/dev/null 2>&1; then
    echo "[extras] installing ttyd"
    curl -fsSL -o /usr/local/bin/ttyd \
        https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 \
        && chmod +x /usr/local/bin/ttyd \
        || echo "[extras] WARN: ttyd download failed"
fi
if command -v ttyd >/dev/null 2>&1 && ! pgrep -x ttyd >/dev/null; then
    nohup ttyd -p 7681 -i 127.0.0.1 -W tmux new -A -s vgo >/tmp/ttyd.log 2>&1 &
    echo "[extras] ttyd on 127.0.0.1:7681 (tmux session 'vgo')"
fi

# ---------- syncthing ---------------------------------------------------------
if ! command -v syncthing >/dev/null 2>&1; then
    echo "[extras] installing syncthing"
    apt-get update -qq && apt-get install -y -qq syncthing \
    || {  # fallback: official static binary
        echo "[extras] apt failed, fetching binary"
        ARCH=linux-amd64
        VER=$(curl -fsSL https://api.github.com/repos/syncthing/syncthing/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
        curl -fsSL "https://github.com/syncthing/syncthing/releases/download/${VER}/syncthing-${ARCH}-${VER}.tar.gz" \
          | tar xz -C /tmp
        mv /tmp/syncthing-${ARCH}-${VER}/syncthing /usr/local/bin/
    }
fi

mkdir -p "$ST_HOME" /workspace/ComfyUI/output

# Fixed identity, if provided (BEFORE generate, so it's kept not created)
if [ -n "${SYNCTHING_ID_URL:-}" ] && [ ! -f "$ST_HOME/cert.pem" ]; then
    echo "[extras] fetching fixed syncthing identity"
    curl -fsSL "$SYNCTHING_ID_URL" | tar xz -C "$ST_HOME" \
        || echo "[extras] WARN: identity fetch failed — will generate fresh"
fi

[ -f "$ST_HOME/config.xml" ] || syncthing generate --home="$ST_HOME" --no-default-folder >/dev/null 2>&1 \
    || syncthing generate --home="$ST_HOME" >/dev/null 2>&1

if ! pgrep -f "syncthing.*$ST_HOME" >/dev/null; then
    nohup syncthing serve --no-browser --home="$ST_HOME" \
        --gui-address=127.0.0.1:8384 >/tmp/syncthing.log 2>&1 &
fi

# wait for the API
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:8384/rest/noauth/health >/dev/null 2>&1 && break
    sleep 1
done

MYID=$(syncthing cli --home="$ST_HOME" show system 2>/dev/null | grep -oP '"myID":\s*"\K[^"]+' || true)
echo "[extras] syncthing device ID: ${MYID:-unknown}"

# peer + shared output folder (send-only)
if [ -n "${SYNC_PEER_ID:-}" ]; then
    syncthing cli --home="$ST_HOME" config devices add --device-id "$SYNC_PEER_ID" 2>/dev/null || true
    syncthing cli --home="$ST_HOME" config folders add \
        --id mmx-out --label "MiniMax outputs" --path /workspace/ComfyUI/output 2>/dev/null || true
    syncthing cli --home="$ST_HOME" config folders mmx-out type set sendonly 2>/dev/null || true
    syncthing cli --home="$ST_HOME" config folders mmx-out devices add --device-id "$SYNC_PEER_ID" 2>/dev/null || true
    echo "[extras] sharing /workspace/ComfyUI/output (send-only) with $SYNC_PEER_ID"
else
    echo "[extras] SYNC_PEER_ID not set — syncthing running but sharing nothing"
fi

echo "[extras] done. GUI 127.0.0.1:8384, terminal 127.0.0.1:7681"
