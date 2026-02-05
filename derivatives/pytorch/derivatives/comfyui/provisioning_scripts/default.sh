!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
    "package-1"
    "package-2"
)

PIP_PACKAGES=(
    "av"
    "sqlalchemy"
    "alembic"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    # "https://github.com/cubiq/ComfyUI_essentials"
    # "https://github.com/welltop-cn/ComfyUI-TeaCache.git"
    # "https://github.com/kijai/ComfyUI-KJNodes"
    # "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    # "https://github.com/rgthree/rgthree-comfy.git"
    # "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git"
    # "https://github.com/WASasquatch/was-node-suite-comfyui.git"
    # "https://github.com/ClownsharkBatwing/RES4LYF.git"
    # "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git"
    # "https://github.com/kijai/ComfyUI-GIMM-VFI.git"
    # "https://github.com/BigStationW/ComfyUi-Scale-Image-to-Total-Pixels-Advanced.git"
    # "https://github.com/moonwhaler/comfyui-seedvr2-tilingupscaler.git"
    # "https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler.git"
    # "https://github.com/1038lab/ComfyUI-RMBG.git"
    # "https://github.com/CY-CHENYUE/ComfyUI-InpaintEasy.git"
    # "https://github.com/chflame163/ComfyUI_LayerStyle.git"
    # "https://github.com/yolain/ComfyUI-Easy-Use.git"
    # "https://github.com/PozzettiAndrea/ComfyUI-SAM3.git"
    # "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git"
    # "https://github.com/tooldigital/ComfyUI-Yolo-Cropper.git"
    # "https://github.com/thalismind/ComfyUI-LoadImageWithFilename.git"
    # "https://github.com/city96/ComfyUI-GGUF.git"
    


    # "https://github.com/crystian/ComfyUI-Crystools.git"
    
    
)

CHECKPOINT_MODELS=(



    # "https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/v20/Qwen-Rapid-AIO-NSFW-v20.safetensors"


)

UNET_MODELS=(

)

DIFFUSION_MODELS=(
    # "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    # "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"

    # "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors"
    # "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"


    


    

)

LORA_MODELS=(

)

VAE_MODELS=(

    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
    "https://huggingface.co/Madespace/vae/resolve/main/ae.sft"
    "https://huggingface.co/camenduru/FLUX.1-dev/resolve/d616d290809ffe206732ac4665a9ddcdfb839743/ae.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"
    "https://huggingface.co/StableDiffusionVN/Flux/resolve/main/Vae/flux_vae.safetensors"
    
)

ESRGAN_MODELS=(

)

UPSCALE_MODELS=(

)

TEXT_ENCODER_MODELS=(
    "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/clip_l.safetensors"

    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
)

CLIP_VISION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)


CONTROLNET_MODELS=(

)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###
function provisioning_start() {
    provisioning_print_header

    echo "Auto-updating ComfyUI core..."
    if git -C /workspace/ComfyUI rev-parse 2>/dev/null; then
        echo "Found git repo, pulling latest ComfyUI..."
        (cd /workspace/ComfyUI && git pull)
    else
        echo "ComfyUI not a git repo or missing. Cloning fresh copy..."
        rm -rf /workspace/ComfyUI
        git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
    fi

    echo "Installing ComfyUI core requirements..."
    python -m pip install --no-cache-dir -r /workspace/ComfyUI/requirements.txt
    
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    # provisioning_install_sageattention
    provisioning_get_files \
        "${COMFYUI_DIR}/models/checkpoints" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/lora" \
        "${LORA_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/upscale_models" \
        "${UPSCALE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/diffusion_models" \
        "${DIFFUSION_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/text_encoders" \
        "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/clip_vision" \
        "${CLIP_VISION_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/esrgan" \
        "${ESRGAN_MODELS[@]}"
    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
            sudo $APT_INSTALL ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
            pip install --no-cache-dir ${PIP_PACKAGES[@]}
    fi
}


function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                   pip install --no-cache-dir -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                pip install --no-cache-dir -r "${requirements}"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    
    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# Download from $1 URL to $2 file path
function provisioning_download() {
    if [[ -n $HF_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif 
        [[ -n $CIVITAI_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n $auth_token ]];then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    fi
}

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
