#!/usr/bin/env bash
# additional_params.sh — optional hardening hook for the MiniMax H3 image.
# /start.sh runs this file automatically if it exists at /workspace/additional_params.sh
# (before Jupyter/ComfyUI start). This variant prevents the tokenless JupyterLab
# from ever binding — use it if you don't want 8888 reachable at all.
#
# To deploy: the onstart script copies this into place if PRESENT, or just
# `curl -fsSL <raw-url> -o /workspace/additional_params.sh` before /start.sh runs.

# Neuter jupyter-lab for this boot. start.sh calls `jupyter-lab ... &` directly,
# so shadowing the binary earlier in PATH is the cleanest non-fork intercept.
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/jupyter-lab <<'EOF'
#!/usr/bin/env bash
echo "[additional_params] jupyter-lab disabled by /workspace/additional_params.sh"
exit 0
EOF
chmod +x /usr/local/sbin/jupyter-lab
echo "[additional_params] JupyterLab disabled (shadowed in /usr/local/sbin)"
