import sys
import subprocess
import pkg_resources

# ─────────────────────────────────────────────
# Auto-install missing packages
# ─────────────────────────────────────────────
required = {"google-api-python-client", "google-auth", "gdown", "huggingface_hub"}
installed = {pkg.key for pkg in pkg_resources.working_set}
missing = required - installed
if missing:
    subprocess.check_call([sys.executable, "-m", "pip", "install", *missing])

import os
import io
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
from google.oauth2.service_account import Credentials
import gdown
from huggingface_hub import hf_hub_download

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
SCOPES = ['https://www.googleapis.com/auth/drive.readonly']
SERVICE_ACCOUNT_FILE = 'credentials.json'

HF_TOKEN = os.environ.get("HF_TOKEN", "")

# Google Drive folder IDs
GDRIVE_LORA_FOLDER_ID = "1U9_NyeTn-1LJH1UoEhOyvnbaUmBmyxDZ"
GDRIVE_LORA_TARGET = "/workspace/ComfyUI/models/loras"

GDRIVE_EXTRA_FOLDERS = [
    ("1cRab0HpIYpgWge3iyT7IT_XyD8sPZuRI", "/workspace/ComfyUI/models/checkpoints"),
    ("1p-zHOOg3NswIOVdqBCZD96DiyAmOYswe", "/workspace/ComfyUI/models/upscale_models"),
    ("10OTIVt0ITyRP0IAXy_w_aq0EDwU_N3Au", "/workspace/ComfyUI/models/clip_vision"),
]

# HuggingFace models
HF_MODELS = [
    {
        "repo_id": "black-forest-labs/FLUX.2-klein-9B",
        "filename": "flux-2-klein-9b.safetensors",
        "output_dir": "/workspace/ComfyUI/models/unet",
    },
    {
        "repo_id": "black-forest-labs/FLUX.2-klein-base-9b-fp8",
        "filename": "flux-2-klein-base-9b-fp8.safetensors",
        "output_dir": "/workspace/ComfyUI/models/unet",
    },
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

# ─────────────────────────────────────────────
# Google Drive helpers
# ─────────────────────────────────────────────
def get_drive_service():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=SCOPES)
    return build('drive', 'v3', credentials=creds)

def list_files_in_folder(service, folder_id):
    query = f"'{folder_id}' in parents and trashed = false"
    results = service.files().list(q=query, fields="files(id, name)").execute()
    return results.get('files', [])

def download_drive_file(service, file_id, file_name, target_folder):
    request = service.files().get_media(fileId=file_id)
    file_path = os.path.join(target_folder, file_name)
    with open(file_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request)
        done = False
        while not done:
            status, done = downloader.next_chunk()
            print(f"  {file_name}: {int(status.progress() * 100)}%", flush=True)
    print(f"  -> {file_name} downloaded.")

def sync_drive_folder(service, folder_id, target_folder):
    """Smart sync — only downloads files not already present locally."""
    os.makedirs(target_folder, exist_ok=True)
    drive_files = list_files_in_folder(service, folder_id)
    local_files = set(os.listdir(target_folder))
    print(f"  {len(drive_files)} files in Drive, {len(local_files)} files local")
    for f in drive_files:
        if f['name'] not in local_files:
            print(f"  Downloading: {f['name']}")
            download_drive_file(service, f['id'], f['name'], target_folder)
        else:
            print(f"  Skipping (exists): {f['name']}")

# ─────────────────────────────────────────────
# HuggingFace helpers
# ─────────────────────────────────────────────
def download_hf_model(repo_id, filename, output_dir, token):
    os.makedirs(output_dir, exist_ok=True)
    dest = os.path.join(output_dir, filename)
    if os.path.exists(dest):
        print(f"  Skipping (exists): {filename}")
        return
    print(f"  Downloading {filename} from {repo_id} ...")
    try:
        downloaded = hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            token=token,
            repo_type="model",
            local_dir=output_dir,
            local_dir_use_symlinks=False,
        )
        print(f"  -> Downloaded: {downloaded}")
    except Exception as e:
        print(f"  ERROR downloading {filename}: {e}")
        if "401" in str(e) or "403" in str(e):
            print("  Tip: Check your HF_TOKEN is valid and you have access to this repo.")

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
if __name__ == "__main__":

    # 1. LoRAs — smart sync via service account
    print("\n=== Syncing LoRAs (service account) ===")
    service = get_drive_service()
    sync_drive_folder(service, GDRIVE_LORA_FOLDER_ID, GDRIVE_LORA_TARGET)

    # 2. Extra folders — bulk sync via gdown
    print("\n=== Syncing extra folders (gdown) ===")
    for folder_id, target_dir in GDRIVE_EXTRA_FOLDERS:
        print(f"\n  -> {target_dir}")
        os.makedirs(target_dir, exist_ok=True)
        gdown.download_folder(id=folder_id, output=target_dir, quiet=False)

    # 3. HuggingFace models
    print("\n=== Downloading HuggingFace models ===")
    for model in HF_MODELS:
        print(f"\n  {model['filename']}")
        download_hf_model(
            repo_id=model["repo_id"],
            filename=model["filename"],
            output_dir=model["output_dir"],
            token=HF_TOKEN,
        )

    print("\n✅ All downloads complete.")
