#!/usr/bin/env python3
"""fetch_models.py — idempotent model + LoRA fetcher for the Vast ComfyUI instances.

Usage:
  python3 fetch_models.py [manifest] [--group h3,swap,qwen,essential] [--dry-run]

Manifest sources (see models.manifest):
  hf:<owner>/<repo>/<path>         exact file in a Hugging Face repo
  hf:<owner>/<repo>/**/<filename>  search the repo for that filename
  gdrive:<folder_id>               every file in a Google Drive folder (service account)
  https://...                      plain URL

- Skips files that already exist; a file that exists anywhere else under the models
  trees is symlinked instead of downloaded again.
- Models root: $MODELS_DIR, else /workspace/ComfyUI/models (where the image and the
  Klein fetch put things), else /ComfyUI/models. Both trees are searched for existing files.
- Secrets come from the environment, or from PID 1's environment (the Vast template env
  isn't inherited by ssh shells): HF_TOKEN, GDRIVE_CREDENTIALS_B64.
- Downloads 3 at a time; one line per file; exit code 1 if anything failed.
"""
import argparse
import base64
import json
import os
import shutil
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TREES = ["/workspace/ComfyUI/models", "/ComfyUI/models"]


def models_root():
    if os.environ.get("MODELS_DIR"):
        return os.environ["MODELS_DIR"]
    for p in TREES:
        if os.path.isdir(p):
            return p
    sys.exit("no ComfyUI models dir found (set MODELS_DIR)")


def env(name):
    if os.environ.get(name):
        return os.environ[name]
    try:
        for kv in open("/proc/1/environ", "rb").read().split(b"\0"):
            if kv.startswith(name.encode() + b"="):
                return kv.split(b"=", 1)[1].decode()
    except OSError:
        pass
    return None


def parse(manifest, groups):
    items = []
    for raw in open(manifest):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        tag = parts[-1][1:] if parts[-1].startswith("@") else None
        if tag:
            parts = parts[:-1]
        if groups and tag not in groups:
            continue
        items.append((parts[0], parts[1].split(",")))
    return items


# ── Hugging Face ────────────────────────────────────────────────────────────
_tree_cache = {}


def resolve_hf(spec, token):
    from huggingface_hub import list_repo_files
    owner, repo, path = spec[3:].split("/", 2)
    rid = f"{owner}/{repo}"
    if path.startswith("**/"):
        name = path[3:]
        if rid not in _tree_cache:
            _tree_cache[rid] = list_repo_files(rid, token=token)
        hits = [p for p in _tree_cache[rid] if p.split("/")[-1] == name]
        if not hits:
            raise FileNotFoundError(f"{name} not found in {rid}")
        path = sorted(hits, key=len)[0]
    return rid, path


def link_aliases(M, main, aliases, dry):
    for alias in aliases:
        a = os.path.join(M, alias)
        if alias.endswith("/") or not alias.endswith(".safetensors"):
            a = os.path.join(a, os.path.basename(main))
        if not os.path.lexists(a) and not dry:
            os.makedirs(os.path.dirname(a), exist_ok=True)
            os.symlink(main, a)


def fetch_file(src, dests, M, have, dry):
    main = os.path.join(M, dests[0])
    name = os.path.basename(main)
    try:
        if os.path.exists(main):
            status = "ok     "
        elif name in have and os.path.realpath(have[name]) != os.path.realpath(main):
            if not dry:
                os.makedirs(os.path.dirname(main), exist_ok=True)
                os.symlink(have[name], main)
            status = "linked "
        elif dry:
            status = "WOULD GET"
        else:
            os.makedirs(os.path.dirname(main), exist_ok=True)
            tmp = main + ".part"
            token = env("HF_TOKEN")
            if src.startswith("hf:"):
                from huggingface_hub import hf_hub_download
                rid, path = resolve_hf(src, token)
                p = hf_hub_download(rid, path, token=token, cache_dir="/workspace/.hfcache")
                shutil.move(os.path.realpath(p), tmp)
            else:
                hdr = {"Authorization": f"Bearer {token}"} if token and "huggingface.co" in src else {}
                with urllib.request.urlopen(urllib.request.Request(src, headers=hdr)) as r, open(tmp, "wb") as f:
                    shutil.copyfileobj(r, f, 1 << 24)
            os.replace(tmp, main)
            status = "fetched"
        link_aliases(M, main, dests[1:], dry)
        return True, f"{status}  {dests[0]}"
    except Exception as e:
        return False, f"FAILED   {dests[0]}  ({e})"


