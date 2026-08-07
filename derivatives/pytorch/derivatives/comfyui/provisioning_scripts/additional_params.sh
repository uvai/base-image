#!/usr/bin/env bash
# additional_params.sh — hooks run by the image's /start.sh before Jupyter/ComfyUI.
# Wanstudio-style: the standing model set lives in the arrays below; edit here,
# commit, and every rental provisions it. EXTRA_HF_MODELS env remains for
# one-off additions without touching the repo.
#
# 1. Disables tokenless JupyterLab (tunnel-only posture)
# 2. Downloads the model arrays below + EXTRA_HF_MODELS (backgrounded)
# 3. Clones CUSTOM_NODE_REPOS + the repos listed in CUSTOM_NODES below
# 4. Installs user workflows from the repo tarball (WORKFLOWS_URL below)

# ── Standing model set (url -> models/<subdir>) ──────────────────────────────
# FLUX.2 Klein 9B edit stack. Gated BFL repos need HF_TOKEN with the licence
# accepted; failures log to /workspace/extra_models.log as FAILED.
DIFFUSION_MODELS=(
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8/resolve/main/flux-2-klein-base-9b-fp8.safetensors"
)
TEXT_ENCODER_MODELS=(
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"
)
VAE_MODELS=(
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
)
UPSCALE_MODELS=(
)
LORA_MODELS=(
)
CONTROLNET_MODELS=(
)

# User workflows tarball (workflows/<folder>/*.json inside) — update the tgz
# in the repo and every rental picks it up. No env var needed.
WORKFLOWS_URL="https://raw.githubusercontent.com/uvai/base-image/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/uv_workflows.tgz"

# Custom nodes cloned before ComfyUI starts (no restart needed).
CUSTOM_NODES=(
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
)

# Global SageAttention: DISABLED by default (its kernels NaN-black FLUX.2 Klein
# renders, 2026-08-07). MiniMax workflows re-enable it per-run via KJNodes'
# "Patch Sage Attention" node. Set KEEP_GLOBAL_SAGE=true for a MiniMax-only
# session where the global flag is wanted back.

# ── 1. neuter jupyter-lab ────────────────────────────────────────────────────
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/jupyter-lab <<'EOF'
#!/usr/bin/env bash
echo "[additional_params] jupyter-lab disabled by /workspace/additional_params.sh"
exit 0
EOF
chmod +x /usr/local/sbin/jupyter-lab
echo "[additional_params] JupyterLab disabled"

