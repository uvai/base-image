#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
# WanStudio provisioning — SINGLE-FILE version (wanstudio3.sh)
#
# Merges wanstudio2.sh + vlora3.py into one script. The GDrive/HF sync python
# is embedded below as a heredoc, so there is exactly ONE file to maintain and
# ONE URL to point PROVISIONING_SCRIPT at. No second fetch that can 404.
#
# Hardening over the old pair:
#   * pkg_resources dependency removed (crashed on py3.12 venvs without
#     setuptools). Plain `pip install` is idempotent; setuptools installed
#     anyway as a backstop.
#   * Drive listing is PAGINATED (old code silently capped at 100 files).
#   * Every Drive folder ALWAYS prints a count — a 0-file folder prints a loud
#     warning with the service-account email (the usual cause: folder not
#     shared with that email).
#   * Partial/zero-byte local files are detected by SIZE COMPARISON against
#     Drive metadata and re-downloaded (old code skipped on filename alone).
#   * Download failures are ACCUMULATED and reported in a banner at the end,
#     and drop a marker file at /workspace/.gdrive_sync_failed. Provisioning
#     continues (HF models etc. are still useful) but the failure is
#     impossible to miss in the log and on disk.
#   * Final verification prints a LoRA count so "did my LoRAs sync?" is
#     answerable at a glance.
#
# Requirements unchanged:
#   * GDRIVE_CREDENTIALS_B64 env var (service-account JSON, base64).
#     The Drive folders must be shared with that service account's email.
#   * HF_TOKEN env var for gated HF repos (FLUX.2 klein).
#   * Big disk: --disk 180 (min 150).
# ═════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE}/ComfyUI"
GDRIVE_AUTH_FILE="${WORKSPACE}/gdrive_auth.json"
SYNC_FAILED_MARKER="${WORKSPACE}/.gdrive_sync_failed"

if [[ -f /venv/main/bin/activate ]]; then
    source /venv/main/bin/activate
fi

# ── Package lists ────────────────────────────────────────────────────────────
APT_PACKAGES=(
    "ffmpeg" "git" "wget" "curl" "ca-certificates" "openssh-server"
)

PIP_PACKAGES=(
    "setuptools"            # backstop: some py3.12 venvs ship without it
    "av" "sqlalchemy" "alembic" "nvidia-ml-py" "gdown"
    "google-api-python-client" "google-auth"
    "huggingface_hub" "tqdm" "websocket-client"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
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
    # "https://github.com/CY-CHENYUE/ComfyUI-InpaintEasy.git"
    "https://github.com/chflame163/ComfyUI_LayerStyle.git"
    "https://github.com/yolain/ComfyUI-Easy-Use.git"
    "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git"
    "https://github.com/thalismind/ComfyUI-LoadImageWithFilename.git"
    "https://github.com/city96/ComfyUI-GGUF.git"
    # "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
    "https://github.com/crystian/ComfyUI-Crystools.git"
    "https://github.com/ai-joe-git/ComfyUI-Simple-Prompt-Batcher.git"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
    "https://github.com/jakechai/ComfyUI-JakeUpgrade.git"
)

# Removed on every run, case-insensitive.
PROBLEM_NODES=(
    "ComfyUI-TeaCache" "teacache"
    "ComfyUI-SAM3" "sam3"
    "ComfyUI-Yolo-Cropper" "Yolo-Cropper" "yolo-cropper"
)

# SSH public key — prefer WANSTUDIO_SSH_KEY env var; fall back to this.
SSH_PUBLIC_KEY=""

# ── Model lists (direct wget, non-GDrive) ────────────────────────────────────
CHECKPOINT_MODELS=()
UNET_MODELS=()
LORA_MODELS=()
CONTROLNET_MODELS=()
ESRGAN_MODELS=()

# FLUX.2 klein lives ONLY here (diffusion_models). It is NOT in the GDrive/HF
# sync below — that double-download is dead.
DIFFUSION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8/resolve/main/flux-2-klein-base-9b-fp8.safetensors"

    "https://huggingface.co/QuantStack/Wan2.2-I2V-A14B-GGUF/blob/main/HighNoise/Wan2.2-I2V-A14B-HighNoise-Q4_K_M.gguf"
    "https://huggingface.co/QuantStack/Wan2.2-I2V-A14B-GGUF/blob/main/LowNoise/Wan2.2-I2V-A14B-LowNoise-Q4_K_M.gguf"
    
)

