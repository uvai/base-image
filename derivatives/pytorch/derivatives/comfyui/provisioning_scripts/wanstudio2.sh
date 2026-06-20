#!/bin/bash
set -Eeuo pipefail

# WanStudio / ComfyUI provisioning for Vast.ai RTX 5090
# Practical target for Vast images that currently top out at CUDA 12.9:
#   - Use the CUDA 12.9 image.
#   - Force-install a modern PyTorch CUDA 12.8 nightly/stable wheel inside the venv.
#   - Reinstall/verify torch at the END because custom node requirements can downgrade it.
#   - Launch ComfyUI with low VRAM flags via COMFYUI_ARGS in your Vast command.

source /venv/main/bin/activate

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

# Override these from Vast env vars if needed.
# Examples:
#   -e TORCH_INDEX_URL="https://download.pytorch.org/whl/nightly/cu128"
#   -e TORCH_PACKAGES="--pre torch torchvision torchaudio"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/nightly/cu128}"
TORCH_PACKAGES="${TORCH_PACKAGES:---pre torch torchvision torchaudio}"

APT_PACKAGES=(
    "openssh-server"
    "ffmpeg"
    "git"
    "wget"
    "curl"
    "ca-certificates"
)

PIP_PACKAGES=(
    "av"
    "sqlalchemy"
    "alembic"
    "google-api-python-client"
    "google-auth"
    "gdown"
    "websocket-client"
    "nvidia-ml-py"
)

# Disabled for this 5090 build because your logs showed import/env problems:
#   ComfyUI-TeaCache: import error against current ComfyUI lightricks API
#   ComfyUI-SAM3: isolation env missing unless separately materialised
#   ComfyUI-Yolo-Cropper: needs ultralytics and can drag in large deps
# Re-enable only after the base WAN workflow is stable.
NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git"
    "https://github.com/WASasquatch/was-node-suite-comfyui.git"
    "https://github.com/ClownsharkBatwing/RES4LYF.git"
    "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git"
    "https://github.com/kijai/ComfyUI-GIMM-VFI.git"
    "https://github.com/BigStationW/ComfyUi-Scale-Image-to-Total-Pixels-Advanced.git"
    "https://github.com/moonwhaler/comfyui-seedvr2-tilingupscaler.git"
    "https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler.git"
    "https://github.com/1038lab/ComfyUI-RMBG.git"
    "https://github.com/CY-CHENYUE/ComfyUI-InpaintEasy.git"
    "https://github.com/chflame163/ComfyUI_LayerStyle.git"
    "https://github.com/yolain/ComfyUI-Easy-Use.git"
    "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git"
    "https://github.com/thalismind/ComfyUI-LoadImageWithFilename.git"
    "https://github.com/city96/ComfyUI-GGUF.git"
    "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
    "https://github.com/crystian/ComfyUI-Crystools.git"
    "https://github.com/ai-joe-git/ComfyUI-Simple-Prompt-Batcher.git"
)

CHECKPOINT_MODELS=()
UNET_MODELS=()
LORA_MODELS=()
CONTROLNET_MODELS=()
ESRGAN_MODELS=()

DIFFUSION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8/resolve/main/flux-2-klein-base-9b-fp8.safetensors"
)

VAE_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
    "https://huggingface.co/Madespace/vae/resolve/main/ae.sft"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
)

UPSCALE_MODELS=(
    "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_NMKD-Siax_200k.pth"
)

TEXT_ENCODER_MODELS=(
    "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/clip_l.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors"
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"
)

CLIP_VISION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)

SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#          WanStudio 5090 Provisioning        #\n"
    printf "##############################################\n\n"
}

function provisioning_print_end() {
    local end_time elapsed mins secs
    end_time=$(date +%s)
    elapsed=$((end_time - PROVISIONING_START_TIME))
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    echo -e "\n\e[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
    echo -e "\e[1;32m  ✅ Provisioning complete — took ${mins}m ${secs}s\e[0m"
    echo -e "\e[1;32m  Application will start now\e[0m"
    echo -e "\e[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
}

function provisioning_get_apt_packages() {
    echo "Installing apt packages..."
    sudo apt-get update
    sudo apt-get install -y "${APT_PACKAGES[@]}"
}

function provisioning_update_comfyui() {
    echo "Auto-updating ComfyUI core..."
    if git -C "$COMFYUI_DIR" rev-parse 2>/dev/null; then
        echo "Found git repo, pulling latest ComfyUI..."
        git -C "$COMFYUI_DIR" pull || true
    else
        echo "ComfyUI not a git repo or missing. Cloning fresh copy..."
        rm -rf "$COMFYUI_DIR"
        git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    fi
}

function provisioning_install_comfy_requirements() {
    echo "Installing ComfyUI core requirements..."
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel
    python -m pip install --no-cache-dir -r "$COMFYUI_DIR/requirements.txt"
}

function provisioning_get_pip_packages() {
    echo "Installing base pip packages..."
    python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}"
}

