#!/bin/bash
set -e

source /venv/main/bin/activate

WORKSPACE=${WORKSPACE:-/workspace}
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

APT_PACKAGES=(
    "ffmpeg"
    "git"
    "wget"
    "curl"
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

function print_header() {
    echo
    echo "##############################################"
    echo "#       Provisioning ComfyUI for RTX 5090     #"
    echo "##############################################"
    echo
}

function install_apt() {
    sudo apt-get update
    sudo apt-get install -y "${APT_PACKAGES[@]}"
}

function update_comfyui() {
    if git -C "$COMFYUI_DIR" rev-parse 2>/dev/null; then
        cd "$COMFYUI_DIR"
        git pull
    else
        rm -rf "$COMFYUI_DIR"
        git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    fi
}

function install_torch_5090() {
    echo "Installing PyTorch CUDA 13.0 build for RTX 5090..."
    python -m pip install --no-cache-dir --upgrade pip

    python -m pip install --no-cache-dir --force-reinstall \
        torch==2.9.0 torchvision==0.24.0 torchaudio==2.9.0 \
        --index-url https://download.pytorch.org/whl/cu130

    python - <<'PY'
import torch
print("Torch:", torch.__version__)
print("CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY
}

function install_comfy_requirements() {
    python -m pip install --no-cache-dir -r "$COMFYUI_DIR/requirements.txt"
    python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}"
}

function get_nodes() {
    mkdir -p "$COMFYUI_DIR/custom_nodes"

    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"

        if [[ -d "$path" ]]; then
            echo "Updating node: $repo"
            cd "$path"
            git pull || true
        else
            echo "Cloning node: $repo"
            git clone "$repo" "$path" --recursive || true
        fi

        if [[ -f "$requirements" ]]; then
            python -m pip install --no-cache-dir -r "$requirements" || true
        fi
    done
}

function download_file() {
    url="$1"
    dir="$2"
    mkdir -p "$dir"

    if [[ -n "$HF_TOKEN" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        wget --header="Authorization: Bearer $HF_TOKEN" \
            -qnc --content-disposition --show-progress \
            -e dotbytes="4M" -P "$dir" "$url"
    else
        wget -qnc --content-disposition --show-progress \
            -e dotbytes="4M" -P "$dir" "$url"
    fi
}

function get_files() {
    dir="$1"
    shift
    arr=("$@")

    [[ ${#arr[@]} -eq 0 ]] && return 0

    echo "Downloading ${#arr[@]} model(s) to $dir"
    for url in "${arr[@]}"; do
        echo "Downloading: $url"
        download_file "$url" "$dir"
    done
}

function provisioning_start() {
    print_header
    install_apt
    update_comfyui
    install_torch_5090
    install_comfy_requirements
    get_nodes

    get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINT_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/lora" "${LORA_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/controlnet" "${CONTROLNET_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/upscale_models" "${UPSCALE_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    get_files "${COMFYUI_DIR}/models/esrgan" "${ESRGAN_MODELS[@]}"

    echo
    echo "Provisioning complete."
    echo
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