VAE_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
    "https://huggingface.co/Madespace/vae/resolve/main/ae.sft"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
    
)

UPSCALE_MODELS=(
    # "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_NMKD-Siax_200k.pth"
)

TEXT_ENCODER_MODELS=(
    "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/clip_l.safetensors"
    # "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    # "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
    # "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    # "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
    # "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors"
    # "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"
    "https://huggingface.co/city96/umt5-xxl-encoder-gguf/blob/main/umt5-xxl-encoder-Q3_K_S.gguf"
)

CLIP_VISION_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)

# ═════════════════════════════════════════════════════════════════════════════
# Main flow
# ═════════════════════════════════════════════════════════════════════════════
function provisioning_start() {
    PROVISIONING_START_TIME=$(date +%s)

    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_update_comfyui

    echo "Installing ComfyUI core requirements..."
    python -m pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt" || {
        echo "WARNING: ComfyUI requirements install had issues; continuing."
    }

    # Torch LAST and force-reinstalled, so it wins.
    provisioning_install_torch_5090

    provisioning_get_pip_packages
    provisioning_get_nodes
    provisioning_remove_problem_nodes
    provisioning_setup_ssh
    provisioning_setup_jupyter_theme
    provisioning_print_system_info
    provisioning_check_disk_space
    provisioning_check_hf_token

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

    # GDrive LoRAs / extra folders + GIMM-VFI HF models (embedded python).
    provisioning_setup_gdrive && provisioning_run_gdrive_sync \
        || echo "WARNING: GDrive credential setup failed — sync skipped."

    provisioning_verify_downloads
    provisioning_print_oom_hint
    provisioning_print_end
}

# ── ComfyUI update (detached-HEAD safe) ──────────────────────────────────────
function provisioning_update_comfyui() {
    echo "Auto-updating ComfyUI core..."
    if git -C "${COMFYUI_DIR}" rev-parse 2>/dev/null; then
        echo "Found ComfyUI git repo."
        (
            cd "${COMFYUI_DIR}"
            echo "Current ComfyUI revision:"; git rev-parse --short HEAD || true
            echo "Fetching latest ComfyUI refs..."; git fetch origin || true
            if git show-ref --verify --quiet refs/remotes/origin/master; then
                git checkout -B master origin/master || true
            elif git show-ref --verify --quiet refs/remotes/origin/main; then
                git checkout -B main origin/main || true
            else
                echo "WARNING: no origin/master or origin/main. Leaving at current revision."
            fi
            echo "ComfyUI revision after update:"; git rev-parse --short HEAD || true
        ) || echo "WARNING: ComfyUI update failed; continuing so downloads still run."
    else
        echo "ComfyUI not found or not a git repo. Cloning fresh copy..."
        rm -rf "${COMFYUI_DIR}"
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}" || {
            echo "ERROR: Could not clone ComfyUI."; exit 1
        }
    fi
}

# ── Torch (RTX 5090 / cu128-vs-cu130 auto-detect) ────────────────────────────
function provisioning_driver_cuda_int() {
    python - <<'PY' 2>/dev/null || echo 0
import ctypes
v = 0
for lib in ("libcuda.so.1", "libcuda.so"):
    try:
        cuda = ctypes.CDLL(lib); cuda.cuInit(0)
        ver = ctypes.c_int(0); cuda.cuDriverGetVersion(ctypes.byref(ver))
        v = ver.value; break
    except Exception:
        continue
print(v)
PY
}

