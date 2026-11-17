#!/usr/bin/env bash
# comfy_update.sh — bring ComfyUI core to the newest release tag (or $COMFY_PIN) before
# ComfyUI starts, and roll back automatically if any of the packs we depend on fail to import.
# Run by additional_params.sh §6 (pre-boot). Log: /workspace/comfy_update.log
#
# Env (Vast template, all optional):
#   COMFY_UPDATE=false   skip entirely (stay on the image's ComfyUI)
#   COMFY_PIN=v0.xx.x    use this tag/commit instead of the newest release
set -u
LOG=/workspace/comfy_update.log
log() { echo "[comfy_update] $*" | tee -a "$LOG"; }

[ "${COMFY_UPDATE:-true}" = "true" ] || { log "COMFY_UPDATE=${COMFY_UPDATE} — skipped"; exit 0; }

CUI=""
for d in /ComfyUI /workspace/ComfyUI; do
  [ -f "$d/main.py" ] && [ -d "$d/.git" ] && CUI="$d" && break
done
[ -z "$CUI" ] && { log "no git checkout of ComfyUI found — skipped"; exit 0; }
cd "$CUI" || exit 0
git config --global --add safe.directory "$CUI" 2>/dev/null

# torch stays exactly as the image ships it (cu130 build); hf-hub stays <2.0 via PIP_CONSTRAINT
PIN=/workspace/uvai-torch-pin.txt
python3 -m pip freeze 2>/dev/null | grep -iE '^(torch|torchvision|torchaudio)==' > "$PIN"
reqs() { python3 -m pip install -q -c "$PIN" -r requirements.txt >> "$LOG" 2>&1; }

PREV=$(git rev-parse HEAD)
PREV_DESC=$(git describe --tags 2>/dev/null || echo "${PREV:0:10}")
echo "$PREV" > /workspace/comfy_prev_commit.txt
git stash -u -q 2>/dev/null || true
if ! git fetch -q --tags origin 2>>"$LOG"; then
  log "git fetch failed — staying on $PREV_DESC"; exit 0
fi
TARGET="${COMFY_PIN:-$(git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)}"
[ -z "$TARGET" ] && { log "no release tag found — staying on $PREV_DESC"; exit 0; }
if [ "$(git rev-parse "$TARGET^{commit}" 2>/dev/null)" = "$PREV" ]; then
  log "already on $TARGET"; exit 0
fi

log "updating $PREV_DESC -> $TARGET"
git checkout -q "$TARGET" 2>>"$LOG" || { log "checkout $TARGET failed — staying on $PREV_DESC"; exit 0; }
reqs

# Smoke test: load every custom node pack once and exit. Roll back if a pack we rely on breaks.
SMOKE=/workspace/comfy_smoke.log
timeout 420 python3 main.py --quick-test-for-ci --port 8199 > "$SMOKE" 2>&1
RC=$?
BROKEN=$(grep 'IMPORT FAILED' "$SMOKE" \
  | grep -iE 'mmx|H3-Project|MiniMaxH3Mod|MiniMaxRefPack|KJNodes|VideoHelperSuite|RMBG|BFSNodes|latent_Upscaler' \
  | sed 's|.*/custom_nodes/||' | tr '\n' ' ')
if [ "$RC" -ne 0 ] || [ -n "$BROKEN" ]; then
  log "ROLLED BACK to $PREV_DESC — rc=$RC broken: ${BROKEN:-none (see $SMOKE)}"
  git checkout -q "$PREV" && reqs
  exit 0
fi
OTHER=$(grep -c 'IMPORT FAILED' "$SMOKE")
log "now on $(git describe --tags 2>/dev/null) (was $PREV_DESC); other packs failing import: $OTHER (see $SMOKE)"
