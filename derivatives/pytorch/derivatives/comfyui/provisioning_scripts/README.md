# MiniMax H3 — RunPod → Vast.ai port

Everything is baked into the Docker image (`/start.sh` + `/workflow_provisioner.py`
+ `/models_registry.json` + `/hf_download_manager.py`). No external provisioning
script exists. The port is: same image, same env vars, onstart runs `/start.sh`.

## Vast template settings

**Image:** `hearmeman/comfyui-minimax-template:v1`
This is the cu130 build (CUDA 13.0, torch 2.11.0+cu130, prebuilt SageAttention
wheel, ComfyUI v0.30.1 pinned). If a Vast host is pinned to a CUDA 12.8 driver,
use `hearmeman/comfyui-minimax-template:v1-cuda12` instead — but note that tag
has **no NVFP4** and compiles SageAttention at boot (slower first start), and
you'd set `minimax_quant=int8` with it.

**Launch mode:** SSH (Vast-managed), with `minimax_onstart.sh` as the On-start script.
Do NOT use "Docker ENTRYPOINT" mode — the image's entrypoint chain
(`nvidia_entrypoint.sh → /start_script.sh`) ends in `sleep infinity` and you lose
Vast's SSH management. The onstart wrapper backgrounds `/start.sh` instead.

**Docker options:**
```
-p 8188:8188 -p 8888:8888
```

**Environment (template env fields):**
```
HF_TOKEN=<your token>
civitai_token=<your token>            # optional, only for CivitAI ID downloads
download_minimax_h3=true
minimax_quant=nvfp4                   # 5090/Blackwell. int8 on anything older.
CHECKPOINT_IDS_TO_DOWNLOAD=replace_with_ids
LORAS_IDS_TO_DOWNLOAD=replace_with_ids
```

**Machine filters:** RTX 5090 (or other Blackwell), driver ≥ 580 for CUDA 13
(the RunPod pod showed driver 590.48). Disk: template author recommends 100 GB
(75 GB for int8/fp8 weights, 64 GB for nvfp4, plus outputs); the observed pod
had ~72 GB of models on volume. 100–150 GB container disk on Vast is comfortable
— unlike RunPod there's no separate network volume, it's all one allocation.

## Quant selection (from the image's own docs)

| quant | encoder | transformer | native on |
|-------|---------|-------------|-----------|
| int8 (default) | int8, 27 GB | int8, 21 GB | everything (safe) |
| fp8 | int8, 27 GB | fp8, 21 GB | Ada/Hopper (4090/L40/H100/H200) |
| nvfp4 | NVFP4, 16 GB | fp8, 21 GB | Blackwell only (5090/PRO 6000/B200) |

nvfp4 is *emulated* (slow) on anything pre-Blackwell — only use it on 50xx.
Bonus on the 5090: nvfp4's encoder is 11 GB smaller, so it's both the fastest
and the lightest download. Changing quant later = change the env var + restart;
the provisioner re-pulls only what's needed and repoints the workflows.

## Differences vs RunPod / gotchas

- **Do not copy** `NVIDIA_VISIBLE_DEVICES=void`, `RUNPOD_*`, `PUBLIC_KEY`,
  `JUPYTER_*` — RunPod plumbing.
- **Jupyter has NO auth.** `/start.sh` launches jupyter-lab with an empty token,
  rooted at `/` (full filesystem, incl. your HF token in env). On RunPod that
  sat behind their auth proxy; on Vast the mapped port is open internet.
  Either drop `-p 8888:8888` and reach it via SSH tunnel / Tailscale (your
  usual pattern), or kill jupyter post-boot.
- **ComfyUI on 8188** is also unauthenticated (`--listen --enable-cors-header '*'`).
  Same treatment: prefer tunnel over public port mapping.
- **Models re-download on every fresh instance** (~72 GB from HF). The
  provisioner skips files >10 MB already on disk, so a Vast *stopped/restarted*
  instance won't re-pull, but a new rental will. Budget ~10–20 min first boot.
- **First boot log:** `/workspace/minimax_boot.log`, then
  `/workspace/comfyui_<label>_nohup.log` once ComfyUI launches.
- `additional_params.sh` hook: drop a script at `/workspace/additional_params.sh`
  and `/start.sh` runs it pre-boot — the sanctioned place for your own tweaks
  (e.g. killing jupyter, extra nodes) without forking the image.

## Verify after boot

```bash
tail -f /workspace/minimax_boot.log          # watch provisioning
curl -sf http://127.0.0.1:8188 && echo UP    # ComfyUI health
grep -c . /tmp/hf_download_queue.tsv         # models queued this boot
nvidia-smi                                    # confirm 5090 visible
```
