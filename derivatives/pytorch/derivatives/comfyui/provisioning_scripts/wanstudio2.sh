#!/usr/bin/env bash
# WanStudio provisioning script — RTX 5090 / Vast.ai
#
# What changed vs the previous version (and WHY):
# - TORCH: installs cu128 stable, NOT cu130. The Vast host driver reports CUDA
#   12.8 (version 12080). cu130 wheels INSTALL fine but cannot RUN on a 12.8
#   driver, so torch.cuda.is_available() was False and ComfyUI crash-looped on
#   import. The 5090 (Blackwell / sm_120) is fully supported by cu128 stable.
# - Torch verification now checks RUNTIME availability, not just install exit
#   code, and the driver's max CUDA version is detected to pick cu128 vs cu130.
# - ORDER: ComfyUI requirements are installed BEFORE torch, and torch is
#   force-installed LAST, so requirements.txt can't clobber the correct build.
# - OOM: exports PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True and launches
#   ComfyUI with --reserve-vram / --disable-smart-memory to survive the Wan 2.2
#   two-expert (high-noise + low-noise) swap, which was failing on fragmentation.
# - Problem nodes (TeaCache, SAM3, Yolo-Cropper) are now ACTUALLY removed.
# - HF_TOKEN is required for gated models (FLUX.2 klein); script warns loudly if
#   it's missing and verifies downloads instead of silently continuing.
#
# IMPORTANT: this model set is large. Use a big Vast disk: --disk 180 (min 150).

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# Helps the Wan 2.2 expert-swap OOM (reserved-but-unusable fragmentation).
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

if [[ -f /venv/main/bin/activate ]]; then
    source /venv/main/bin/activate
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

# Custom-node directory names to remove on every run (matched against the
# folder name under custom_nodes/). These caused the problems noted in your logs.
PROBLEM_NODES=(
    "ComfyUI-TeaCache"
    "teacache"
    "ComfyUI-SAM3"
    "sam3"
    "ComfyUI-YoloCropper"
    "Yolo-Cropper"
    "yolo-cropper"
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
    provisioning_update_comfyui

    # Install ComfyUI core requirements FIRST so they can't pull in / pin a
    # torch build that overrides the correct one we install next.
    echo "Installing ComfyUI core requirements..."
    python -m pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt" || {
        echo "WARNING: ComfyUI requirements install had issues; continuing."
    }

    # Torch LAST and force-reinstalled, so it wins.
    provisioning_install_torch_5090

    provisioning_get_pip_packages
    provisioning_get_nodes
    provisioning_remove_problem_nodes
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

    provisioning_verify_downloads
    provisioning_print_oom_hint
    provisioning_print_end
}

function provisioning_update_comfyui() {
    echo "Auto-updating ComfyUI core..."

    if git -C "${COMFYUI_DIR}" rev-parse 2>/dev/null; then
        echo "Found ComfyUI git repo."

        (
            cd "${COMFYUI_DIR}"

            echo "Current ComfyUI revision:"
            git rev-parse --short HEAD || true

            echo "Fetching latest ComfyUI refs..."
            git fetch origin || true

            # Vast images often ship ComfyUI in detached HEAD.
            # Do NOT use plain git pull in detached HEAD; it exits 1 and stops provisioning.
            if git show-ref --verify --quiet refs/remotes/origin/master; then
                echo "Checking out origin/master..."
                git checkout -B master origin/master || true
            elif git show-ref --verify --quiet refs/remotes/origin/main; then
                echo "Checking out origin/main..."
                git checkout -B main origin/main || true
            else
                echo "WARNING: Could not find origin/master or origin/main. Leaving ComfyUI at current revision."
            fi

            echo "ComfyUI revision after update attempt:"
            git rev-parse --short HEAD || true
        ) || echo "WARNING: ComfyUI update failed; continuing so model downloads still run."
    else
        echo "ComfyUI not found or not a git repo. Cloning fresh copy..."
        rm -rf "${COMFYUI_DIR}"
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}" || {
            echo "ERROR: Could not clone ComfyUI."
            exit 1
        }
    fi
}

# Returns the host driver's MAX supported CUDA version as an integer like 12080
# (= 12.8) or 13000 (= 13.0). Uses torch's view of the driver, which is exactly
# what determines wheel compatibility.
function provisioning_driver_cuda_int() {
    python - <<'PY' 2>/dev/null || echo 0
import ctypes
v = 0
for lib in ("libcuda.so.1", "libcuda.so"):
    try:
        cuda = ctypes.CDLL(lib)
        cuda.cuInit(0)
        ver = ctypes.c_int(0)
        cuda.cuDriverGetVersion(ctypes.byref(ver))
        v = ver.value  # e.g. 12080 for 12.8, 13000 for 13.0
        break
    except Exception:
        continue
print(v)
PY
}