# ── Google Drive (service account) ──────────────────────────────────────────
def drive_service():
    from google.oauth2.service_account import Credentials
    from googleapiclient.discovery import build
    auth = "/workspace/gdrive_auth.json"
    if not (os.path.exists(auth) and os.path.getsize(auth) > 0):
        b64 = env("GDRIVE_CREDENTIALS_B64")
        if not b64:
            raise RuntimeError("GDRIVE_CREDENTIALS_B64 not set and /workspace/gdrive_auth.json missing")
        with open(auth, "wb") as f:
            f.write(base64.b64decode(b64))
        os.chmod(auth, 0o600)
    creds = Credentials.from_service_account_file(auth, scopes=["https://www.googleapis.com/auth/drive.readonly"])
    return build("drive", "v3", credentials=creds, cache_discovery=False), json.load(open(auth)).get("client_email")


def fetch_gdrive(src, dests, M, dry):
    from googleapiclient.http import MediaIoBaseDownload
    folder = src.split(":", 1)[1]
    lines, ok = [], True
    try:
        svc, sa = drive_service()
        files, token = [], None
        while True:
            r = svc.files().list(q=f"'{folder}' in parents and trashed=false",
                                 fields="nextPageToken, files(id,name,size,mimeType)",
                                 pageSize=200, pageToken=token,
                                 supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
            files += r.get("files", [])
            token = r.get("nextPageToken")
            if not token:
                break
        files = [f for f in files if f["mimeType"] != "application/vnd.google-apps.folder"]
        if not files:
            return False, [f"FAILED   gdrive:{folder}  (empty, or not shared with {sa})"]
        for f in files:
            out = os.path.join(M, dests[0], f["name"])
            rel = os.path.join(dests[0], f["name"])
            if os.path.exists(out) and str(os.path.getsize(out)) == f.get("size"):
                lines.append(f"ok       {rel}")
            elif dry:
                lines.append(f"WOULD GET {rel}")
            else:
                os.makedirs(os.path.dirname(out), exist_ok=True)
                tmp = out + ".part"
                with open(tmp, "wb") as fh:
                    dl = MediaIoBaseDownload(fh, svc.files().get_media(fileId=f["id"], supportsAllDrives=True),
                                             chunksize=64 << 20)
                    done = False
                    while not done:
                        _, done = dl.next_chunk()
                os.replace(tmp, out)
                lines.append(f"fetched  {rel}")
            link_aliases(M, out, [d.rstrip("/") + "/" for d in dests[1:]], dry)
    except Exception as e:
        ok = False
        lines.append(f"FAILED   gdrive:{folder}  ({e})")
    return ok, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest", nargs="?",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.manifest"))
    ap.add_argument("--group", default="", help="comma list, e.g. h3,qwen (default: every uncommented line)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    M = models_root()
    items = parse(a.manifest, set(filter(None, a.group.split(","))))
    have = {}
    for t in TREES:
        for r, _, fs in os.walk(t, followlinks=True):
            for f in fs:
                if f.endswith(".safetensors"):
                    have.setdefault(f, os.path.join(r, f))
    print(f"[fetch_models] {len(items)} entries -> {M}  (hf token: {'yes' if env('HF_TOKEN') else 'no'})", flush=True)
    ok_all = True
    files = [it for it in items if not it[0].startswith("gdrive:")]
    with ThreadPoolExecutor(3) as ex:
        for ok, msg in ex.map(lambda it: fetch_file(it[0], it[1], M, have, a.dry_run), files):
            ok_all &= ok
            print("[fetch_models]", msg, flush=True)
    for src, dests in (it for it in items if it[0].startswith("gdrive:")):
        ok, lines = fetch_gdrive(src, dests, M, a.dry_run)
        ok_all &= ok
        for l in lines:
            print("[fetch_models]", l, flush=True)
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
