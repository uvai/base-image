#!/usr/bin/env bash
# additional_params.sh — hooks run by the image's /start.sh before Jupyter/ComfyUI.
# Baseline posture: MiniMax-only (JupyterLab disabled) + ComfyUI Manager and
# the MiniMaxRefPack custom node (needed by the v4 H3 reference workflow).
#
# Hybrid H3 model (smhfacct fl2va+ref2va int8) downloads by default; set
# DOWNLOAD_HYBRID=false in the template env to skip it (~21GB).
#
# Klein sessions: set DOWNLOAD_KLEIN=true in the Vast template env to pull the
# FLUX.2 Klein 9B stack (bf16) in a detached worker via `hf download`.
# Global sage stays ON — verified clean with Klein 9B bf16 on this image
# 2026-08-10; the 2026-08-07 black-frame result traced to the old stack's
# sage build, not sage-vs-Klein (this image kernel-probes the wheel on the
# actual GPU before enabling --use-sage-attention).
#
# Downloader notes: hf/xet parallelises correctly where aria2 could not
# (single-stream ~5MB/s vs ~350MB/s observed 2026-08-10) and handles resume +
# integrity natively — no size heuristics or .aria2 checks needed. Keep aria2
# for non-hf.co hosts only.

# ── 1. neuter jupyter-lab ────────────────────────────────────────────────────
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/jupyter-lab <<'EOF'
#!/usr/bin/env bash
echo "[additional_params] jupyter-lab disabled by /workspace/additional_params.sh"
exit 0
EOF
chmod +x /usr/local/sbin/jupyter-lab
echo "[additional_params] JupyterLab disabled (shadowed in /usr/local/sbin)"

# ── 2. Klein 9B model stack (opt-in: DOWNLOAD_KLEIN=true) ────────────────────
if [ "${DOWNLOAD_KLEIN:-false}" = "true" ]; then
    cat > /root/klein_fetch.sh <<'WEOF'
#!/usr/bin/env bash
# klein_fetch.sh — detached (setsid) so it survives Vast reaping the on-start
# process group (the 2026-08-06 failure mode). Written by additional_params.sh.
set -u
LOG=/workspace/extra_models.log
M=/workspace/ComfyUI/models
echo "=== klein fetch $(date -u +%FT%TZ) (worker pid $$) ===" >> "$LOG"
# Wait for the image's own model downloads first: competing streams collapsed
# the H3 pulls from ~290MB/s to single digits (2026-08-23), and on 2026-09-01
# the H3 text encoder never arrived at all. Process-name watching was fragile
# (v4 renamed things and dropped /start.sh), so watch the models dir instead:
# proceed only once its total size has stopped growing for two checks. Cap 45 min.
PREV=-1; STILL=0
for _i in $(seq 1 135); do
    CUR=$(du -sb /workspace/ComfyUI/models 2>/dev/null | cut -f1)
    CUR=${CUR:-0}
    if [ "$CUR" = "$PREV" ]; then STILL=$((STILL+1)); else STILL=0; fi
    [ "$STILL" -ge 2 ] && break
    PREV=$CUR
    sleep 20
done
echo "=== klein fetch proceeding $(date -u +%FT%TZ) ===" >> "$LOG"
pip install -q -U huggingface_hub >> "$LOG" 2>&1
mkdir -p "$M/diffusion_models" "$M/text_encoders" "$M/vae"
ok=1

# hf download into --local-dir is idempotent for the first file; the two
# moved files get explicit exists-guards since mv empties the local-dir.
hf download black-forest-labs/FLUX.2-klein-9B flux-2-klein-9b.safetensors \
    --local-dir "$M/diffusion_models" >> "$LOG" 2>&1 || ok=0