function provisioning_install_torch_5090() {
    echo
    echo "Installing RTX 5090 (Blackwell / sm_120) PyTorch stack..."
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel || true

    local driver_cuda; driver_cuda="$(provisioning_driver_cuda_int)"
    echo "Detected driver max CUDA version (int): ${driver_cuda}"

    local index_url
    if [[ "$driver_cuda" -ge 13000 ]]; then
        index_url="https://download.pytorch.org/whl/cu130"
        echo "Driver supports CUDA 13.x -> using cu130 wheels."
    else
        index_url="https://download.pytorch.org/whl/cu128"
        echo "Driver < CUDA 13.0 -> using cu128 stable wheels (correct for a 12.8 host)."
    fi

    set +e
    python -m pip install --no-cache-dir --force-reinstall \
        torch torchvision torchaudio --index-url "$index_url"
    local status=$?
    set -e

    if [[ $status -ne 0 ]]; then
        echo "WARNING: torch install from ${index_url} failed. Falling back to cu128 stable."
        python -m pip install --no-cache-dir --force-reinstall \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/cu128 || \
            echo "WARNING: fallback torch install also failed. Continuing with existing torch."
    fi

    provisioning_print_torch_info

    set +e
    python - <<'PY'
import sys
try:
    import torch
except Exception as e:
    print(f"FATAL: cannot import torch: {e}", file=sys.stderr); sys.exit(1)
print("Torch:", torch.__version__, "| CUDA runtime:", torch.version.cuda)
if not torch.cuda.is_available():
    print("FATAL: torch.cuda.is_available() is False after install.", file=sys.stderr)
    print("       Almost always a wheel/driver CUDA mismatch.", file=sys.stderr)
    print("       Check 'nvidia-smi' top-right for the driver's max CUDA version.", file=sys.stderr)
    sys.exit(1)
print("CUDA OK:", torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))
PY
    local cuda_status=$?
    set -e

    if [[ $cuda_status -ne 0 ]]; then
        echo "############################################################"
        echo "# CUDA is NOT available to torch. ComfyUI would crash-loop. #"
        echo "# Stopping provisioning so you can see this clearly.        #"
        echo "############################################################"
        exit 1
    fi
}

function provisioning_print_torch_info() {
    python - <<'PY' || true
import torch
print("Torch:", torch.__version__)
print("Torch CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("Capability:", torch.cuda.get_device_capability(0))
PY
}

# ── apt / pip / nodes ────────────────────────────────────────────────────────
function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -eq 0 ]]; then return 0; fi
    echo "Installing apt packages..."
    sudo apt-get update || true
    sudo apt-get install -y "${APT_PACKAGES[@]}" || echo "WARNING: Some apt packages failed."
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -eq 0 ]]; then return 0; fi
    echo "Installing extra pip packages..."
    python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}" || echo "WARNING: Some pip packages failed."
}

function provisioning_get_nodes() {
    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"; dir="${dir%.git}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"

        if [[ -d "$path" ]]; then
            local auto_update="${AUTO_UPDATE:-true}"
            if [[ "${auto_update,,}" != "false" ]]; then
                printf "Updating node: %s...\n" "$repo"
                (
                    cd "$path"; git fetch origin || true
                    current_branch="$(git branch --show-current || true)"
                    if [[ -n "$current_branch" ]]; then
                        git pull --ff-only || true
                    else
                        echo "Node is detached HEAD; skipping pull."
                    fi
                ) || true
            fi
        else
            printf "Downloading node: %s...\n" "$repo"
            git clone "$repo" "$path" --recursive || { echo "WARNING: Failed to clone $repo"; continue; }
        fi

        if [[ -f "$requirements" ]]; then
            python -m pip install --no-cache-dir -r "$requirements" || echo "WARNING: requirements failed for $repo"
        fi
    done
}

function provisioning_remove_problem_nodes() {
    local cn_dir="${COMFYUI_DIR}/custom_nodes"
    [[ -d "$cn_dir" ]] || return 0
    echo "Removing known-problem custom nodes (TeaCache / SAM3 / Yolo-Cropper)..."
    for name in "${PROBLEM_NODES[@]}"; do
        while IFS= read -r -d '' found; do
            echo "  Removing: $found"; rm -rf "$found"
        done < <(find "$cn_dir" -maxdepth 1 -iname "*${name}*" -print0 2>/dev/null || true)
    done
}

# ── SSH / Jupyter ────────────────────────────────────────────────────────────
function provisioning_setup_ssh() {
    echo "Setting up SSH..."
    service ssh start || true
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    local key="${WANSTUDIO_SSH_KEY:-$SSH_PUBLIC_KEY}"
    if [[ -n "$key" ]]; then
        echo "$key" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "SSH public key installed."
    else
        echo "WARNING: No SSH public key. Set WANSTUDIO_SSH_KEY env var or SSH_PUBLIC_KEY in this script."
    fi
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    service ssh restart || true
    echo "SSH setup complete."
}

function provisioning_setup_jupyter_theme() {
    echo "Setting JupyterLab dark theme..."
    mkdir -p /root/.jupyter/lab/user-settings/@jupyterlab/apputils-extension
    cat > /root/.jupyter/lab/user-settings/@jupyterlab/apputils-extension/themes.jupyterlab-settings << 'EOF'
{
    "theme": "JupyterLab Dark"
}
EOF
    echo "JupyterLab dark theme set."
}