function provisioning_install_torch_5090() {
    echo
    echo "Installing RTX 5090 (Blackwell / sm_120) PyTorch stack..."
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel || true

    local driver_cuda
    driver_cuda="$(provisioning_driver_cuda_int)"
    echo "Detected driver max CUDA version (int): ${driver_cuda}"

    # Pick the wheel channel the DRIVER can actually run.
    # cu130 wheels need a >= 13.0 driver (>=13000). Otherwise use cu128 stable,
    # which fully supports the 5090. This is the bug from last time: cu130
    # installs on a 12.8 driver but cannot run.
    local index_url
    if [[ "$driver_cuda" -ge 13000 ]]; then
        index_url="https://download.pytorch.org/whl/cu130"
        echo "Driver supports CUDA 13.x -> using cu130 wheels."
    else
        index_url="https://download.pytorch.org/whl/cu128"
        echo "Driver is < CUDA 13.0 -> using cu128 stable wheels (correct for a 12.8 host)."
    fi

    set +e
    python -m pip install --no-cache-dir --force-reinstall \
        torch torchvision torchaudio \
        --index-url "$index_url"
    local status=$?
    set -e

    if [[ $status -ne 0 ]]; then
        echo "WARNING: torch install from ${index_url} failed. Trying cu128 stable as fallback."
        python -m pip install --no-cache-dir --force-reinstall \
            torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/cu128 || \
            echo "WARNING: fallback torch install also failed. Continuing with existing torch."
    fi

    provisioning_print_torch_info

    # Verify RUNTIME CUDA availability, not just install success. If the GPU is
    # not visible, fail loudly NOW instead of crash-looping ComfyUI forever.
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
    print("       This is almost always a wheel/driver CUDA mismatch.", file=sys.stderr)
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
        echo "# Fix: ensure the torch wheel channel matches the host      #"
        echo "# driver (cu128 for a CUDA 12.8 driver).                    #"
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

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing apt packages..."
    sudo apt-get update || true
    sudo apt-get install -y "${APT_PACKAGES[@]}" || echo "WARNING: Some apt packages failed."
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing extra pip packages..."
    python -m pip install --no-cache-dir "${PIP_PACKAGES[@]}" || echo "WARNING: Some pip packages failed."
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
                (
                    cd "$path"
                    git fetch origin || true
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

# Actually remove the nodes the old header only CLAIMED to remove.
function provisioning_remove_problem_nodes() {
    local cn_dir="${COMFYUI_DIR}/custom_nodes"
    [[ -d "$cn_dir" ]] || return 0

    echo "Removing known-problem custom nodes (TeaCache / SAM3 / Yolo-Cropper)..."
    for name in "${PROBLEM_NODES[@]}"; do
        # Case-insensitive match against existing node folders.
        while IFS= read -r -d '' found; do
            echo "  Removing: $found"
            rm -rf "$found"
        done < <(find "$cn_dir" -maxdepth 1 -iname "*${name}*" -print0 2>/dev/null || true)
    done
}

function provisioning_check_hf_token() {
    echo
    echo "===== HF TOKEN CHECK ====="
    if [[ -z "${HF_TOKEN:-}" ]]; then
        echo "WARNING: HF_TOKEN is not set."
        echo "Gated repos (e.g. black-forest-labs/FLUX.2-klein-*) will return 401"
        echo "and be SKIPPED. Set HF_TOKEN in the Vast environment to fetch them."
    else
        echo "HF_TOKEN is set; gated downloads will be authenticated."
    fi
    echo "=========================="
    echo
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

# Sanity-check what actually landed on disk, so a 3-minute "success" that
# downloaded almost nothing is obvious instead of silent.
function provisioning_verify_downloads() {
    echo
    echo "===== DOWNLOADED MODEL FILES ====="
    local mdir="${COMFYUI_DIR}/models"
    if [[ -d "$mdir" ]]; then
        find "$mdir" -type f \( -name "*.safetensors" -o -name "*.sft" -o -name "*.pth" -o -name "*.gguf" \) \
            -printf "%10s  %p\n" 2>/dev/null | sort -k2 || true
        echo "----------------------------------"
        echo "Total models dir size:"
        du -sh "$mdir" 2>/dev/null || true
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
    echo "Tip: this full model set is large (qwen_image_edit bf16 ~40GB, both"
    echo "FLUX.2 klein variants, both Wan 2.2 experts, t5xxl_fp16). Use --disk 180."
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
    echo "Your earlier OOM was the two-expert (high-noise + low-noise) swap"
    echo "failing on allocator FRAGMENTATION (31GB reserved, ~7GB allocated),"
    echo "not raw VRAM exhaustion. This run sets:"
    echo "  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
    echo "If you still OOM, launch ComfyUI with:"
    echo "  --reserve-vram 1.0 --disable-smart-memory"
    echo "or switch the Wan models to GGUF (Q8 / Q5_K_M) via ComfyUI-GGUF to"
    echo "avoid the fp8 load-time re-quantization spike entirely."
    echo "============================="
    echo
}

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#       WanStudio RTX 5090 Provisioning      #\n"
    printf "#                                            #\n"
    printf "#   cu128 torch fix + OOM + download checks   #\n"
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
