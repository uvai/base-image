#!/usr/bin/env bash
# comfy_update.sh — pin ComfyUI core to a known-good release. FAST PATH: no checkout, pip or
# import test at boot.
#
# On the hearmeman image, the runtime's start.sh runs after additional_params.sh and (with its
# default COMFYUI_VERSION=approved) moves ComfyUI to the SHA in /comfyui-approved-ref and
# reinstalls requirements (torch-constrained) in its own single pass. So at boot we only resolve
# the pinned tag to a SHA and write it there. On images without that runtime we check it out.
#
# Env (Vast template, all optional):
#   COMFY_UPDATE=false   skip entirely (stay on the image's ComfyUI)
#   COMFY_PIN=v0.xx.x    override the pinned tag below
#
# Bumping the pin: on a running instance first run   bash comfy_update.sh --test v0.NN.N
# (checks it out, installs requirements, loads every custom node pack and reports failures),
# then change DEFAULT_PIN here.
set -u
LOG=/workspace/comfy_update.log
log() { echo "[comfy_update] $*" | tee -a "$LOG"; }

# smoke-tested 2026-11-17: mmx-comfy-nodes, H3 Project Suite, MiniMaxH3Mod, RefPack, KJ, VHS,
# RMBG, BFSNodes, H3 latent upscaler all import cleanly
DEFAULT_PIN=v0.45.5

TEST=""
if [ "${1:-}" = "--test" ]; then TEST=1; COMFY_PIN="${2:-${COMFY_PIN:-$DEFAULT_PIN}}"; fi
PIN="${COMFY_PIN:-$DEFAULT_PIN}"
[ -z "$TEST" ] && [ "${COMFY_UPDATE:-true}" != "true" ] && { log "COMFY_UPDATE=${COMFY_UPDATE} — skipped"; exit 0; }

CUI=""
for d in /ComfyUI /workspace/ComfyUI; do
  [ -f "$d/main.py" ] && [ -d "$d/.git" ] && CUI="$d" && break
done
[ -z "$CUI" ] && { log "no git checkout of ComfyUI found — skipped"; exit 0; }
cd "$CUI" || exit 0
git config --global --add safe.directory "$CUI" 2>/dev/null

SHA=$(git rev-parse --verify -q "$PIN^{commit}" 2>/dev/null)
if [ -z "$SHA" ]; then
  timeout 90 git fetch -q origin "refs/tags/$PIN:refs/tags/$PIN" 2>>"$LOG"
  SHA=$(git rev-parse --verify -q "$PIN^{commit}" 2>/dev/null)
fi
[ -z "$SHA" ] && { log "could not resolve $PIN (fetch failed?) — leaving ComfyUI as the image ships it"; exit 0; }

if [ -n "$TEST" ]; then
  PINF=/workspace/uvai-torch-pin.txt
  python3 -m pip freeze 2>/dev/null | grep -iE '^(torch|torchvision|torchaudio)==' > "$PINF"
  PREV=$(git rev-parse HEAD)
  git checkout -q "$SHA" && python3 -m pip install -q -c "$PINF" -r requirements.txt
  echo "[comfy_update] loading every custom node pack under $PIN (up to 7 min)..."
  timeout 420 python3 main.py --quick-test-for-ci --port 8199 > /workspace/comfy_smoke.log 2>&1
  echo "[comfy_update] exit=$?  import failures:"; grep 'IMPORT FAILED' /workspace/comfy_smoke.log || echo "  none"
  echo "[comfy_update] still checked out at $PIN; to go back: git -C $CUI checkout $PREV"
  exit 0
fi

if [ -d /comfyui-runtime ] || [ -e /comfyui-approved-ref ]; then
  if echo "$SHA" > /comfyui-approved-ref 2>/dev/null; then
    log "pinned $PIN ($(echo "$SHA" | cut -c1-10)) in /comfyui-approved-ref — the runtime moves ComfyUI to it at launch"
  else
    log "WARN: /comfyui-approved-ref not writable — ComfyUI stays on the image's version"
  fi
else
  PINF=/workspace/uvai-torch-pin.txt
  python3 -m pip freeze 2>/dev/null | grep -iE '^(torch|torchvision|torchaudio)==' > "$PINF"
  if [ "$(git rev-parse HEAD)" != "$SHA" ]; then
    git checkout -q "$SHA" && timeout 300 python3 -m pip install -q -c "$PINF" -r requirements.txt >> "$LOG" 2>&1
    log "checked out $PIN (no runtime on this image)"
  else
    log "already on $PIN"
  fi
fi