# ── HF / Civitai tokens ──────────────────────────────────────────────────────
function provisioning_check_hf_token() {
    echo
    echo "===== HF TOKEN CHECK ====="
    if [[ -z "${HF_TOKEN:-}" ]]; then
        echo "WARNING: HF_TOKEN not set. Gated repos (e.g. FLUX.2-klein-*) will 401 and be SKIPPED."
    elif provisioning_has_valid_hf_token; then
        echo "HF_TOKEN is set and VALID."
    else
        echo "WARNING: HF_TOKEN is set but did NOT validate (whoami != 200). Gated downloads may fail."
    fi
    echo "=========================="
    echo
}

function provisioning_has_valid_hf_token() {
    [[ -n "${HF_TOKEN:-}" ]] || return 1
    local response
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "https://huggingface.co/api/whoami-v2" \
        -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

# ── Direct model downloads (wget) ────────────────────────────────────────────
function provisioning_get_files() {
    local dir="$1"; shift || true
    local arr=("$@")
    if [[ ${#arr[@]} -eq 0 ]]; then return 0; fi
    mkdir -p "$dir"
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "$url"
        provisioning_download "$url" "$dir"
        printf "\n"
    done
}

function provisioning_download() {
    local url="$1"; local dir="$2"; local auth_token=""
    if [[ -n "${HF_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n "$auth_token" ]]; then
        wget --header="Authorization: Bearer $auth_token" \
            -qnc --content-disposition --show-progress -e dotbytes="4M" -P "$dir" "$url" \
            || echo "WARNING: Download failed: $url"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="4M" -P "$dir" "$url" \
            || echo "WARNING: Download failed: $url"
    fi
}

# ── Google Drive credentials ─────────────────────────────────────────────────
function provisioning_setup_gdrive() {
    local CREDENTIALS_GDRIVE_ID="1akurAPebSquq5vmedB_ZRygoX-KKffRC"
    python -m pip install -q gdown || true

    if [[ -n "${GDRIVE_CREDENTIALS_B64:-}" ]]; then
        echo "Decoding Google Drive credentials from env var..."
        echo "$GDRIVE_CREDENTIALS_B64" | base64 -d > "$GDRIVE_AUTH_FILE"
        chmod 600 "$GDRIVE_AUTH_FILE"
    fi

    if ! python3 -c "import json; json.load(open('$GDRIVE_AUTH_FILE'))" 2>/dev/null; then
        echo "gdrive_auth.json missing or invalid — downloading from Google Drive..."
        gdown --id "$CREDENTIALS_GDRIVE_ID" -O "$GDRIVE_AUTH_FILE" || true
        chmod 600 "$GDRIVE_AUTH_FILE" 2>/dev/null || true
    fi

    if python3 -c "import json; json.load(open('$GDRIVE_AUTH_FILE'))" 2>/dev/null; then
        echo "gdrive_auth.json is valid."
        return 0
    fi
    echo "WARNING: gdrive_auth.json still invalid. GDrive sync (incl. LoRAs) will be skipped."
    return 1
}

# ── Embedded GDrive/HF sync (formerly vlora3.py) ─────────────────────────────
function provisioning_run_gdrive_sync() {
    echo
    echo "===== GDRIVE / HF SYNC (embedded) ====="
    rm -f "$SYNC_FAILED_MARKER"

    # Deps are already in PIP_PACKAGES, but be idempotent if this function is
    # ever run standalone.
    python -m pip install --no-cache-dir --quiet \
        google-api-python-client google-auth huggingface_hub tqdm || true

    set +e
    python3 - <<'PYEOF'
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
from google.oauth2.service_account import Credentials
from huggingface_hub import hf_hub_download
from tqdm import tqdm

# ── Configuration ────────────────────────────────────────────────────────────
SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]
SERVICE_ACCOUNT_FILE = "/workspace/gdrive_auth.json"
HF_TOKEN = os.environ.get("HF_TOKEN", "")
PARALLEL_DOWNLOADS = 8

GDRIVE_LORA_FOLDER_ID = "1U9_NyeTn-1LJH1UoEhOyvnbaUmBmyxDZ"
GDRIVE_LORA_TARGET = "/workspace/ComfyUI/models/loras"

GDRIVE_EXTRA_FOLDERS = [
    ("1cRab0HpIYpgWge3iyT7IT_XyD8sPZuRI", "/workspace/ComfyUI/models/checkpoints"),
    ("1p-zHOOg3NswIOVdqBCZD96DiyAmOYswe", "/workspace/ComfyUI/models/upscale_models"),
    ("10OTIVt0ITyRP0IAXy_w_aq0EDwU_N3Au", "/workspace/ComfyUI/models/clip_vision"),
    ("1_aB1hCyLP61FMX-IcGsNc-HOLhFamfFb", "/workspace"),
]

# GIMM-VFI only. FLUX.2 klein is handled by the bash side (diffusion_models).
HF_MODELS = [
    {
        "repo_id": "Kijai/GIMM-VFI_safetensors",
        "filename": "gimmvfi_f_arb_lpips_fp32.safetensors",
        "output_dir": "/workspace/ComfyUI/models/interpolation/gimm-vfi",
    },
    {
        "repo_id": "Kijai/GIMM-VFI_safetensors",
        "filename": "gimmvfi_r_arb_lpips_fp32.safetensors",
        "output_dir": "/workspace/ComfyUI/models/interpolation/gimm-vfi",
    },
]

FAILURES = []  # (context, name, error) accumulated across the whole run


def get_drive_service():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=SCOPES)
    return build("drive", "v3", credentials=creds)


def service_account_email():
    import json
    try:
        return json.load(open(SERVICE_ACCOUNT_FILE)).get("client_email", "<unknown>")
    except Exception:
        return "<unknown>"


def list_files_in_folder(service, folder_id):
    """Paginated listing — the old version silently capped at ~100 files."""
    query = f"'{folder_id}' in parents and trashed = false"
    files, page_token = [], None
    while True:
        results = service.files().list(
            q=query,
            fields="nextPageToken, files(id, name, size, mimeType)",
            pageSize=1000,
            pageToken=page_token,
        ).execute()
        files.extend(results.get("files", []))
        page_token = results.get("nextPageToken")
        if not page_token:
            break
    return files


def needs_download(f, target_folder):
    """True if the file is absent OR the local size doesn't match Drive's.

    Catches zero-byte / partial files left by interrupted runs, which the old
    filename-only check skipped forever.
    """
    path = os.path.join(target_folder, f["name"])
    if not os.path.exists(path):
        return True
    drive_size = int(f.get("size", 0) or 0)
    if drive_size == 0:
        return False  # no size metadata (rare); trust the existing file
    local_size = os.path.getsize(path)
    if local_size != drive_size:
        tqdm.write(
            f"  ↻ {f['name']}: local {local_size} B != drive {drive_size} B — re-downloading"
        )
        return True
    return False


def download_drive_file(service, file_id, file_name, target_folder, show_progress=True):
    request = service.files().get_media(fileId=file_id)
    file_path = os.path.join(target_folder, file_name)
    tmp_path = file_path + ".part"

    meta = service.files().get(fileId=file_id, fields="size").execute()
    total = int(meta.get("size", 0) or 0)
    total_mb = round(total / 1048576, 1)

    with open(tmp_path, "wb") as fh:
        downloader = MediaIoBaseDownload(fh, request, chunksize=16 * 1024 * 1024)
        if show_progress:
            with tqdm(
                total=total, unit="B", unit_scale=True, unit_divisor=1024,
                desc=f"  {file_name[:40]}", colour="green", leave=True,
            ) as pbar:
                done, downloaded = False, 0
                while not done:
                    status, done = downloader.next_chunk()
                    new = int(status.resumable_progress) - downloaded
                    pbar.update(new)
                    downloaded += new
        else:
            done = False
            while not done:
                _, done = downloader.next_chunk()

    # Verify size before promoting .part -> final. A wrong-size download is a
    # failure, not a success.
    if total > 0 and os.path.getsize(tmp_path) != total:
        got = os.path.getsize(tmp_path)
        os.remove(tmp_path)
        raise IOError(f"size mismatch after download: got {got} B, expected {total} B")
    os.replace(tmp_path, file_path)

    if not show_progress:
        print(f"  ✓ {file_name} ({total_mb} MB)")


def sync_drive_folder_recursive(service, folder_id, target_folder, workers=PARALLEL_DOWNLOADS):
    os.makedirs(target_folder, exist_ok=True)
    all_files = list_files_in_folder(service, folder_id)

    files = [f for f in all_files if f.get("mimeType") != "application/vnd.google-apps.folder"]
    subfolders = [f for f in all_files if f.get("mimeType") == "application/vnd.google-apps.folder"]

    # ALWAYS print, even for empty folders — an unshared folder looks empty.
    print(f"  Drive folder {folder_id} -> {target_folder}")
    print(f"    {len(files)} files | {len(subfolders)} subfolders found in Drive")
    if not files and not subfolders:
        print(f"    ⚠️  ZERO items. If this folder is not actually empty, it is probably")
        print(f"    ⚠️  not shared with the service account: {service_account_email()}")

    to_download = [f for f in files if needs_download(f, target_folder)]
    to_skip = [f for f in files if f not in to_download]
    print(f"    {len(to_skip)} already local (size-verified) | {len(to_download)} to download")

    for f in to_skip:
        tqdm.write(f"  ✓ {f['name']}")

    def _download(f):
        try:
            svc = get_drive_service()  # thread-local service
            download_drive_file(svc, f["id"], f["name"], target_folder,
                                show_progress=(workers == 1))
            return f["name"], None
        except Exception as e:
            return f["name"], str(e)

    if to_download:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {executor.submit(_download, f): f["name"] for f in to_download}
            for future in as_completed(futures):
                name, error = future.result()
                if error:
                    tqdm.write(f"  ✗ ERROR {name}: {error}")
                    FAILURES.append((target_folder, name, error))
                else:
                    tqdm.write(f"  ✓ {name}")

    for subfolder in subfolders:
        sub_path = os.path.join(target_folder, subfolder["name"])
        print(f"  📁 {subfolder['name']}/")
        sync_drive_folder_recursive(service, subfolder["id"], sub_path, workers)


def download_hf_model(repo_id, filename, output_dir, token):
    os.makedirs(output_dir, exist_ok=True)
    dest = os.path.join(output_dir, filename)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print(f"  ✓ {filename} (already exists)")
        return
    print(f"  Downloading {filename}...")
    try:
        hf_hub_download(
            repo_id=repo_id, filename=filename, token=token or None,
            repo_type="model", local_dir=output_dir,
        )
        print(f"  ✓ {filename} done.")
    except Exception as e:
        print(f"  ✗ ERROR: {filename}: {e}")
        FAILURES.append((output_dir, filename, str(e)))
        if "401" in str(e) or "403" in str(e):
            print("    Tip: Check HF_TOKEN is valid and you have access to this repo.")


def main():
    print()
    print("═" * 50)
    print("  WanStudio Model Sync (embedded)")
    print("  Service account:", service_account_email())
    print("═" * 50)

    try:
        service = get_drive_service()
    except Exception as e:
        print(f"FATAL: could not build Drive service: {e}")
        sys.exit(2)

    print("\n── LoRAs (Google Drive) ──")
    try:
        sync_drive_folder_recursive(service, GDRIVE_LORA_FOLDER_ID, GDRIVE_LORA_TARGET)
    except Exception as e:
        print(f"  ✗ FATAL syncing LoRA folder: {e}")
        FAILURES.append((GDRIVE_LORA_TARGET, "<folder listing>", str(e)))

    print("\n── Extra Folders (Google Drive) ──")
    for folder_id, target_dir in GDRIVE_EXTRA_FOLDERS:
        print(f"\n  {target_dir}")
        try:
            sync_drive_folder_recursive(service, folder_id, target_dir)
        except Exception as e:
            print(f"  ✗ FATAL syncing {target_dir}: {e}")
            FAILURES.append((target_dir, "<folder listing>", str(e)))

    print("\n── HuggingFace Models ──")
    for model in HF_MODELS:
        print(f"\n  [{model['repo_id']}]")
        download_hf_model(model["repo_id"], model["filename"],
                          model["output_dir"], HF_TOKEN)

    # LoRA sanity count — the headline number.
    lora_count = 0
    if os.path.isdir(GDRIVE_LORA_TARGET):
        for _root, _dirs, fnames in os.walk(GDRIVE_LORA_TARGET):
            lora_count += sum(1 for n in fnames if not n.endswith(".part"))

    print()
    print("═" * 50)
    if FAILURES:
        print(f"  ⚠️  SYNC FINISHED WITH {len(FAILURES)} FAILURE(S):")
        for ctx, name, err in FAILURES:
            print(f"    ✗ [{ctx}] {name}: {err}")
        print(f"  LoRA files on disk: {lora_count}")
        print("═" * 50 + "\n")
        sys.exit(1)
    print(f"  ✅ All downloads complete. LoRA files on disk: {lora_count}")
    print("═" * 50 + "\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
PYEOF
    local sync_status=$?
    set -e

    if [[ $sync_status -ne 0 ]]; then
        touch "$SYNC_FAILED_MARKER"
        echo "##############################################################"
        echo "# ⚠️  GDRIVE/HF SYNC FAILED (exit $sync_status).              "
        echo "#    Some LoRAs/models are MISSING. See errors above.         "
        echo "#    Marker written: $SYNC_FAILED_MARKER                      "
        echo "#    Provisioning continues so the instance is still usable.  "
        echo "##############################################################"
    else
        echo "GDrive/HF sync completed cleanly."
    fi
    echo "===== END GDRIVE / HF SYNC ====="
    echo
}

# ── Verification / info ──────────────────────────────────────────────────────
function provisioning_verify_downloads() {
    echo
    echo "===== DOWNLOADED MODEL FILES ====="
    local mdir="${COMFYUI_DIR}/models"
    if [[ -d "$mdir" ]]; then
        find "$mdir" -type f \( -name "*.safetensors" -o -name "*.sft" -o -name "*.pth" -o -name "*.gguf" \) \
            -printf "%10s  %p\n" 2>/dev/null | sort -k2 || true
        echo "----------------------------------"
        local lora_dir="${COMFYUI_DIR}/models/loras"
        if [[ -d "$lora_dir" ]]; then
            local lcount
            lcount=$(find "$lora_dir" -type f ! -name "*.part" | wc -l)
            echo "LoRA files in ${lora_dir}: ${lcount}"
        else
            echo "⚠️  No loras directory at ${lora_dir}"
        fi
        if [[ -f "$SYNC_FAILED_MARKER" ]]; then
            echo "⚠️  GDrive sync failure marker present: $SYNC_FAILED_MARKER"
        fi
        echo "Total models dir size:"; du -sh "$mdir" 2>/dev/null || true
    else
        echo "WARNING: ${mdir} does not exist — no models downloaded."
    fi
    echo "=================================="
    echo
}

function provisioning_check_disk_space() {
    echo
    echo "===== DISK SPACE ====="
    df -h "${WORKSPACE}" || true
    echo "Tip: large model set. Use --disk 180."
    echo "======================"
    echo
}

function provisioning_print_system_info() {
    echo
    echo "===== SYSTEM INFO ====="
    nvidia-smi || true
    provisioning_print_torch_info || true
    echo "ComfyUI dir: ${COMFYUI_DIR}"
    echo "Python: $(which python)"
    echo "PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF}"
    echo "======================="
    echo
}

function provisioning_print_oom_hint() {
    echo
    echo "===== WAN 2.2 OOM NOTES ====="
    echo "The earlier OOM was the two-expert (high+low noise) swap failing on"
    echo "allocator FRAGMENTATION, not raw VRAM. This run sets:"
    echo "  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
    echo "If you still OOM, launch ComfyUI with:"
    echo "  --reserve-vram 1.0 --disable-smart-memory"
    echo "or switch Wan to GGUF (Q8 / Q5_K_M) via ComfyUI-GGUF."
    echo "============================="
    echo
}

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#   WanStudio RTX 5090 Provisioning (v3)     #\n"
    printf "#                                            #\n"
    printf "#  single-file: torch + nodes + models +     #\n"
    printf "#  GDrive LoRA sync (embedded) + SSH         #\n"
    printf "#                                            #\n"
    printf "##############################################\n\n"
}

function provisioning_print_end() {
    local end_time; end_time=$(date +%s)
    local elapsed=$((end_time - PROVISIONING_START_TIME))
    local mins=$((elapsed / 60)); local secs=$((elapsed % 60))
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -f "$SYNC_FAILED_MARKER" ]]; then
        echo "⚠️  Provisioning finished in ${mins}m ${secs}s WITH SYNC FAILURES"
        echo "   (see GDRIVE/HF SYNC section above — some LoRAs/models missing)"
    else
        echo "✅ Provisioning complete — took ${mins}m ${secs}s"
    fi
    echo "Application will start now"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
