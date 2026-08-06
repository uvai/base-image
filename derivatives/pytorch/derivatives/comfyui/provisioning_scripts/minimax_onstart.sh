#!/usr/bin/env bash
# minimax_onstart.sh — Vast.ai onstart for the Hearmeman MiniMax H3 image (cu130)
# Ported from the RunPod template. The image's own /start.sh does all the work:
# SageAttention wheel probe (baked cu130 wheel -> kernel probe -> source-build
# fallback), Jupyter, workflow_provisioner.py model pull via HF, ComfyUI launch.
# This wrapper just sets the env the RunPod template used to inject, then runs it.
#
# Usage: paste into the Vast template "On-start Script" box, or host in
# uvai/base-image and curl it. Env vars below can also be set via Vast's
# template env fields / -e docker options instead — values here are fallbacks.

set -u

# ---- template env (RunPod-equivalent) ---------------------------------------
export download_minimax_h3="${download_minimax_h3:-true}"
# RTX 5090 = Blackwell (sm_120): nvfp4 is the native fast path per the image's
# own docs. Use int8 if you ever land on Ada/Hopper/Ampere.
export minimax_quant="${minimax_quant:-nvfp4}"
export CUDA_VARIANT="${CUDA_VARIANT:-cu130}"
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN in the Vast template env}"
export civitai_token="${civitai_token:-}"
export CHECKPOINT_IDS_TO_DOWNLOAD="${CHECKPOINT_IDS_TO_DOWNLOAD:-replace_with_ids}"
export LORAS_IDS_TO_DOWNLOAD="${LORAS_IDS_TO_DOWNLOAD:-replace_with_ids}"
# start.sh appends RUNPOD_POD_ID to the comfyui log filename; give it something.
export RUNPOD_POD_ID="${VAST_CONTAINERLABEL:-vast}"

# ---- workspace --------------------------------------------------------------
# RunPod mounts a network volume at /workspace; on Vast we just use container
# disk at the same path so all of start.sh's persistence logic works unchanged.
mkdir -p /workspace

# ---- idempotency guard ------------------------------------------------------
# Vast re-runs onstart on instance restart; start.sh is not fully re-entrant
# (git clones, moves). Skip if ComfyUI is already up or a boot is in flight.
if curl -sf http://127.0.0.1:8188 >/dev/null 2>&1; then
    echo "[onstart] ComfyUI already running — skipping boot"
    exit 0
fi
if [ -f /tmp/minimax_boot.pid ] && kill -0 "$(cat /tmp/minimax_boot.pid)" 2>/dev/null; then
    echo "[onstart] boot already in progress (pid $(cat /tmp/minimax_boot.pid))"
    exit 0
fi

# ---- locate and run the baked start script ----------------------------------
START=""
for cand in /start.sh /start_script.sh; do
    [ -f "$cand" ] && { START="$cand"; break; }
done
if [ -z "$START" ]; then
    echo "[onstart] FATAL: no /start.sh or /start_script.sh in image" >&2
    exit 1
fi

echo "[onstart] launching $START (quant=$minimax_quant, flag=$download_minimax_h3)"
nohup bash "$START" > /workspace/minimax_boot.log 2>&1 &
echo $! > /tmp/minimax_boot.pid
echo "[onstart] boot pid $(cat /tmp/minimax_boot.pid) — tail /workspace/minimax_boot.log"
