#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
    "openssh-server"
)

PIP_PACKAGES=(
    "av"
    "sqlalchemy"
    "alembic"
    "google-api-python-client"
    "google-auth"
    "gdown"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/welltop-cn/ComfyUI-TeaCache.git"
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
    "https://github.com/PozzettiAndrea/ComfyUI-SAM3.git"
    "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git"
    "https://github.com/tooldigital/ComfyUI-Yolo-Cropper.git"
    "https://github.com/thalismind/ComfyUI-LoadImageWithFilename.git"
    "https://github.com/city96/ComfyUI-GGUF.git"
    "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
    "https://github.com/crystian/ComfyUI-Crystools.git"
    "https://github.com/ai-joe-git/ComfyUI-Simple-Prompt-Batcher.git"
)

CHECKPOINT_MODELS=(
)

UNET_MODELS=(
)

DIFFUSION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8/resolve/main/flux-2-klein-base-9b-fp8.safetensors"
)

LORA_MODELS=(
)

VAE_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
    "https://huggingface.co/Madespace/vae/resolve/main/ae.sft"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
)

ESRGAN_MODELS=(
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

CONTROLNET_MODELS=(
)

# ─────────────────────────────────────────────
# Google Drive folder IDs
# These map to your existing Drive folders
# ─────────────────────────────────────────────

# Service-account authenticated folder (LoRAs)
GDRIVE_LORA_FOLDER_ID="1U9_NyeTn-1LJH1UoEhOyvnbaUmBmyxDZ"
GDRIVE_LORA_TARGET="${COMFYUI_DIR}/models/loras"

# gdown folders (checkpoints, upscale, clip_vision)
GDRIVE_EXTRA_FOLDERS=(
    "1cRab0HpIYpgWge3iyT7IT_XyD8sPZuRI:${COMFYUI_DIR}/models/checkpoints"
    "1p-zHOOg3NswIOVdqBCZD96DiyAmOYswe:${COMFYUI_DIR}/models/upscale_models"
    "10OTIVt0ITyRP0IAXy_w_aq0EDwU_N3Au:${COMFYUI_DIR}/models/clip_vision"
)

# SSH public key — paste your public key here
# Generate with: ssh-keygen -t ed25519 -C "wanstudio"
SSH_PUBLIC_KEY=""

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
    provisioning_setup_ssh
    provisioning_setup_gdrive
    provisioning_sync_gdrive

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

# ─────────────────────────────────────────────
# SSH Setup
# Reads SSH_PUBLIC_KEY from env var or falls back
# to the hardcoded key in this script
# ─────────────────────────────────────────────
function provisioning_setup_ssh() {
    echo "Setting up SSH..."

    service ssh start || true

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Prefer env var, fall back to hardcoded key above
    local key="${WANSTUDIO_SSH_KEY:-$SSH_PUBLIC_KEY}"

    if [[ -n "$key" ]]; then
        echo "$key" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "SSH public key installed."
    else
        echo "WARNING: No SSH public key found. Set WANSTUDIO_SSH_KEY env var or edit SSH_PUBLIC_KEY in this script."
    fi

    # Ensure SSH daemon is configured to allow root login
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
    service ssh restart || true

    echo "SSH setup complete. Connect with: ssh -p 2222 root@<instance-ip>"
}

# ─────────────────────────────────────────────
# Google Drive Credentials Setup
# Decodes base64 credentials from env var
# GDRIVE_CREDENTIALS_B64 into credentials.json
#
# To encode your credentials.json locally run:
#   base64 -i credentials.json | tr -d '\n'
# Then set as env var in vast.ai docker options:
#   -e GDRIVE_CREDENTIALS_B64="<output>"
# ─────────────────────────────────────────────
function provisioning_setup_gdrive() {
    if [[ -n "$GDRIVE_CREDENTIALS_B64" ]]; then
        echo "Decoding Google Drive credentials..."
        echo "$GDRIVE_CREDENTIALS_B64" | base64 -d > /workspace/credentials.json
        chmod 600 /workspace/credentials.json
        echo "credentials.json written to /workspace/credentials.json"
    elif [[ -f /workspace/credentials.json ]]; then
        echo "Found existing /workspace/credentials.json — using it."
    else
        echo "WARNING: No GDRIVE_CREDENTIALS_B64 env var and no credentials.json found."
        echo "Skipping Google Drive sync. Upload credentials.json manually and re-run vlora3.py."
        return 1
    fi
}

# ─────────────────────────────────────────────
# Google Drive Sync
# Downloads missing files from your Drive folders
# ─────────────────────────────────────────────
function provisioning_sync_gdrive() {
    if [[ ! -f /workspace/credentials.json ]]; then
        echo "Skipping GDrive sync — no credentials.json."
        return 1
    fi

    echo "Starting Google Drive sync..."

    python3 << PYEOF
import os, sys

try:
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaIoBaseDownload
    from google.oauth2.service_account import Credentials
    import gdown
except ImportError as e:
    print(f"Missing package: {e}. Run pip install google-api-python-client google-auth gdown")
    sys.exit(1)

import io

SCOPES = ['https://www.googleapis.com/auth/drive.readonly']
SERVICE_ACCOUNT_FILE = '/workspace/credentials.json'

def get_drive_service():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=SCOPES)
    return build('drive', 'v3', credentials=creds)

def list_files_in_folder(service, folder_id):
    query = f"'{folder_id}' in parents and trashed = false"
    results = service.files().list(q=query, fields="files(id, name)").execute()
    return results.get('files', [])

def download_file(service, file_id, file_name, target_folder):
    request = service.files().get_media(fileId=file_id)
    file_path = os.path.join(target_folder, file_name)
    with open(file_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request)
        done = False
        while not done:
            status, done = downloader.next_chunk()
            print(f"  {file_name}: {int(status.progress() * 100)}%", flush=True)
    print(f"  -> {file_name} downloaded.")

def sync_folder(service, folder_id, target_folder):
    os.makedirs(target_folder, exist_ok=True)
    drive_files = list_files_in_folder(service, folder_id)
    local_files = set(os.listdir(target_folder))
    print(f"\n[GDrive] {len(drive_files)} files in folder -> {target_folder}")
    for f in drive_files:
        if f['name'] not in local_files:
            print(f"  Downloading: {f['name']}")
            download_file(service, f['id'], f['name'], target_folder)
        else:
            print(f"  Skipping (exists): {f['name']}")

# --- Service account sync (LoRAs) ---
print("\n=== Syncing LoRAs via service account ===")
service = get_drive_service()
sync_folder(service, "${GDRIVE_LORA_FOLDER_ID}", "${GDRIVE_LORA_TARGET}")

# --- gdown sync (checkpoints, upscale, clip_vision) ---
print("\n=== Syncing extra folders via gdown ===")
extra_folders = [
$(for entry in "${GDRIVE_EXTRA_FOLDERS[@]}"; do
    folder_id="${entry%%:*}"
    target_dir="${entry##*:}"
    echo "    (\"${folder_id}\", \"${target_dir}\"),"
done)
]
for folder_id, target_dir in extra_folders:
    os.makedirs(target_dir, exist_ok=True)
    print(f"\n[gdown] Syncing folder {folder_id} -> {target_dir}")
    gdown.download_folder(id=folder_id, output=target_dir, quiet=False, skip_download=False)

print("\nGoogle Drive sync complete.")
PYEOF

    echo "GDrive sync finished."
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
        dir="${dir%.git}"
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
    printf "\n##############################################\n#                                            #\n#             WanStudio Provisioning          #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
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
    if [ "$response" -eq 200 ]; then return 0; else return 1; fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")
    if [ "$response" -eq 200 ]; then return 0; else return 1; fi
}

function provisioning_download() {
    if [[ -n $HF_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n $CIVITAI_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n $auth_token ]]; then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    fi
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