function provisioning_force_torch_5090() {
    echo "Forcing PyTorch build for RTX 5090..."
    echo "TORCH_INDEX_URL=${TORCH_INDEX_URL}"
    echo "TORCH_PACKAGES=${TORCH_PACKAGES}"

    # Do this after Comfy/custom-node requirements so they cannot quietly leave us on torch 2.7/cu128 from the base image.
    python -m pip uninstall -y torch torchvision torchaudio || true
    python -m pip install --no-cache-dir --upgrade ${TORCH_PACKAGES} --index-url "${TORCH_INDEX_URL}"

    echo "Verifying PyTorch..."
    python - <<'PY'
import sys
import torch
print("Torch:", torch.__version__)
print("PyTorch CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("Capability:", torch.cuda.get_device_capability(0))
else:
    sys.exit("ERROR: PyTorch cannot see CUDA/GPU")
PY
}

function provisioning_get_nodes() {
    mkdir -p "${COMFYUI_DIR}/custom_nodes"

    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"

        if [[ -d "$path" ]]; then
            if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
                printf "Updating node: %s...\n" "$repo"
                ( cd "$path" && git pull ) || true
            fi
        else
            printf "Downloading node: %s...\n" "$repo"
            git clone "$repo" "$path" --recursive || {
                echo "WARNING: failed to clone $repo; continuing."
                continue
            }
        fi

        if [[ -f "$requirements" ]]; then
            python -m pip install --no-cache-dir -r "$requirements" || {
                echo "WARNING: requirements install failed for $repo; continuing."
            }
        fi
    done
}

function provisioning_setup_jupyter_theme() {
    echo "Setting JupyterLab dark theme..."
    mkdir -p /root/.jupyter/lab/user-settings/@jupyterlab/apputils-extension
    cat > /root/.jupyter/lab/user-settings/@jupyterlab/apputils-extension/themes.jupyterlab-settings << 'EOF_THEME'
{
    "theme": "JupyterLab Dark"
}
EOF_THEME
}

function provisioning_setup_ssh() {
    echo "Setting up SSH..."
    service ssh start || true

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    local key="${WANSTUDIO_SSH_KEY:-$SSH_PUBLIC_KEY}"
    if [[ -n "$key" ]]; then
        grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "SSH public key installed."
    else
        echo "WARNING: No SSH public key found. Set WANSTUDIO_SSH_KEY env var."
    fi

    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    service ssh restart || true
}

function provisioning_setup_gdrive() {
    CREDENTIALS_GDRIVE_ID="1akurAPebSquq5vmedB_ZRygoX-KKffRC"

    if [[ -n "${GDRIVE_CREDENTIALS_B64:-}" ]]; then
        echo "Decoding Google Drive credentials from env var..."
        echo "$GDRIVE_CREDENTIALS_B64" | base64 -d > /workspace/gdrive_auth.json
        chmod 600 /workspace/gdrive_auth.json
    fi

    if ! python3 -c "import json; json.load(open('/workspace/gdrive_auth.json'))" 2>/dev/null; then
        echo "gdrive_auth.json missing or invalid — downloading fallback from Google Drive..."
        gdown --id "$CREDENTIALS_GDRIVE_ID" -O /workspace/gdrive_auth.json || true
        chmod 600 /workspace/gdrive_auth.json 2>/dev/null || true
    fi

    if python3 -c "import json; json.load(open('/workspace/gdrive_auth.json'))" 2>/dev/null; then
        echo "gdrive_auth.json is valid."
    else
        echo "WARNING: gdrive_auth.json invalid. GDrive sync will be skipped."
        return 1
    fi
}

function provisioning_get_vlora_script() {
    echo "Downloading vlora3.py from GitHub..."
    wget -q -O /workspace/vlora3.py \
        https://raw.githubusercontent.com/uvai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/vlora3.py
    chmod +x /workspace/vlora3.py
}

function provisioning_sync_gdrive() {
    if [[ ! -f /workspace/gdrive_auth.json ]]; then
        echo "Skipping GDrive sync — no gdrive_auth.json."
        return 0
    fi

    provisioning_get_vlora_script || {
        echo "WARNING: Could not download vlora3.py; skipping GDrive sync."
        return 0
    }

    echo "Running vlora3.py..."
    python3 /workspace/vlora3.py || echo "WARNING: vlora3.py failed; continuing."
}

function provisioning_download() {
    local url="$1"
    local dir="$2"
    local dotbytes="${3:-4M}"
    local auth_token=""

    if [[ -n "${HF_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi

    mkdir -p "$dir"
    if [[ -n "$auth_token" ]]; then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="$dotbytes" -P "$dir" "$url" || true
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="$dotbytes" -P "$dir" "$url" || true
    fi
}

function provisioning_get_files() {
    local dir="$1"
    shift || true
    local arr=("$@")

    [[ ${#arr[@]} -eq 0 ]] && return 0

    mkdir -p "$dir"
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "$url"
        provisioning_download "$url" "$dir"
        printf "\n"
    done
}

function provisioning_start() {
    PROVISIONING_START_TIME=$(date +%s)
    provisioning_print_header

    provisioning_get_apt_packages
    provisioning_update_comfyui
    provisioning_install_comfy_requirements
    provisioning_get_pip_packages
    provisioning_get_nodes

    # Reinstall torch after node deps, because some node requirements can replace torch.
    provisioning_force_torch_5090

    provisioning_setup_ssh
    provisioning_setup_jupyter_theme

    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/lora" "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/controlnet" "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/upscale_models" "${UPSCALE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/esrgan" "${ESRGAN_MODELS[@]}"

    provisioning_setup_gdrive || true
    provisioning_sync_gdrive || true

    provisioning_print_end
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
