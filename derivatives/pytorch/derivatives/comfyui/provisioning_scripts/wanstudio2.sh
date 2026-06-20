#!/usr/bin/env bash
# WanStudio provisioning script — RTX 5090 focused
# Changes:
# - Installs newer PyTorch CUDA stack for RTX 5090 / WAN FP8 quantisation
# - Removes broken/problematic nodes seen in logs: TeaCache, SAM3, Yolo-Cropper
# - Removes fake apt packages
# - Adds diagnostics so the log confirms torch/CUDA/GPU versions

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

if [[ -f /venv/main/bin/activate ]]; then
    source /venv/main/bin/activate
else
    echo "WARNING: /venv/main/bin/activate not found. Continuing with current Python."
fi

APT_PACKAGES=(
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
    "nvidia-ml-py"
)

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

function provisioning_start() {
    PROVISIONING_START_TIME=$(date +%s)

    provisioning_print_header
    provisioning_get_apt_packages

    echo "Auto-updating ComfyUI core..."
    if git -C "${COMFYUI_DIR}" rev-parse 2>/dev/null; then
        echo "Found ComfyUI git repo, pulling latest..."
        (cd "${COMFYUI_DIR}" && git pull --rebase) || (cd "${COMFYUI_DIR}" && git pull)
    else
        echo "ComfyUI not found or not a git repo. Cloning fresh copy..."
        rm -rf "${COMFYUI_DIR}"
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"
    fi

    provisioning_install_torch_5090

    echo "Installing ComfyUI core requirements..."
    python -m pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"

    provisioning_get_pip_packages
    provisioning_get_nodes
    provisioning_print_system_info

    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
    # provisioning_get_files "${COMFYUI_DIR}/models/lora" "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/controlnet" "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/upscale_models" "${UPSCALE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/esrgan" "${ESRGAN_MODELS[@]}"

    provisioning_print_end
}

function provisioning_install_torch_5090() {
    echo
    echo "Installing RTX 5090 PyTorch stack..."
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel

    set +e
    python -m pip install --no-cache-dir --force-reinstall \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu130
    local CU130_STATUS=$?
    set -e

    if [[ $CU130_STATUS -ne 0 ]]; then
        echo "WARNING: cu130 install failed. Falling back to PyTorch nightly cu128."
        python -m pip install --no-cache-dir --upgrade --pre \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/nightly/cu128
    fi

    provisioning_print_torch_info
}

function provisioning_print_torch_info() {
    python - <<'PY'
import torch
print("Torch:", torch.__version__)
print("Torch CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("Capability:", torch.cuda.get_device_capability(0))
PY
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing apt packages..."
    sudo apt-get update || true
    sudo apt-get install -y "${APT_PACKAGES[@]}"
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing extra pip packages..."
    python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}"
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
                (cd "$path" && git pull --rebase) || (cd "$path" && git pull) || true
            fi
        else
            printf "Downloading node: %s...\n" "$repo"
            git clone "$repo" "$path" --recursive || {
                echo "WARNING: Failed to clone $repo"
                continue
            }
        fi

        if [[ -f "$requirements" ]]; then
            python -m pip install --no-cache-dir -r "$requirements" || echo "WARNING: requirements failed for $repo"
        fi
    done
}

function provisioning_get_files() {
    local dir="$1"
    shift || true
    local arr=("$@")

    if [[ ${#arr[@]} -eq 0 ]]; then
        return 0
    fi

    mkdir -p "$dir"
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"

    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "$url"
        provisioning_download "$url" "$dir"
        printf "\n"
    done
}

function provisioning_download() {
    local url="$1"
    local dir="$2"
    local auth_token=""

    if [[ -n "${HF_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi

    if [[ -n "$auth_token" ]]; then
        wget --header="Authorization: Bearer $auth_token" \
            -qnc --content-disposition --show-progress \
            -e dotbytes="4M" -P "$dir" "$url" || echo "WARNING: Download failed: $url"
    else
        wget -qnc --content-disposition --show-progress \
            -e dotbytes="4M" -P "$dir" "$url" || echo "WARNING: Download failed: $url"
    fi
}

function provisioning_print_system_info() {
    echo
    echo "===== SYSTEM INFO ====="
    nvidia-smi || true
    provisioning_print_torch_info || true
    echo "ComfyUI dir: ${COMFYUI_DIR}"
    echo "Python: $(which python)"
    echo "======================="
    echo
}

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#       WanStudio RTX 5090 Provisioning      #\n"
    printf "#                                            #\n"
    printf "#         This will take some time           #\n"
    printf "#                                            #\n"
    printf "##############################################\n\n"
}

function provisioning_print_end() {
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - PROVISIONING_START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Provisioning complete — took ${mins}m ${secs}s"
    echo "Application will start now"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