if [ ! -f "$M/text_encoders/qwen_3_8b.safetensors" ]; then
    hf download Comfy-Org/vae-text-encorder-for-flux-klein-9b \
        split_files/text_encoders/qwen_3_8b.safetensors \
        --local-dir /tmp/hf_te >> "$LOG" 2>&1 \
        && mv -f /tmp/hf_te/split_files/text_encoders/qwen_3_8b.safetensors \
                 "$M/text_encoders/" || ok=0
fi
if [ ! -f "$M/vae/flux2-vae.safetensors" ]; then
    hf download Comfy-Org/flux2-dev split_files/vae/flux2-vae.safetensors \
        --local-dir /tmp/hf_vae >> "$LOG" 2>&1 \
        && mv -f /tmp/hf_vae/split_files/vae/flux2-vae.safetensors \
                 "$M/vae/" || ok=0
fi

if [ "${DOWNLOAD_HYBRID:-true}" = "true" ] \
   && [ ! -f "$M/diffusion_models/minimax_h3_hybrid_fl2va_ref2va_b15-49-int8.safetensors" ]; then
    echo "--- hybrid H3 fl2va+ref2va (int8) ---" >> "$LOG"
    hf download smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models \
        minimax_h3_hybrid_fl2va_ref2va_b15-49-int8.safetensors \
        --local-dir "$M/diffusion_models" >> "$LOG" 2>&1 || ok=0
fi

if [ "$ok" = 1 ]; then
    echo "=== extra model fetch complete ===" >> "$LOG"
else
    echo "=== klein fetch FINISHED WITH FAILURES (gated BFL repo needs HF_TOKEN with licence accepted) ===" >> "$LOG"
fi
WEOF
    chmod +x /root/klein_fetch.sh
    [ -n "${HF_TOKEN:-}" ] && export HF_TOKEN
    setsid nohup /root/klein_fetch.sh >/dev/null 2>&1 < /dev/null &
    echo "[additional_params] klein fetch detached (pid $!; log: /workspace/extra_models.log)"
else
    echo "[additional_params] DOWNLOAD_KLEIN not set — MiniMax-only session"
fi

# ── 3. ComfyUI Manager + MiniMax RefPack ─────────────────────────────────────
# v4 image: the app lives at /ComfyUI (not /workspace/ComfyUI) and the H3
# reference workflow needs Hearmeman24/ComfyUI-MiniMaxRefPack, whose registry
# install fails silently (2026-08-23). Clone it directly, install Manager,
# and patch --enable-manager into start.sh's launch line before it runs.
CUI=""
for d in /ComfyUI /workspace/ComfyUI; do
    [ -f "$d/main.py" ] && CUI="$d" && break
done
if [ -n "$CUI" ]; then
    python3 -m pip install -q -U --pre comfyui-manager \
        && echo "[additional_params] comfyui-manager installed"
    if [ -f /start.sh ] && ! grep -q "enable-manager" /start.sh; then
        sed -i 's|/main\.py" --listen|/main.py" --enable-manager --listen|' /start.sh \
            && echo "[additional_params] --enable-manager patched into /start.sh"
    fi
    CN="$CUI/custom_nodes"
    mkdir -p "$CN"
    if [ ! -d "$CN/ComfyUI-MiniMaxRefPack" ]; then
        git clone --depth 1 https://github.com/Hearmeman24/ComfyUI-MiniMaxRefPack \
            "$CN/ComfyUI-MiniMaxRefPack" >/dev/null 2>&1 \
            && { [ -f "$CN/ComfyUI-MiniMaxRefPack/requirements.txt" ] \
                 && python3 -m pip install -q -r "$CN/ComfyUI-MiniMaxRefPack/requirements.txt"; \
                 echo "[additional_params] MiniMaxRefPack installed -> $CN"; } \
            || echo "[additional_params] WARN: MiniMaxRefPack clone failed"
    else
        echo "[additional_params] MiniMaxRefPack already present"
    fi
else
    echo "[additional_params] WARN: no ComfyUI main.py found — manager/refpack skipped"
fi
