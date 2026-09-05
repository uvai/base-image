#!/usr/bin/env python3
"""Mock ComfyUI: enough of the API to test mmx_runner v2. Records every submitted prompt.

v2 additions: /object_info (model enums; MOCK_LORAS env = comma list, default three),
Display Any output (node 186 -> ui text = the direction, so the runner's generated_prompt
capture is exercised), and MiniMaxH3AddGuide awareness: when a submitted graph anchors a
LoadImage through the guide node, the rendered segment *starts* on that image (so the
runner's continuity PSNR check has something real to measure); otherwise segments are
solid colours that differ from each other.

    MOCK_RENDER=0.3 python3 mock_comfy.py [--port 8188]
"""
import http.server, json, os, re, subprocess, sys, threading, time, uuid

OUT = os.environ.get("MOCK_OUT", "/tmp/mmx_mock/out")
INP = os.environ.get("MOCK_IN", "/tmp/mmx_mock/in")
SUBMITTED_FILE = os.environ.get("MOCK_SUBMITTED", "/tmp/mmx_mock/mock_submitted.json")
os.makedirs(OUT, exist_ok=True); os.makedirs(INP, exist_ok=True); os.makedirs(os.path.dirname(SUBMITTED_FILE), exist_ok=True)
PROMPTS = {}; HISTORY = {}; SUBMITTED = []
RENDER_SECONDS = float(os.environ.get("MOCK_RENDER", "1.5"))
COLORS = ["red", "green", "blue", "yellow", "magenta", "cyan"]

MODELS = {
    "LoraLoaderModelOnly": ("lora_name", [s for s in os.environ.get(
        "MOCK_LORAS", "MiniMax-H3-Ref2VA-Acc-8Step.safetensors,minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors,"
                      "H3_Motion_BoosterV2.safetensors,side_fuck_h3_000000750.safetensors").split(",") if s]),
    "UNETLoader": ("unet_name", ["minimax_h3_hybrid_fl2va_ref2va_b15-49-int8.safetensors", "minimax_h3_ref2va_pruned_fp8_scaled.safetensors"]),
    "VAELoader": ("vae_name", ["minimax_h3_video_vae_fp16.safetensors", "minimax_h3_audio_vae_fp32.safetensors"]),
    "CLIPLoader": ("clip_name", ["qwen3vl_32b_minimax_h3_int8_convrot.safetensors"]),
}

def object_info(cls=None):
    def one(c):
        inp, enum = MODELS[c]
        return {c: {"input": {"required": {inp: [enum, {}]}}, "output": [], "name": c, "display_name": c}}
    if cls: return one(cls) if cls in MODELS else {}
    info = {}
    for c in MODELS: info.update(one(c))
    info["MiniMaxH3AddGuide"] = {"input": {"required": {"positive": ["CONDITIONING"], "latent": ["LATENT"], "frame_idx": ["INT", {"default": 0}]},
                                          "optional": {"vae": ["VAE"], "audio_vae": ["VAE"], "image": ["IMAGE"], "audio": ["AUDIO"]}},
                                "output": ["CONDITIONING"], "name": "MiniMaxH3AddGuide", "display_name": "Add Guide for MiniMax H3"}
    return info

def run(cmd):
    subprocess.run(cmd, check=True)

def make_mp4(path, color, size="320x180", guide_png=None):
    if guide_png:
        # first ~half on the guide image, then the colour — first frame == guide, last frame == colour
        run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-t", "0.5", "-i", guide_png,
             "-f", "lavfi", "-t", "0.5", "-i", f"color=c={color}:s={size}:r=24",
             "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
             "-filter_complex", f"[0:v]scale={size.replace('x', ':')},setsar=1,fps=24[g];[1:v]setsar=1[c];[g][c]concat=n=2:v=1:a=0[v]",
             "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv444p", "-c:a", "aac", "-shortest", path])
    else:
        run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s={size}:d=1:r=24",
             "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-shortest", path])

def last_frame_png(mp4, path):
    run(["ffmpeg", "-y", "-loglevel", "error", "-sseof", "-0.05", "-i", mp4, "-frames:v", "1", "-update", "1", path])

def guide_image_of(p):
    for nid, node in p.items():
        if node.get("class_type") == "MiniMaxH3AddGuide":
            img = node["inputs"].get("image")
            if isinstance(img, list) and str(img[0]) in p and p[str(img[0])].get("class_type") == "LoadImage":
                f = os.path.join(INP, p[str(img[0])]["inputs"]["image"])
                return f if os.path.isfile(f) else None
    return None

