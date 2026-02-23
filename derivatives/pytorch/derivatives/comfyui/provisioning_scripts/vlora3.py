import sys
import subprocess
import pkg_resources

# ─────────────────────────────────────────────
# Auto-install missing packages
# ─────────────────────────────────────────────
required = {"google-api-python-client", "google-auth", "gdown", "huggingface_hub", "tqdm"}
installed = {pkg.key for pkg in pkg_resources.working_set}
missing = required - installed
if missing:
    subprocess.check_call([sys.executable, "-m", "pip", "install", *missing])

import os
import io
from concurrent.futures import ThreadPoolExecutor, as_completed
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
from google.oauth2.service_account import Credentials
from huggingface_hub import hf_hub_download
from tqdm import tqdm

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
SCOPES = ['https://www.googleapis.com/auth/drive.readonly']
SERVICE_ACCOUNT_FILE = '/workspace/gdrive_auth.json'

HF_TOKEN = os.environ.get("HF_TOKEN", "")

PARALLEL_DOWNLOADS = 8  # concurrent downloads

# Google Drive folder IDs
GDRIVE_LORA_FOLDER_ID = "1U9_NyeTn-1LJH1UoEhOyvnbaUmBmyxDZ"
GDRIVE_LORA_TARGET = "/workspace/ComfyUI/models/loras"

GDRIVE_EXTRA_FOLDERS = [
    ("1cRab0HpIYpgWge3iyT7IT_XyD8sPZuRI", "/workspace/ComfyUI/models/checkpoints"),
    ("1p-zHOOg3NswIOVdqBCZD96DiyAmOYswe", "/workspace/ComfyUI/models/upscale_models"),
    ("10OTIVt0ITyRP0IAXy_w_aq0EDwU_N3Au", "/workspace/ComfyUI/models/clip_vision"),
    ("1_aB1hCyLP61FMX-IcGsNc-HOLhFamfFb", "/workspace"),
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
    results = service.files().list(q=query, fields="files(id, name, size)").execute()
    return results.get('files', [])

def download_drive_file(service, file_id, file_name, target_folder):
    request = service.files().get_media(fileId=file_id)
    file_path = os.path.join(target_folder, file_name)

    meta = service.files().get(fileId=file_id, fields="size").execute()
    total = int(meta.get("size", 0))

    with open(file_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request, chunksize=16 * 1024 * 1024)
        with tqdm(
            total=total,
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            desc=f"  {file_name[:40]}",
            colour="green",
            leave=True,
        ) as pbar:
            done = False
            downloaded = 0
            while not done:
                status, done = downloader.next_chunk()
                new = int(status.resumable_progress) - downloaded
                pbar.update(new)
                downloaded += new

def sync_drive_folder_parallel(service, folder_id, target_folder, workers=PARALLEL_DOWNLOADS):
    """Parallel sync — downloads multiple files simultaneously."""
    os.makedirs(target_folder, exist_ok=True)
    drive_files = list_files_in_folder(service, folder_id)
    local_files = set(os.listdir(target_folder))

    to_download = [f for f in drive_files if f['name'] not in local_files]
    to_skip = [f for f in drive_files if f['name'] in local_files]

    print(f"  {len(drive_files)} in Drive | {len(to_skip)} already local | {len(to_download)} to download")

    for f in to_skip:
        tqdm.write(f"  ✓ {f['name']}")

    if not to_download:
        return

    def _download(f):
        try:
            # Each thread needs its own service instance
            svc = get_drive_service()
            download_drive_file(svc, f['id'], f['name'], target_folder)
            return f['name'], None
        except Exception as e:
            return f['name'], str(e)

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(_download, f): f['name'] for f in to_download}
        for future in as_completed(futures):
            name, error = future.result()
            if error:
                tqdm.write(f"  ✗ ERROR {name}: {error}")

# ─────────────────────────────────────────────
# HuggingFace helpers
# ─────────────────────────────────────────────
def download_hf_model(repo_id, filename, output_dir, token):
    os.makedirs(output_dir, exist_ok=True)
    dest = os.path.join(output_dir, filename)
    if os.path.exists(dest):
        print(f"  ✓ {filename} (already exists)")
        return
    print(f"  Downloading {filename}...")
    try:
        hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            token=token,
            repo_type="model",
            local_dir=output_dir,
            local_dir_use_symlinks=False,
        )
        print(f"  ✓ {filename} done.")
    except Exception as e:
        print(f"  ✗ ERROR: {filename}: {e}")
        if "401" in str(e) or "403" in str(e):
            print("    Tip: Check HF_TOKEN is valid and you have access to this repo.")

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
if __name__ == "__main__":

    print("\n" + "═" * 50)
    print("  WanStudio Model Sync")
    print("═" * 50)

    service = get_drive_service()

    # 1. LoRAs
    print("\n── LoRAs (Google Drive) ──")
    sync_drive_folder_parallel(service, GDRIVE_LORA_FOLDER_ID, GDRIVE_LORA_TARGET)

    # 2. Extra folders — all via parallel service account API
    print("\n── Extra Folders (Google Drive) ──")
    for folder_id, target_dir in GDRIVE_EXTRA_FOLDERS:
        print(f"\n  {target_dir}")
        sync_drive_folder_parallel(service, folder_id, target_dir)

    # 3. HuggingFace models
    print("\n── HuggingFace Models ──")
    for model in HF_MODELS:
        print(f"\n  [{model['repo_id']}]")
        download_hf_model(
            repo_id=model["repo_id"],
            filename=model["filename"],
            output_dir=model["output_dir"],
            token=HF_TOKEN,
        )

    print("\n" + "═" * 50)
    print("  ✅ All downloads complete.")
    print("═" * 50 + "\n")
