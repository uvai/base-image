#!/usr/bin/env bash
# mmx_extras.sh — browser terminal + direct NAS output sync for the MiniMax instance.
# v4: the nebN session folder is created lazily (first real output) and an empty newest nebN is reused.
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

# wait for the NAS to be reachable through the fresh tailnet path — the first
# seconds after tailscale up can drop connections, and a failed listing must
# not be mistaken for an empty directory (the neb1 bug, 2026-08-07).
NAS_UP=""
for i in $(seq 1 12); do
    if eval "$NAS_SSH" "$NAS_USERHOST" "\"true\"" 2>/dev/null; then NAS_UP=1; break; fi
    log "NAS not reachable yet (attempt $i/12), retrying in 5s"
    sleep 5
done
[ -z "$NAS_UP" ] && { log "ERROR: NAS unreachable after 60s — no sync this session"; exit 1; }

# session folder (sticky per instance). v4: created LAZILY — only once ComfyUI has written a
# real file — and the newest nebN on the NAS is reused when it holds no real files, so a dud
# instance never leaves an empty nebN behind (2026-11-20).
NEB_FILE=/root/.neb_session
OUT=/workspace/ComfyUI/output
mkdir -p "$OUT"
# "real" = anything except ComfyUI's placeholder, dotfiles, partials and Synology metadata
real_local() { find "$OUT" -type f ! -name '_output_images_will_be_put_here' ! -name '.*' ! -name '*.part*' 2>/dev/null | head -1; }
pick_session() {
    LISTING=$(eval "$NAS_SSH" "$NAS_USERHOST" "\"ls -1d $NAS_BASE/neb* 2>/dev/null\"") || LISTING=""
    LAST=$(printf '%s\n' "$LISTING" | grep -oE 'neb[0-9]+$' | grep -oE '[0-9]+' | sort -n | tail -1)
    if [ -z "$LAST" ]; then
        # an empty listing must not be mistaken for "no history" (the neb1 bug, 2026-08-07)
        eval "$NAS_SSH" "$NAS_USERHOST" "\"test -d $NAS_BASE\"" \
            || { log "ERROR: $NAS_BASE missing on NAS (share locked?) — will retry"; return 1; }
        NEB=neb1
    else
        HAS=$(eval "$NAS_SSH" "$NAS_USERHOST" "\"find $NAS_BASE/neb$LAST -type f ! -name _output_images_will_be_put_here ! -name '.*' ! -path '*@eaDir*' 2>/dev/null | head -1; echo LISTED\"") || HAS=""
        case "$HAS" in
            *LISTED*) ;;
            *) log "WARN: could not inspect neb$LAST — will retry"; return 1;;
        esac
        if [ "$HAS" = "LISTED" ]; then NEB="neb$LAST"; log "neb$LAST has no files — reusing it"
        else NEB="neb$(( LAST + 1 ))"; fi
    fi
    eval "$NAS_SSH" "$NAS_USERHOST" "\"mkdir -p $NAS_BASE/$NEB\"" \
        || { log "ERROR: cannot create $NAS_BASE/$NEB — will retry"; return 1; }
    echo "$NEB" > "$NEB_FILE"
    log "session folder: $NAS_BASE/$NEB"
}

if [ -f "$NEB_FILE" ]; then
    log "resuming session $(cat "$NEB_FILE")"
else
    log "no session folder yet — one is created on the NAS when the first output file appears"
fi

# sync loop with heartbeat
log "sync loop starting -> $NAS_BASE (every 60s)"
while true; do
    if [ ! -f "$NEB_FILE" ]; then
        if [ -z "$(real_local)" ] || ! pick_session; then sleep 30; continue; fi
    fi
    NEB=$(cat "$NEB_FILE")
    if eval rsync -a --partial -e "\"$NAS_SSH\"" \
        "$OUT/" "$NAS_USERHOST:$NAS_BASE/$NEB/" >/dev/null 2>&1; then
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
