#!/usr/bin/env bash
# minimax.sh — MiniMax H3 provisioning for the vastai/comfy base image.
# Wanstudio-style port of hearmeman/comfyui-minimax-template's boot logic.
# Invoked by the base image via PROVISIONING_SCRIPT; runs with the venv active
# and ComfyUI managed by the image's supervisor (we never start ComfyUI here).
#
# Env:
#   minimax_quant   int8 (default) | fp8 | nvfp4     nvfp4 = Blackwell only
#   HF_TOKEN        required (Comfy-Org/MiniMax-H3 is public, but token avoids
#                   rate limits and matches the original template's behaviour)
#   H3_WORKFLOWS_URL  optional tarball of the three H3 workflow JSONs; falls
#                   back to ComfyUI v0.30+'s bundled H3 templates if unset.
#
# Registry extracted from the hearmeman image's /models_registry.json 2026-08-06.

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE}/ComfyUI}"
MODELS_ROOT="${COMFYUI_DIR}/models"
WORKFLOW_DIR="${COMFYUI_DIR}/user/default/workflows"
QUANT="${minimax_quant:-int8}"
HF_BASE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"

echo "[minimax] quant=${QUANT} models_root=${MODELS_ROOT}"

# ---- quant profiles (from workflow_provisioner.py QUANT_PROFILES) -----------
# role order: fl2va_dit ref2va_dit text_encoder
case "$QUANT" in
  int8)
    FL2VA="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
    REF2VA="minimax_h3_ref2va_pruned_int8_convrot.safetensors"
    TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
    ;;
  fp8)
    FL2VA="minimax_h3_fl2va_pruned_fp8_scaled.safetensors"
    REF2VA="minimax_h3_ref2va_pruned_fp8_scaled.safetensors"
    TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
    ;;
  nvfp4)
    FL2VA="minimax_h3_fl2va_pruned_fp8_scaled.safetensors"
    REF2VA="minimax_h3_ref2va_pruned_fp8_scaled.safetensors"
    TE="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
    ;;
  *)
    echo "[minimax] FATAL: unknown minimax_quant '$QUANT' (int8|fp8|nvfp4)" >&2
    exit 1
    ;;
esac

# ---- download manifest: file<TAB>subdir -------------------------------------
MANIFEST=$(cat <<EOF
${FL2VA}	diffusion_models
${REF2VA}	diffusion_models
${TE}	text_encoders
minimax_h3_video_vae_fp16.safetensors	vae
minimax_h3_audio_vae_fp32.safetensors	vae
EOF
)

# ---- fetch ------------------------------------------------------------------
AUTH_HEADER=""
[ -n "${HF_TOKEN:-}" ] && AUTH_HEADER="Authorization: Bearer ${HF_TOKEN}"

fetch() {  # fetch <url> <dest>
    local url="$1" dest="$2"
    # Same completeness heuristic as the original provisioner: files >10MB on
    # disk are trusted; anything smaller is a truncated artifact — re-fetch.
    if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -ge $((10*1024*1024)) ]; then
        echo "[minimax] exists, skipping: $(basename "$dest")"
        return 0
    fi
    echo "[minimax] downloading: $(basename "$dest")"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -x8 -s8 --continue=true --auto-file-renaming=false \
            ${AUTH_HEADER:+--header="$AUTH_HEADER"} \
            -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url"
    else
        wget -c ${AUTH_HEADER:+--header="$AUTH_HEADER"} -O "$dest" "$url"
    fi
}

while IFS=$'\t' read -r fname subdir; do
    mkdir -p "${MODELS_ROOT}/${subdir}"
    fetch "${HF_BASE}/${subdir}/${fname}" "${MODELS_ROOT}/${subdir}/${fname}"
done <<< "$MANIFEST"

# ---- workflows --------------------------------------------------------------
mkdir -p "$WORKFLOW_DIR"
if [ -n "${H3_WORKFLOWS_URL:-}" ]; then
    echo "[minimax] fetching workflow bundle: $H3_WORKFLOWS_URL"
    curl -fsSL "$H3_WORKFLOWS_URL" | tar xz -C "$WORKFLOW_DIR" --strip-components=1
    # The bundled workflows are authored against int8; repoint loader widgets
    # at the quant actually downloaded (exact-filename swaps, same effect as
    # workflow_provisioner.py's widget rewrite).
    if [ "$QUANT" != "int8" ]; then
        find "$WORKFLOW_DIR" -name '*.json' -exec sed -i \
            -e "s/minimax_h3_fl2va_pruned_int8_convrot\.safetensors/${FL2VA}/g" \
            -e "s/minimax_h3_ref2va_pruned_int8_convrot\.safetensors/${REF2VA}/g" \
            -e "s/qwen3vl_32b_minimax_h3_int8_convrot\.safetensors/${TE}/g" {} +
        echo "[minimax] workflows retargeted to ${QUANT}"
    fi
else
    echo "[minimax] H3_WORKFLOWS_URL unset — using ComfyUI's bundled H3 templates"
    echo "[minimax] (Workflow menu -> Browse Templates -> MiniMax H3; pick the"
    echo "[minimax]  ${QUANT} files in the loader dropdowns if they differ)"
fi

echo "[minimax] provisioning complete (quant=${QUANT})"