def finish(pid):
    time.sleep(RENDER_SECONDS)
    p = PROMPTS[pid]
    try:
        vprefix = p["119"]["inputs"]["filename_prefix"]; lprefix = p["195"]["inputs"]["filename_prefix"]
        sub, vname = os.path.split(vprefix); lname = os.path.basename(lprefix)
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
        color = COLORS[len(HISTORY) % len(COLORS)]
        w, h = p["184"]["inputs"]["width"], p["184"]["inputs"]["height"]
        mp4 = os.path.join(OUT, sub, vname + "_00001.mp4")
        make_mp4(mp4, color, f"{w}x{h}", guide_image_of(p))
        last_frame_png(mp4, os.path.join(OUT, sub, lname + "_00001_.png"))
        direction = p["185"]["inputs"].get("direction", "")
        provider = p["185"]["inputs"].get("prompt_provider", "none")
        text = direction if provider == "none" else f"[mock {provider} rewrite] " + direction
        HISTORY[pid] = {"status": {"status_str": "success", "completed": True, "messages": []},
                        "outputs": {"119": {"gifs": [{"filename": vname + "_00001.mp4", "subfolder": sub, "type": "output", "format": "video/h264-mp4"}]},
                                    "195": {"images": [{"filename": lname + "_00001_.png", "subfolder": sub, "type": "output"}]},
                                    "186": {"text": [text]}}}
    except Exception as e:
        HISTORY[pid] = {"status": {"status_str": "error", "completed": False,
                                   "messages": [["execution_error", {"exception_message": f"mock render failed: {e}"}]]}, "outputs": {}}

def validate(p):
    """Mimic ComfyUI's model-file validation: unknown enum values -> node_errors."""
    errs = {}
    for nid, node in p.items():
        cls = node.get("class_type")
        if cls in MODELS:
            inp, enum = MODELS[cls]
            v = node["inputs"].get(inp)
            if v is not None and v not in enum:
                errs[nid] = {"errors": [{"type": "value_not_in_list", "message": f"Value not in list: {inp}: '{v}' not in {enum[:3]}…", "details": ""}], "class_type": cls}
        if cls == "Power Lora Loader (rgthree)":
            enum = MODELS["LoraLoaderModelOnly"][1]
            for k, v in node["inputs"].items():
                if k.startswith("lora_") and isinstance(v, dict) and v.get("on") and v.get("lora") not in enum:
                    errs[nid] = {"errors": [{"type": "value_not_in_list", "message": f"lora '{v.get('lora')}' not in loras folder", "details": ""}], "class_type": cls}
    return errs

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, o, code=200):
        b = json.dumps(o).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/system_stats": return self._json({"system": {"os": "mock"}})
        if u.path == "/object_info": return self._json(object_info())
        if u.path.startswith("/object_info/"): return self._json(object_info(u.path.split("/")[2]))
        if u.path.startswith("/history/"):
            pid = u.path.split("/")[2]; return self._json({pid: HISTORY[pid]} if pid in HISTORY else {})
        if u.path == "/queue":
            running = [[0, pid, PROMPTS[pid]] for pid in PROMPTS if pid not in HISTORY]
            return self._json({"queue_running": running[:1], "queue_pending": [[0, p, None] for p in [r[1] for r in running[1:]]]})
        if u.path == "/view":
            f = q["filename"][0]; sub = q.get("subfolder", [""])[0]; t = q.get("type", ["output"])[0]
            path = os.path.join(OUT if t == "output" else INP, sub, f)
            if not os.path.isfile(path): return self._json({"error": "nf"}, 404)
            data = open(path, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        self._json({"error": "nf"}, 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n)
        if self.path == "/prompt":
            body = json.loads(raw); p = body["prompt"]
            errs = validate(p)
            if errs:
                # real ComfyUI: 400 with node_errors when every output is invalid; 200 + node_errors when only
                # some outputs fail. Model-file misses hit the whole graph, so 400 here.
                return self._json({"error": {"type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation", "details": ""},
                                   "node_errors": errs}, 400)
            pid = uuid.uuid4().hex; PROMPTS[pid] = p; SUBMITTED.append(p)
            json.dump(SUBMITTED, open(SUBMITTED_FILE, "w"), indent=1)
            threading.Thread(target=finish, args=(pid,), daemon=True).start()
            return self._json({"prompt_id": pid, "number": len(PROMPTS), "node_errors": {}})
        if self.path == "/upload/image":
            m = re.search(rb'filename="([^"]+)"\r\n(?:[^\r\n]*\r\n)*\r\n', raw)
            name = m.group(1).decode(); start = m.end()
            boundary = self.headers["Content-Type"].split("boundary=")[1].encode()
            end = raw.find(b"\r\n--" + boundary, start)
            open(os.path.join(INP, name), "wb").write(raw[start:end])
            return self._json({"name": name, "subfolder": "", "type": "input"})
        if self.path == "/interrupt": return self._json({})
        self._json({"error": "nf"}, 404)

if __name__ == "__main__":
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8188
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H); srv.daemon_threads = True
    print(f"mock comfy on {port} (out={OUT} in={INP})", flush=True); srv.serve_forever()
