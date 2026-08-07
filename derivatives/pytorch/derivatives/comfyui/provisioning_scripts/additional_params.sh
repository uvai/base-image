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
)

# ── 1. neuter jupyter-lab ────────────────────────────────────────────────────
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/jupyter-lab <<'EOF'
#!/usr/bin/env bash
echo "[additional_params] jupyter-lab disabled by /workspace/additional_params.sh"
exit 0
EOF
chmod +x /usr/local/sbin/jupyter-lab
echo "[additional_params] JupyterLab disabled"

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
            if command -v aria2c >/dev/null 2>&1; then
                aria2c -x8 -s8 --continue=true --auto-file-renaming=false \
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