# ── 1b. disable global sage-attention (see note above) ───────────────────────
if [ "${KEEP_GLOBAL_SAGE:-false}" != "true" ]; then
    # runs before start.sh's sage section: no wheel -> source-build path;
    # pre-poisoned clone dir -> build fails fast -> ComfyUI starts sage-less.
    rm -f /opt/sage/*.whl 2>/dev/null
    pip uninstall -y -q sageattention >/dev/null 2>&1
    mkdir -p /tmp/SageAttention/poison
    echo "[additional_params] global sage-attention disabled (per-workflow via KJNodes)"
else
    echo "[additional_params] KEEP_GLOBAL_SAGE=true — leaving sage-attention active"
fi

# ── 2. model downloads (backgrounded; log /workspace/extra_models.log) ───────
MODELS_ROOT=/workspace/ComfyUI/models
MANIFEST=/tmp/extra_models_manifest.tsv
: > "$MANIFEST"
add_models() {  # add_models <subdir> <url>...
    local subdir="$1"; shift
    local url
    for url in "$@"; do printf '%s\t%s\n' "$url" "$subdir" >> "$MANIFEST"; done
}
add_models diffusion_models "${DIFFUSION_MODELS[@]}"
add_models text_encoders    "${TEXT_ENCODER_MODELS[@]}"
add_models vae              "${VAE_MODELS[@]}"
add_models upscale_models   "${UPSCALE_MODELS[@]}"
add_models loras            "${LORA_MODELS[@]}"
add_models controlnet       "${CONTROLNET_MODELS[@]}"
# optional env additions: url|subdir,url|subdir
if [ -n "${EXTRA_HF_MODELS:-}" ]; then
    IFS=, read -ra ITEMS <<< "$EXTRA_HF_MODELS"
    for item in "${ITEMS[@]}"; do
        printf '%s\t%s\n' "${item%%|*}" "${item##*|}" >> "$MANIFEST"
    done
fi

if [ -s "$MANIFEST" ]; then
    # copy aria2c under a different name: the image boot waits on `pgrep -x aria2c`
    command -v aria2c >/dev/null 2>&1 && cp -f "$(command -v aria2c)" /usr/local/bin/aria2uv
    nohup bash -c '
        LOG=/workspace/extra_models.log
        echo "=== extra models $(date -u +%FT%TZ) ===" >> "$LOG"
        while IFS=$'"'"'\t'"'"' read -r url subdir; do
            [ -z "$url" ] && continue
            fname=$(basename "${url%%\?*}")
            dest="'"$MODELS_ROOT"'/$subdir/$fname"
            mkdir -p "'"$MODELS_ROOT"'/$subdir"
            if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -ge $((10*1024*1024)) ]; then
                echo "skip (exists): $subdir/$fname" >> "$LOG"; continue
            fi
            echo "fetching: $subdir/$fname" >> "$LOG"
            # HF xet CDN signs redirects per byte-range: parallel connections
            # 403 mid-file (2026-08-07). Single stream + retries for hf.co.
            case "$url" in *huggingface.co*) CONN="-x1 -s1";; *) CONN="-x8 -s8";; esac
            if command -v aria2uv >/dev/null 2>&1; then
                aria2uv $CONN --continue=true --auto-file-renaming=false \
                    --max-tries=15 --retry-wait=5 \
                    ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
                    -d "'"$MODELS_ROOT"'/$subdir" -o "$fname" "$url" >> "$LOG" 2>&1
            else
                curl -fL --retry 3 -C - \
                    ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
                    -o "$dest" "$url" >> "$LOG" 2>&1
            fi
            [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -ge $((10*1024*1024)) ] \
                && echo "done: $subdir/$fname ($(du -h "$dest" | cut -f1))" >> "$LOG" \
                || echo "FAILED: $subdir/$fname" >> "$LOG"
        done < '"$MANIFEST"'
        echo "=== extra models complete ===" >> "$LOG"
    ' >/dev/null 2>&1 &
    echo "[additional_params] model fetch started ($(wc -l < "$MANIFEST") items; log: /workspace/extra_models.log)"
fi

# ── 3. custom nodes ──────────────────────────────────────────────────────────
CN_DIR=/workspace/ComfyUI/custom_nodes
mkdir -p "$CN_DIR"
ALL_NODES=("${CUSTOM_NODES[@]}")
if [ -n "${CUSTOM_NODE_REPOS:-}" ]; then
    IFS=, read -ra ENV_NODES <<< "$CUSTOM_NODE_REPOS"
    ALL_NODES+=("${ENV_NODES[@]}")
fi
for repo in "${ALL_NODES[@]}"; do
    [ -z "$repo" ] && continue
    name=$(basename "${repo%.git}")
    if [ -d "$CN_DIR/$name" ]; then
        echo "[additional_params] custom node exists: $name"
    else
        git clone --depth 1 "$repo" "$CN_DIR/$name" >/dev/null 2>&1 \
            && { [ -f "$CN_DIR/$name/requirements.txt" ] && pip install -q -r "$CN_DIR/$name/requirements.txt" >/dev/null 2>&1; \
                 echo "[additional_params] custom node installed: $name"; } \
            || echo "[additional_params] WARN: clone failed: $repo"
    fi
done

# ── 4. user workflows ────────────────────────────────────────────────────────
WF_DIR=/workspace/ComfyUI/user/default/workflows
mkdir -p "$WF_DIR"
curl -fsSL "$WORKFLOWS_URL" | tar xz -C "$WF_DIR" --strip-components=1 \
    && echo "[additional_params] user workflows installed" \
    || echo "[additional_params] WARN: workflow fetch failed (tarball missing or URL wrong?)"

# ── 5. GDrive LoRA sync (loras_minimax) ──────────────────────────────────────
# Pulls every file from the Drive folder named "loras_minimax" (shared with the
# service account) into models/loras. Auth: GDRIVE_CREDENTIALS_B64 env var
# (service-account JSON, base64 — same credential pattern as wanstudio3.sh).
# Optional: GDRIVE_MINIMAX_LORA_FOLDER_ID pins the folder by ID.
# Logs append to /workspace/extra_models.log (visible live in vgo).
if [ -n "${GDRIVE_CREDENTIALS_B64:-}" ]; then
    echo "$GDRIVE_CREDENTIALS_B64" | base64 -d > /workspace/gdrive_auth.json 2>/dev/null
    chmod 600 /workspace/gdrive_auth.json

    cat > /root/gdrive_lora_sync.py <<'PYEOF'
import os, json
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
from google.oauth2.service_account import Credentials

TARGET = "/workspace/ComfyUI/models/loras"
FOLDER_NAME = "loras_minimax"
FOLDER_ID = os.environ.get("GDRIVE_MINIMAX_LORA_FOLDER_ID", "")

creds = Credentials.from_service_account_file(
    "/workspace/gdrive_auth.json",
    scopes=["https://www.googleapis.com/auth/drive.readonly"])
svc = build("drive", "v3", credentials=creds)
sa_email = json.load(open("/workspace/gdrive_auth.json")).get("client_email", "?")

if not FOLDER_ID:
    q = ("name = '" + FOLDER_NAME + "' and "
         "mimeType = 'application/vnd.google-apps.folder' and trashed = false")
    hits = svc.files().list(q=q, fields="files(id, name)", pageSize=10).execute().get("files", [])
    if not hits:
        print(f"[gdrive] folder '{FOLDER_NAME}' not found — is it shared with {sa_email}?")
        raise SystemExit(0)
    if len(hits) > 1:
        print(f"[gdrive] WARNING: {len(hits)} folders named {FOLDER_NAME}; using first. "
              "Pin with GDRIVE_MINIMAX_LORA_FOLDER_ID.")
    FOLDER_ID = hits[0]["id"]

files, tok = [], None
while True:
    r = svc.files().list(q=f"'{FOLDER_ID}' in parents and trashed = false",
                         fields="nextPageToken, files(id, name, size, mimeType)",
                         pageSize=1000, pageToken=tok).execute()
    files += r.get("files", [])
    tok = r.get("nextPageToken")
    if not tok:
        break
files = [f for f in files if f.get("mimeType") != "application/vnd.google-apps.folder"]
suffix = "" if files else f" — if unexpected, share the folder with {sa_email}"
print(f"[gdrive] {FOLDER_NAME}: {len(files)} file(s){suffix}")

os.makedirs(TARGET, exist_ok=True)
for f in files:
    dest = os.path.join(TARGET, f["name"])
    dsize = int(f.get("size", 0) or 0)
    if os.path.exists(dest) and dsize and os.path.getsize(dest) == dsize:
        print(f"[gdrive] skip (exists): {f['name']}")
        continue
    print(f"[gdrive] fetching: {f['name']} ({dsize // 1048576} MB)", flush=True)
    tmp = dest + ".part"
    try:
        with open(tmp, "wb") as fh:
            dl = MediaIoBaseDownload(fh, svc.files().get_media(fileId=f["id"]),
                                     chunksize=16 * 1024 * 1024)
            done = False
            while not done:
                _, done = dl.next_chunk()
        if dsize and os.path.getsize(tmp) != dsize:
            raise IOError(f"size mismatch: {os.path.getsize(tmp)} != {dsize}")
        os.replace(tmp, dest)
        print(f"[gdrive] done: {f['name']}")
    except Exception as e:
        print(f"[gdrive] FAILED: {f['name']}: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
print("[gdrive] loras_minimax sync complete")
PYEOF

    setsid nohup bash -c '
        LOG=/workspace/extra_models.log
        echo "=== gdrive loras_minimax $(date -u +%FT%TZ) ===" >> "$LOG"
        pip install -q google-api-python-client google-auth >> "$LOG" 2>&1
        python3 /root/gdrive_lora_sync.py >> "$LOG" 2>&1
    ' >/dev/null 2>&1 < /dev/null &
    echo "[additional_params] gdrive loras_minimax sync started"
else
    echo "[additional_params] GDRIVE_CREDENTIALS_B64 not set — gdrive lora sync skipped"
fi
