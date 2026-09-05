#!/usr/bin/env python3
"""mmx_runner v2.0 — headless MiniMax H3 chain runner. Lives ON the Vast instance.

Takes a job spec (from mmx_studio.html, or anything else) and, per segment:
  template -> patch node inputs -> POST /prompt -> wait -> collect mp4 + last frame
  -> last frame becomes slot 9 (and, for segments 2+, a hard first-frame guide)
  of the next segment -> repeat -> ffmpeg concat.

Talks to ComfyUI purely over its HTTP API on localhost (upload/view/prompt/history),
so it does not care where ComfyUI's input/output dirs live. Stdlib only.

    python3 mmx_runner.py [--port 8190] [--comfy http://127.0.0.1:8188]

OpenRouter key: first non-empty of OPENROUTER_API_KEY, OPENROUTER_KEY, LLM_KEY —
always written into the RefPack node, so ComfyUI's own environment is irrelevant.

Endpoints (CORS open, for the file:// studio page):
  GET  /health                       -> {ok, version, comfy, ffmpeg, openrouter_key, nas, jobs}
  GET  /models[?fresh=1]             -> {loras, unets, vaes, clips} from ComfyUI /object_info
  GET  /library?kind=subjects|videoref[&fresh=1]   -> {items:[...], locked, error}
  GET  /library/state                -> {configured, reachable, locked, kinds}
  GET  /library/thumb?path=<rel>     -> jpeg (viewer thumb reused, else generated once)
  POST /validate                     -> spec in body; {ok, segments:[{prompt, references}], errors}
  POST /job                          -> {job}          spec JSON in body (spec_version 1 or 2)
  GET  /job/<id>                     -> full job state (poll this)
  POST /job/<id>/cancel              -> interrupt current segment, stop chain
  GET  /jobs                         -> summaries
  GET  /media?f=<name>&sub=<sub>&type=output       proxies ComfyUI /view

Spec v2 (v1 specs with refs/first_frame are upgraded on arrival):
  {
    "spec_version": 2, "name": "...",
    "template": {<API-format graph>},               # segment 1 (and all, when templates.next is absent)
    "templates": {"first": {...}, "next": {...}},    # optional; overrides "template"
    "mapping": {"refpack": "185", ...},              # optional node-id overrides (DEFAULT_MAP)
    "slots": {
      "images": [{"slot": 1..9, "src": SRC}],        # slot 9 = first frame
      "videos": [{"slot": 1..3, "src": SRC, "use_soundtrack": true}],
      "audios": [{"slot": 1..3, "src": SRC}]
    },
    "segments": [{"prompt", "seconds", "aspect", "megapixels", "seed", "loras": [{"name", "strength"}]}],
    "concat": true,
    "options": {"seed", "seed_mode", "fps", "aspect", "megapixels", "seconds",
                "auto_prompt": {"enabled", "model", "reasoning"},
                "continuation": "guide" | "none",     # guide (default): inject MiniMaxH3AddGuide for segments 2+
                "continuation_unet": "<file>"}        # optional UNET swap for segments 2+
  }
  SRC = {"kind": "local", "name": "x.png", "data": "<base64>"}
      | {"kind": "library", "path": "Subjects/j/j1.jpg"}    # fetched from the NAS by the runner
"""
import argparse, base64, copy, hashlib, http.server, json, mimetypes, os, random, re, shutil
import subprocess, sys, tempfile, threading, time, urllib.parse, urllib.request, urllib.error, uuid

VERSION = "2.2"
COMFY = "http://127.0.0.1:8188"
OUTPUT_CANDIDATES = ["/workspace/ComfyUI/output", "/ComfyUI/output", "/root/ComfyUI/output"]
JOBS = {}
JOBS_LOCK = threading.Lock()
KEY_ENV = ("OPENROUTER_API_KEY", "OPENROUTER_KEY", "LLM_KEY")

# Node ids in the template. Overridable per-spec via spec["mapping"].
DEFAULT_MAP = {
    "refpack": "185",       # MiniMaxH3ReferencePack  (direction, references_json, provider, w/h, seconds)
    "ref2video": "184",     # MiniMaxH3ReferenceToVideo (width, height, positive/latent outputs)
    "duration": "132",      # PrimitiveFloat seconds
    "resolution": "115",    # ResolutionSelector (removed; literals written instead)
    "seed": "154",          # RandomNoise.noise_seed
    "video": "119",         # VHS_VideoCombine
    "lastframe": "195",     # SaveImage of ImageFromBatch(-1)
    "apikey": "193",        # PrimitiveString holding the OpenRouter key (removed)
    "display": "186",       # Display Any (rgthree) showing the generated prompt
    "loras": "137",         # Power Lora Loader (rgthree): lora_1 = acc LoRA (never touched)
    "unet": "135",          # UNETLoader
    "guide": "900",         # injected MiniMaxH3AddGuide (continuation)
    "guide_image": "901",   # injected LoadImage feeding the guide
}
MAX_SLOTS = {"images": 9, "videos": 3, "audios": 3}
FIRST_SLOT = 9
TAG_RE = re.compile(r"<\s*(picture|video|audio)\s*(\d+)\s*>", re.I)
TAG_WORD = {"picture": "Picture", "video": "Video", "audio": "Audio"}

ASPECTS = {"16:9": 16/9, "9:16": 9/16, "1:1": 1.0, "4:3": 4/3, "3:4": 3/4,
           "21:9": 21/9, "4:5": 4/5, "5:4": 5/4, "3:2": 3/2, "2:3": 2/3}

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff"}
VIDEO_EXT = {".mp4", ".mov", ".webm", ".mkv", ".m4v"}
AUDIO_EXT = {".wav", ".mp3", ".flac", ".m4a", ".aac", ".ogg"}


def openrouter_key():
    for k in KEY_ENV:
        v = os.environ.get(k, "").strip()
        if v: return v
    return ""


# ── ComfyUI API helpers ──────────────────────────────────────────────────────
def comfy(path, data=None, timeout=30, method=None):
    url = COMFY + path
    body = None
    headers = {}
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:2000]
        try:
            j = json.loads(detail)
            if j.get("node_errors") or j.get("error"):
                raise RuntimeError(summarize_node_errors(j, data.get("prompt") if isinstance(data, dict) else None, j.get("error")))
        except (ValueError, AttributeError):
            pass
        raise RuntimeError(f"ComfyUI {path} -> HTTP {e.code}: {detail[:300]}")
    return json.loads(raw) if raw else {}

def summarize_node_errors(res, prompt=None, top=None):
    """Turn ComfyUI's node_errors into one readable line per node."""
    parts = []
    if isinstance(top, dict): top = top.get("message") or json.dumps(top)
    if top: parts.append(str(top))
    for nid, err in (res.get("node_errors") or {}).items():
        cls = (prompt or {}).get(nid, {}).get("class_type", "?")
        msgs = []
        for e in err.get("errors", []):
            m = e.get("message", "")
            d = e.get("details", "")
            if d: m += f": {d}"
            msgs.append(m)
        parts.append(f"node {nid} ({cls}): " + ("; ".join(msgs) or json.dumps(err)[:200]))
    return "ComfyUI rejected the workflow — " + " | ".join(parts) if parts else "ComfyUI rejected the workflow"

def comfy_bytes(path, timeout=120):
    with urllib.request.urlopen(COMFY + path, timeout=timeout) as r:
        return r.read()

def comfy_upload(name, data: bytes, overwrite=True):
    """POST /upload/image (multipart). Returns the stored filename. ComfyUI stores any
    file type under its input dir this way (videos and audio included)."""
    boundary = "----mmx" + uuid.uuid4().hex
    parts = []
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n"
                 f"Content-Type: {mimetypes.guess_type(name)[0] or 'application/octet-stream'}\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\n{'true' if overwrite else 'false'}\r\n".encode())
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(COMFY + "/upload/image", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        res = json.loads(r.read())
    return res.get("name", name)

def view_url(filename, subfolder="", ftype="output"):
    return "/view?" + urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": ftype})


# ── model lists (/object_info) ───────────────────────────────────────────────
MODEL_NODES = {"loras": ("LoraLoaderModelOnly", "lora_name"), "unets": ("UNETLoader", "unet_name"),
               "vaes": ("VAELoader", "vae_name"), "clips": ("CLIPLoader", "clip_name")}
_models_cache = {"t": 0, "data": None}
_models_lock = threading.Lock()

def model_lists(fresh=False, ttl=30):
    """{loras:[...], unets:[...], vaes:[...], clips:[...]} straight from ComfyUI. ComfyUI
    re-scans the model folders on every /object_info request in current builds, so a
    fresh=1 call sees newly copied files without any cache flush."""
    with _models_lock:
        if not fresh and _models_cache["data"] and time.time() - _models_cache["t"] < ttl:
            return _models_cache["data"]
        out = {}
        for key, (cls, inp) in MODEL_NODES.items():
            try:
                info = comfy(f"/object_info/{cls}", timeout=20)
                enum = info[cls]["input"]["required"][inp][0]
                out[key] = sorted(enum) if isinstance(enum, list) else []
            except Exception as e:
                out[key] = []
                out.setdefault("errors", {})[key] = str(e)[:200]
        _models_cache.update(t=time.time(), data=out)
        return out


# ── NAS library (Subjects / VideoRef on the pyramid share) ───────────────────
def _nas_config():
    userhost = os.environ.get("MMX_NAS") or ""
    if not userhost:
        dest = os.environ.get("NAS_DEST", "")
        if "@" in dest: userhost = dest.split(":")[0]
    userhost = userhost or "alchera@100.81.253.103"
    key = os.environ.get("MMX_NAS_KEY") or "/root/.ssh/mmx_nas_key"
    proxy = os.environ.get("MMX_NAS_PROXY")
    if proxy is None:
        # on the instance tailscaled runs in userspace mode: outbound tailnet traffic
        # must go through its SOCKS5 proxy (same path mmx_extras' nas_worker uses)
        proxy = "nc -X 5 -x 127.0.0.1:1055 %h %p" if os.path.exists("/root/.ssh/mmx_nas_key") else "none"
    return {"userhost": userhost, "key": key, "proxy": proxy,
            "share": os.environ.get("MMX_NAS_SHARE", "/volume1/subgenula"),
            "local_root": os.environ.get("MMX_LIBRARY_ROOT", "")}

def library_kinds():
    spec = os.environ.get("MMX_LIBRARY_DIRS", "subjects=Subjects,videoref=VideoRef")
    out = {}
    for part in spec.split(","):
        if "=" in part:
            k, v = part.split("=", 1); out[k.strip().lower()] = v.strip().strip("/")
    return out

def cache_dir():
    base = os.environ.get("MMX_CACHE") or ("/workspace/mmx_cache" if os.path.isdir("/workspace") else os.path.join(tempfile.gettempdir(), "mmx_cache"))
    os.makedirs(base, exist_ok=True)
    return base

def nas_ssh_cmd(cfg):
    cmd = ["ssh", "-i", cfg["key"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
           "-o", "StrictHostKeyChecking=accept-new"]
    if cfg["proxy"] and cfg["proxy"] != "none":
        cmd += ["-o", f"ProxyCommand={cfg['proxy']}"]
    return cmd

def nas_run(cmd, timeout=60):
    cfg = _nas_config()
    r = subprocess.run(nas_ssh_cmd(cfg) + [cfg["userhost"], cmd], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr

def nas_fetch(rel, dest, timeout=900):
    """Copy share/<rel> to dest by streaming `cat` over the same ssh path the listing uses.
    (scp is avoided on purpose: OpenSSH 9+ scp speaks SFTP by default, and DSM's SFTP
    server resolves absolute paths against its own root, so /volume1/... came back as
    "No such file or directory" even though ssh could read it.)"""
    cfg = _nas_config()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    src = os.path.join(cfg["share"], rel)
    q = shell_quote(src)
    cmd = nas_ssh_cmd(cfg) + [cfg["userhost"], f"if [ -f {q} ]; then cat {q}; else echo MMX_NOFILE >&2; exit 3; fi"]
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, timeout=timeout)
    err = r.stderr.decode(errors="replace").strip()
    if r.returncode != 0 or os.path.getsize(tmp) == 0:
        try: os.remove(tmp)
        except OSError: pass
        if "MMX_NOFILE" in err:
            raise RuntimeError(f"NAS fetch failed for {rel}: no such file on the share")
        raise RuntimeError(f"NAS fetch failed for {rel}: " + (("ssh: " + err.splitlines()[-1][-200:]) if err else f"rc={r.returncode}, empty"))
    os.replace(tmp, dest)
    return dest

def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def classify(name):
    ext = os.path.splitext(name)[1].lower()
    if ext in IMAGE_EXT: return "image"
    if ext in VIDEO_EXT: return "video"
    if ext in AUDIO_EXT: return "audio"
    return None

def item_id(rel):
    # same formula as the subgenula viewer (sha1 of the share-relative path, 12 hex)
    return hashlib.sha1(rel.encode()).hexdigest()[:12]

_lib_cache = {}
_lib_lock = threading.Lock()

def library_state():
    """Mount state of the share, judged on the NAS itself with the same signal the vgo
    dashboard and the subgenula viewer use: an ecryptfs entry for the share in the mount
    table (`synoshare --enc_mount` produces it, `--enc_unmount` removes it). Distinct tokens
    per outcome, so a locked share is never confused with an ssh, permission or path error.
    The raw command output lands in the runner log."""
    cfg = _nas_config()
    kinds = library_kinds()
    if cfg["local_root"]:
        return {"configured": True, "mode": "local", "reachable": os.path.isdir(cfg["local_root"]), "locked": False,
                "state": "local", "kinds": kinds, "dirs": {k: ("ok" if os.path.isdir(os.path.join(cfg["local_root"], v)) else "missing")
                                                          for k, v in kinds.items()}, "root": cfg["local_root"]}
    st = {"configured": os.path.exists(cfg["key"]), "mode": "nas", "userhost": cfg["userhost"], "share": cfg["share"],
          "kinds": kinds, "reachable": False, "locked": None, "state": None, "dirs": {}, "error": None}
    if not st["configured"]:
        st["error"] = f"NAS key {cfg['key']} not present on this host"
        return st
    share = cfg["share"]
    cmd = (f"if mount | grep -q {shell_quote(' ' + share + ' type ecryptfs')}; then echo MMX_STATE=mounted; "
           f"elif [ -d {shell_quote(share)} ]; then echo MMX_STATE=plain; else echo MMX_STATE=locked; fi; "
           f"echo MMX_WHO=$(id -un); ")
    for k, v in kinds.items():
        d = shell_quote(os.path.join(share, v))
        cmd += (f"if [ -d {d} ]; then if [ -r {d} ] && [ -x {d} ]; then echo MMX_DIR={k}=ok; else echo MMX_DIR={k}=noperm; fi; "
                f"else echo MMX_DIR={k}=missing; fi; ")
    try:
        rc, out, err = nas_run(cmd, timeout=25)
    except subprocess.TimeoutExpired:
        st["error"] = "NAS unreachable (ssh timeout after 25s)"
        print(f"[nas] state check timed out ({cfg['userhost']})", flush=True)
        return st
    print(f"[nas] state check rc={rc} out={out.strip()!r} err={err.strip()[-300:]!r}", flush=True)
    m = re.search(r"MMX_STATE=(\w+)", out)
    if rc == 255 or not m:
        e = err.strip().splitlines()[-1] if err.strip() else (out.strip()[-200:] or f"rc={rc}, no state token")
        st["error"] = ("NAS ssh failed: " if rc == 255 else "NAS check gave no verdict: ") + e[-200:]
        return st
    st["reachable"] = True
    st["state"] = m.group(1)
    st["locked"] = st["state"] == "locked"
    who = re.search(r"MMX_WHO=(\S+)", out)
    if who: st["user"] = who.group(1)
    for k, v in re.findall(r"MMX_DIR=(\w+)=(\w+)", out):
        st["dirs"][k] = v
    return st

def library_list(kind, fresh=False, ttl=120):
    kinds = library_kinds()
    if kind not in kinds:
        raise ValueError(f"unknown library kind '{kind}' (have: {', '.join(kinds)})")
    with _lib_lock:
        c = _lib_cache.get(kind)
        if c and not fresh and time.time() - c["t"] < ttl:
            return c["data"]
    cfg = _nas_config()
    sub = kinds[kind]
    items = []
    if cfg["local_root"]:
        root = os.path.join(cfg["local_root"], sub)
        if not os.path.isdir(root):
            data = {"kind": kind, "folder": sub, "items": [], "locked": False, "error": f"{sub} not found under {cfg['local_root']}"}
        else:
            for dp, dn, fn in os.walk(root):
                dn[:] = [d for d in dn if not d.startswith("@") and not d.startswith(".")]
                for f in fn:
                    if f.startswith("."): continue
                    p = os.path.join(dp, f)
                    rel = os.path.relpath(p, root).replace(os.sep, "/")
                    items.append((rel, os.path.getsize(p), os.path.getmtime(p)))
            data = {"kind": kind, "folder": sub, "locked": False, "error": None}
    else:
        st = library_state()
        dstate = (st.get("dirs") or {}).get(kind)
        if not st["reachable"]:
            data = {"kind": kind, "folder": sub, "items": [], "locked": None, "state": st.get("state"),
                    "error": st.get("error") or "NAS unreachable"}
        elif st["locked"]:
            data = {"kind": kind, "folder": sub, "items": [], "locked": True, "state": "locked", "error": None}
        elif dstate == "missing":
            data = {"kind": kind, "folder": sub, "items": [], "locked": False, "state": st["state"],
                    "error": f"{sub} folder does not exist on the share (share is {st['state']})"}
        elif dstate == "noperm":
            data = {"kind": kind, "folder": sub, "items": [], "locked": False, "state": st["state"],
                    "error": f"{sub} is not readable by {st.get('user', 'the NAS user')} (permissions)"}
        else:
            base = os.path.join(cfg["share"], sub)
            cmd = (f"cd {shell_quote(base)} || {{ echo MMX_NOFOLDER; exit 0; }}; "
                   f"find . -path '*/@eaDir' -prune -o -type f -printf '%P\\t%s\\t%T@\\n'")
            try:
                rc, out, err = nas_run(cmd, timeout=90)
            except subprocess.TimeoutExpired:
                rc, out, err = 124, "", "listing timed out after 90s"
            print(f"[nas] list {kind} rc={rc} lines={len(out.splitlines())} err={err.strip()[-200:]!r}", flush=True)
            if "MMX_NOFOLDER" in out:
                data = {"kind": kind, "folder": sub, "items": [], "locked": False, "state": st["state"],
                        "error": f"{sub} folder does not exist on the share"}
            elif rc != 0:
                e = err.strip().splitlines()[-1] if err.strip() else f"find rc={rc}"
                data = {"kind": kind, "folder": sub, "items": [], "locked": False, "state": st["state"],
                        "error": ("NAS ssh failed: " if rc == 255 else "listing failed: ") + e[-200:]}
            else:
                for line in out.splitlines():
                    parts = line.split("\t")
                    if len(parts) < 3: continue
                    rel = parts[0]
                    if os.path.basename(rel).startswith("."): continue
                    try: items.append((rel, int(parts[1]), float(parts[2])))
                    except ValueError: continue
                data = {"kind": kind, "folder": sub, "locked": False, "state": st["state"], "error": None}
    out_items = []
    for rel, size, mtime in items:
        k = classify(rel)
        if not k: continue
        path = f"{sub}/{rel}"
        out_items.append({"id": item_id(path), "path": path, "name": os.path.basename(rel),
                          "folder": os.path.dirname(rel), "kind": k, "size": size, "mtime": mtime})
    out_items.sort(key=lambda x: (x["folder"].lower(), x["name"].lower()))
    data["items"] = out_items
    data["count"] = len(out_items)
    data["listed_at"] = time.time()
    # only successful listings are cached: a locked/unreachable verdict is re-checked on every
    # request, so a Refresh right after unlocking sees the files
    with _lib_lock:
        if not data.get("error") and not data.get("locked"):
            _lib_cache[kind] = {"t": time.time(), "data": data}
        else:
            _lib_cache.pop(kind, None)   # a stale success must not outlive a locked/error verdict
    return data

def library_local_file(path):
    """The library file as a local path (fetched from the NAS into the cache once)."""
    cfg = _nas_config()
    if ".." in path.split("/") or path.startswith("/"):
        raise ValueError("bad library path")
    if cfg["local_root"]:
        p = os.path.join(cfg["local_root"], path)
        if not os.path.isfile(p): raise RuntimeError(f"library file missing: {path}")
        return p
    dest = os.path.join(cache_dir(), "lib", path)
    if not os.path.isfile(dest):
        try:
            nas_fetch(path, dest)
        except RuntimeError as e:
            st = library_state()
            if st.get("locked"):
                raise RuntimeError(f"NAS share is locked — unlock it in the vgo dashboard, then retry ({path})")
            if not st.get("reachable"):
                raise RuntimeError(f"NAS unreachable from the instance: {st.get('error')} ({path})")
            raise RuntimeError(f"{e} (share is {st.get('state')})")
    return dest

def library_thumb(path):
    """JPEG thumb bytes: the viewer's own thumb (share/_app/thumbs/t<id>.jpg) when it has one,
    otherwise generated here once with ffmpeg. Cached under the runner's cache dir."""
    if ".." in path.split("/") or path.startswith("/"):
        raise ValueError("bad library path")
    tdir = os.path.join(cache_dir(), "thumbs"); os.makedirs(tdir, exist_ok=True)
    out = os.path.join(tdir, item_id(path) + ".jpg")
    if os.path.isfile(out):
        return open(out, "rb").read()
    cfg = _nas_config()
    if not cfg["local_root"]:
        try:
            nas_fetch(f"_app/thumbs/t{item_id(path)}.jpg", out, timeout=60)
            return open(out, "rb").read()
        except Exception:
            pass
    src = library_local_file(path)
    kind = classify(path)
    cmd = ["ffmpeg", "-y", "-loglevel", "error"]
    if kind == "video": cmd += ["-ss", "1"]
    cmd += ["-i", src, "-frames:v", "1", "-vf", "scale=480:-2", out]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if (r.returncode != 0 or not os.path.isfile(out)) and kind == "video":
        # a seek past the end of a very short clip exits 0 without writing anything
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-frames:v", "1", "-vf", "scale=480:-2", out],
                           capture_output=True, text=True, timeout=120)
    if r.returncode != 0 or not os.path.isfile(out):
        raise RuntimeError("thumb generation failed: " + r.stderr.strip()[-200:])
    return open(out, "rb").read()


# ── job state ────────────────────────────────────────────────────────────────
def log(job, msg):
    line = time.strftime("%H:%M:%S ") + msg
    job["log"].append(line)
    if len(job["log"]) > 400:
        del job["log"][:100]
    print(f"[{job['id'][:8]}] {msg}", flush=True)

def upgrade_spec(spec):
    """Accept v1 specs (refs + first_frame) by mapping them onto v2 slots."""
    spec = dict(spec)
    if "slots" not in spec:
        images = []
        for i, r in enumerate(spec.get("refs") or []):
            if i + 1 >= FIRST_SLOT: break
            images.append({"slot": i + 1, "src": {"kind": "local", "name": r.get("name", ""), "data": r.get("data", "")}})
        ff = spec.get("first_frame")
        if ff:
            images.append({"slot": FIRST_SLOT, "src": {"kind": "local", "name": ff.get("name", ""), "data": ff.get("data", "")}})
        spec["slots"] = {"images": images, "videos": [], "audios": []}
        spec.setdefault("spec_version", 1)
    spec.setdefault("spec_version", 2)
    if spec.get("templates", {}).get("first") and not spec.get("template"):
        spec["template"] = spec["templates"]["first"]
    return spec

def slot_table(spec):
    """{'images': {slot: entry}, 'videos': {...}, 'audios': {...}} with validation."""
    out = {}
    for kind, cap in MAX_SLOTS.items():
        table = {}
        for e in (spec.get("slots") or {}).get(kind) or []:
            try: s = int(e.get("slot"))
            except Exception: raise ValueError(f"{kind}: slot must be an integer")
            if not 1 <= s <= cap: raise ValueError(f"{kind}: slot {s} out of range 1..{cap}")
            if s in table: raise ValueError(f"{kind}: slot {s} given twice")
            src = e.get("src") or {}
            if src.get("kind") == "local":
                if not src.get("data"): raise ValueError(f"{kind} slot {s}: local source has no data")
            elif src.get("kind") == "library":
                if not src.get("path"): raise ValueError(f"{kind} slot {s}: library source has no path")
            else:
                raise ValueError(f"{kind} slot {s}: src.kind must be 'local' or 'library'")
            table[s] = e
        out[kind] = table
    return out

def new_job(spec):
    jid = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:4]
    slots = spec.get("slots") or {}
    job = {
        "id": jid, "name": spec.get("name") or jid, "state": "queued", "phase": "",
        "spec_version": spec.get("spec_version", 2), "runner_version": VERSION,
        "created": time.time(), "started": None, "finished": None,
        "segments": [], "current": None, "progress": None, "log": [],
        "final": None, "error": None, "cancel": False, "spec_summary": {
            "segments": len(spec.get("segments", [])), "concat": bool(spec.get("concat")),
            "images": len(slots.get("images") or []), "videos": len(slots.get("videos") or []),
            "audios": len(slots.get("audios") or []),
            "continuation": (spec.get("options") or {}).get("continuation", "guide"),
            "has_next_template": bool((spec.get("templates") or {}).get("next")),
        },
    }
    for i, s in enumerate(spec.get("segments", [])):
        job["segments"].append({"index": i, "state": "pending", "prompt": s.get("prompt", ""),
                                "direction": None, "generated_prompt": None, "references": None,
                                "loras": s.get("loras") or [], "continuity_psnr": None, "guided": False,
                                "seconds": s.get("seconds"), "aspect": s.get("aspect"),
                                "seed": None, "prompt_id": None, "video": None, "lastframe": None,
                                "started": None, "finished": None, "error": None})
    return job

def public(job):
    return {k: v for k, v in job.items() if k not in ("cancel",)}


# ── references + tag remap ───────────────────────────────────────────────────
def build_references(images, videos, audios):
    """images/videos/audios: {slot: {"file": <comfy input name>, ...}}. Returns
    (references list for the RefPack node, tag map {"<Picture 3>": "<Picture 2>", ...},
    listing for the job state). Ordinals follow the node: per kind, 1-based over the
    compacted list in slot order; <Audio N> counts video soundtracks first."""
    refs, tagmap, listing = [], {}, []
    for pos, slot in enumerate(sorted(images), start=1):
        refs.append({"kind": "image", "file": images[slot]["file"]})
        tagmap[("picture", slot)] = f"<Picture {pos}>"
        listing.append({"slot_tag": f"<Picture {slot}>", "tag": f"<Picture {pos}>", "file": images[slot]["file"],
                        "label": images[slot].get("label", "")})
    audio_n = 0
    for pos, slot in enumerate(sorted(videos), start=1):
        v = videos[slot]
        use_st = bool(v.get("use_soundtrack", True))
        refs.append({"kind": "video", "file": v["file"], "use_soundtrack": use_st})
        tagmap[("video", slot)] = f"<Video {pos}>"
        entry = {"slot_tag": f"<Video {slot}>", "tag": f"<Video {pos}>", "file": v["file"], "label": v.get("label", "")}
        if use_st:
            audio_n += 1
            entry["soundtrack_tag"] = f"<Audio {audio_n}>"
        listing.append(entry)
    for pos, slot in enumerate(sorted(audios), start=1):
        audio_n += 1
        refs.append({"kind": "audio", "file": audios[slot]["file"]})
        tagmap[("audio", slot)] = f"<Audio {audio_n}>"
        listing.append({"slot_tag": f"<Audio {slot}>", "tag": f"<Audio {audio_n}>", "file": audios[slot]["file"],
                        "label": audios[slot].get("label", "")})
    return refs, tagmap, listing

def remap_prompt(prompt, tagmap, seg_label="segment"):
    """Rewrite UI-slot tags to the node's compacted ordinals. {{first}} = slot 9.
    Raises ValueError naming the first tag that points at an empty slot."""
    text = re.sub(r"\{\{\s*first\s*\}\}", f"<Picture {FIRST_SLOT}>", prompt, flags=re.I)
    missing = []
    def sub(m):
        kind, n = m.group(1).lower(), int(m.group(2))
        t = tagmap.get((kind, n))
        if t is None:
            missing.append(f"<{TAG_WORD[kind]} {n}>")
            return m.group(0)
        return t
    out = TAG_RE.sub(sub, text)
    if missing:
        uniq = sorted(set(missing), key=missing.index)
        raise ValueError(f"{seg_label}: {', '.join(uniq)} refer{'s' if len(uniq) == 1 else ''} to an empty slot")
    return out

def plan_segments(spec, uploaded=None):
    """Per segment: the remapped direction and reference listing, without touching ComfyUI.
    uploaded: {(kind, slot): comfy filename} once files exist; otherwise placeholder names."""
    tables = slot_table(spec)
    def entries(kind, tag):
        out = {}
        for slot, e in tables[kind].items():
            src = e.get("src") or {}
            name = (uploaded or {}).get((kind, slot)) or src.get("name") or src.get("path") or f"{tag}{slot}"
            out[slot] = {"file": name, "label": src.get("name") or src.get("path") or "",
                         "use_soundtrack": e.get("use_soundtrack", True)}
        return out
    images, videos, audios = entries("images", "img"), entries("videos", "vid"), entries("audios", "aud")
    plans, errors = [], []
    for i, seg in enumerate(spec.get("segments") or []):
        imgs = dict(images)
        if i > 0:
            imgs[FIRST_SLOT] = {"file": (uploaded or {}).get(("chain", i)) or f"seg{i:02d}_last.png",
                                "label": f"last frame of segment {i}", "use_soundtrack": False}
        refs, tagmap, listing = build_references(imgs, videos, audios)
        try:
            direction = remap_prompt(seg.get("prompt", ""), tagmap, f"segment {i+1}")
        except ValueError as e:
            errors.append(str(e)); direction = None
        plans.append({"index": i, "prompt": direction, "references": refs, "listing": listing,
                      "guided": i > 0 and (spec.get("options") or {}).get("continuation", "guide") != "none"})
    return plans, errors


# ── template patching ────────────────────────────────────────────────────────
def size_for(aspect, megapixels, multiple=32):
    ar = ASPECTS.get(aspect) or float(aspect.split(":")[0]) / float(aspect.split(":")[1])
    total = float(megapixels) * 1_000_000
    w = (total * ar) ** 0.5
    h = w / ar
    r = lambda v: max(multiple, int(round(v / multiple)) * multiple)
    return r(w), r(h)

def inject_guide(p, m, first_file):
    """Continuation: anchor the previous last frame as a hard keyframe at frame 0 via
    MiniMaxH3AddGuide, wired between the reference node's conditioning and every consumer
    of it (BasicGuider). References stay for identity/audio. Returns the node id used."""
    r2v = m["ref2video"]
    vae_ref = p[r2v]["inputs"].get("vae")
    if not isinstance(vae_ref, list):
        raise RuntimeError("continuation: reference node has no vae link to reuse for the guide")
    gid, iid = m["guide"], m["guide_image"]
    while gid in p: gid = str(int(gid) + 2)
    while iid in p or iid == gid: iid = str(int(iid) + 2)
    for nid, node in p.items():
        for k, v in list(node.get("inputs", {}).items()):
            if isinstance(v, list) and len(v) == 2 and str(v[0]) == r2v and v[1] == 0:
                node["inputs"][k] = [gid, 0]
    p[iid] = {"class_type": "LoadImage", "inputs": {"image": first_file}, "_meta": {"title": "mmx continuation frame"}}
    p[gid] = {"class_type": "MiniMaxH3AddGuide", "_meta": {"title": "mmx first-frame guide"},
              "inputs": {"positive": [r2v, 0], "latent": [r2v, 1], "vae": vae_ref, "image": [iid, 0], "frame_idx": 0}}
    return gid

def build_prompt(template, mapping, seg, images, videos, audios, seed, opts, prefix, seg_index, first_file, key):
    p = copy.deepcopy(template)
    m = {**DEFAULT_MAP, **(mapping or {})}
    for need in ("refpack", "ref2video", "duration", "seed", "video", "lastframe"):
        if m[need] not in p:
            raise RuntimeError(f"template has no node {m[need]} ({need})")
    rp, r2v = p[m["refpack"]]["inputs"], p[m["ref2video"]]["inputs"]

    refs, tagmap, listing = build_references(images, videos, audios)
    rp["references_json"] = json.dumps({"references": refs})
    direction = remap_prompt(seg["prompt"], tagmap, f"segment {seg_index+1}")
    rp["direction"] = direction

    # prompt provider: passthrough by default, openrouter opt-in. The key comes from the
    # runner's environment (never from the template) and is written into the node so
    # ComfyUI's own env doesn't matter.
    ap = opts.get("auto_prompt") or {}
    if ap.get("enabled"):
        rp["prompt_provider"] = "openrouter"
        rp["openrouter_api_key"] = key
        if ap.get("model"): rp["openrouter_model"] = ap["model"]
        if ap.get("reasoning"): rp["reasoning_effort"] = ap["reasoning"]
    else:
        rp["prompt_provider"] = "none"
        rp["openrouter_api_key"] = ""
    p.pop(m["apikey"], None)

    # size: literals into both consumers, drop the selector node
    w, h = size_for(seg.get("aspect") or opts.get("aspect") or "16:9",
                    seg.get("megapixels") or opts.get("megapixels") or 0.7)
    for node in (rp, r2v):
        node["width"], node["height"] = w, h
    p.pop(m["resolution"], None)

    # duration + seed
    p[m["duration"]]["inputs"]["value"] = float(seg.get("seconds") or opts.get("seconds") or 5)
    p[m["seed"]]["inputs"]["noise_seed"] = int(seed)

    # per-segment LoRAs -> lora_2, lora_3 … on the Power Lora Loader; lora_1 (acc) untouched
    loras = [l for l in (seg.get("loras") or []) if l.get("name")]
    if loras:
        ln = p.get(m["loras"])
        if not ln: raise RuntimeError(f"segment {seg_index+1} has LoRAs but the template has no node {m['loras']} (Power Lora Loader)")
        for k in [k for k in ln["inputs"] if re.fullmatch(r"lora_\d+", k) and k != "lora_1"]:
            ln["inputs"].pop(k)
        for j, l in enumerate(loras, start=2):
            ln["inputs"][f"lora_{j}"] = {"on": True, "lora": l["name"], "strength": float(l.get("strength", 0.85))}

    # continuation (segments 2+): hard first-frame guide, optional UNET swap
    guided = False
    if seg_index > 0 and first_file and opts.get("continuation", "guide") == "guide" and not opts.get("_has_next_template"):
        inject_guide(p, m, first_file)
        guided = True
    if seg_index > 0 and opts.get("continuation_unet") and m["unet"] in p:
        p[m["unet"]]["inputs"]["unet_name"] = opts["continuation_unet"]

    # output naming: mmx/<job>/segNN
    p[m["video"]]["inputs"]["filename_prefix"] = prefix
    if opts.get("fps"): p[m["video"]]["inputs"]["frame_rate"] = int(opts["fps"])
    p[m["lastframe"]]["inputs"]["filename_prefix"] = prefix + "_last"
    return p, {"size": (w, h), "direction": direction, "listing": listing, "guided": guided, "loras": loras}


# ── waiting on ComfyUI ───────────────────────────────────────────────────────
def wait_for(job, prompt_id, seg):
    """Poll /history until the prompt lands; surface queue position + progress."""
    t0 = time.time()
    last_note = 0
    while True:
        if job["cancel"]:
            try: comfy("/interrupt", data={}, method="POST")
            except Exception: pass
            raise RuntimeError("cancelled")
        try:
            h = comfy(f"/history/{prompt_id}", timeout=15)
        except Exception as e:
            h = {}
            if time.time() - last_note > 30:
                log(job, f"history poll error: {e}"); last_note = time.time()
        if prompt_id in h:
            entry = h[prompt_id]
            st = entry.get("status", {})
            if st.get("status_str") == "error" or st.get("completed") is False and st.get("status_str"):
                msgs = [x for x in st.get("messages", []) if x and x[0] == "execution_error"]
                detail = (msgs[-1][1].get("exception_message") if msgs else None) or st.get("status_str")
                raise RuntimeError(f"ComfyUI execution error: {detail}")
            return entry
        try:
            q = comfy("/queue", timeout=10)
            running = [x for x in q.get("queue_running", []) if x[1] == prompt_id]
            pending = [i for i, x in enumerate(q.get("queue_pending", [])) if x[1] == prompt_id]
            if running: job["phase"] = "rendering"
            elif pending: job["phase"] = f"queued (position {pending[0]+1})"
            elif time.time() - t0 > 20:
                raise RuntimeError("prompt disappeared from queue without a history entry (ComfyUI crashed?)")
        except RuntimeError:
            raise
        except Exception:
            pass
        job["progress"] = {"elapsed": int(time.time() - t0)}
        time.sleep(3)


def ws_progress_thread(job):
    """Best-effort: attach to ComfyUI /ws and mirror progress into job['progress']."""
    import socket, struct
    try:
        u = urllib.parse.urlparse(COMFY)
        s = socket.create_connection((u.hostname, u.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall((f"GET /ws?clientId=mmx{job['id'][-4:]} HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        s.settimeout(None)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk: return
            buf += chunk
        buf = buf.split(b"\r\n\r\n", 1)[1]
        while job["state"] == "running":
            while True:
                if len(buf) < 2: break
                b1, b2 = buf[0], buf[1]; op = b1 & 0x0F; ln = b2 & 0x7F; i = 2
                if ln == 126:
                    if len(buf) < 4: break
                    ln = struct.unpack("!H", buf[2:4])[0]; i = 4
                elif ln == 127:
                    if len(buf) < 10: break
                    ln = struct.unpack("!Q", buf[2:10])[0]; i = 10
                if len(buf) < i + ln: break
                payload = buf[i:i+ln]; buf = buf[i+ln:]
                if op == 1:
                    try:
                        msg = json.loads(payload.decode())
                        t, d = msg.get("type"), msg.get("data", {})
                        prog = job.get("progress") or {}
                        if t == "progress":
                            prog.update({"step": d.get("value"), "steps": d.get("max"), "node": d.get("node")})
                        elif t == "executing" and d.get("node"):
                            prog.update({"node": d.get("node"), "step": None, "steps": None})
                        job["progress"] = prog
                    except Exception:
                        pass
                elif op == 8:
                    return
            chunk = s.recv(65536)
            if not chunk: return
            buf += chunk
    except Exception:
        return


# ── the chain ────────────────────────────────────────────────────────────────
def pick_outputs(entry, video_node, last_node, display_node):
    outs = entry.get("outputs", {})
    vid = None
    for key in ("gifs", "videos", "images"):
        lst = outs.get(video_node, {}).get(key)
        if lst: vid = lst[0]; break
    last = (outs.get(last_node, {}).get("images") or [None])[0]
    text = outs.get(display_node, {}).get("text")
    if isinstance(text, list): text = "\n".join(str(t) for t in text)
    elif text is not None: text = str(text)
    return vid, last, text

def src_bytes(src):
    """Bytes + suggested extension for a slot source (local base64 or NAS library path)."""
    if src.get("kind") == "library":
        p = library_local_file(src["path"])
        return open(p, "rb").read(), os.path.splitext(p)[1].lower()
    ext = os.path.splitext(src.get("name", ""))[1].lower()
    return base64.b64decode(src["data"]), ext

def upload_slots(job, spec, tables):
    """Upload every occupied slot once. Returns {'images': {slot: {...}}, ...} with comfy filenames."""
    out = {"images": {}, "videos": {}, "audios": {}}
    defaults = {"images": ".png", "videos": ".mp4", "audios": ".wav"}
    for kind in ("images", "videos", "audios"):
        for slot, e in sorted(tables[kind].items()):
            src = e["src"]
            if src.get("kind") == "library":
                job["phase"] = f"fetching {src['path']} from NAS"
            data, ext = src_bytes(src)
            name = f"mmx_{job['id']}_{ {'images': 'img', 'videos': 'vid', 'audios': 'aud'}[kind]}{slot}{ext or defaults[kind]}"
            stored = comfy_upload(name, data)
            out[kind][slot] = {"file": stored, "label": src.get("name") or src.get("path") or "",
                               "use_soundtrack": bool(e.get("use_soundtrack", True))}
    return out

def psnr(ref_png, video_path):
    """PSNR (dB) between a PNG and the first decoded frame of a video, via ffmpeg. None on failure."""
    try:
        first = video_path + ".first.png"
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video_path, "-frames:v", "1", first],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0: return None
        r = subprocess.run(["ffmpeg", "-loglevel", "info", "-i", first, "-i", ref_png,
                            "-lavfi", "[0:v][1:v]scale2ref[a][b];[a][b]psnr", "-f", "null", "-"],
                           capture_output=True, text=True, timeout=120)
        m = re.search(r"average:(inf|[\d.]+)", r.stderr)
        if not m: return None
        return 99.0 if m.group(1) == "inf" else round(float(m.group(1)), 2)
    except Exception:
        return None

def validate_loras(spec):
    names = []
    for seg in spec.get("segments") or []:
        for l in seg.get("loras") or []:
            if l.get("name"): names.append(l["name"])
    if not names: return
    have = set(model_lists(fresh=True).get("loras") or [])
    missing = [n for n in names if n not in have]
    if missing:
        raise RuntimeError("LoRA not on this instance: " + ", ".join(sorted(set(missing))) +
                           " — copy it to ComfyUI/models/loras (or pull it from Drive via vgo) and Refresh")

def run_job(job, spec):
    job["state"] = "running"; job["started"] = time.time()
    threading.Thread(target=ws_progress_thread, args=(job,), daemon=True).start()
    m = {**DEFAULT_MAP, **(spec.get("mapping") or {})}
    templates = spec.get("templates") or {}
    t_first = templates.get("first") or spec["template"]
    t_next = templates.get("next")
    opts = dict(spec.get("options") or {})
    opts["_has_next_template"] = bool(t_next)
    key = openrouter_key()
    work = tempfile.mkdtemp(prefix="mmx_job_")
    try:
        tables = slot_table(spec)
        validate_loras(spec)
        # 1. upload every slot once
        job["phase"] = "uploading references"
        up = upload_slots(job, spec, tables)
        log(job, f"uploaded {len(up['images'])} images, {len(up['videos'])} videos, {len(up['audios'])} audios")
        if (opts.get("auto_prompt") or {}).get("enabled") and not key:
            raise RuntimeError("auto-prompt is on but no OpenRouter key is set (OPENROUTER_API_KEY / OPENROUTER_KEY / LLM_KEY)")

        # 2. seed policy
        seed_mode = opts.get("seed_mode", "increment")
        base_seed = int(opts.get("seed") or random.randint(1, 2**48))

        # 3. segments
        segs = spec["segments"]
        chain_file, chain_png = None, None
        for i, seg in enumerate(segs):
            S = job["segments"][i]
            if job["cancel"]: raise RuntimeError("cancelled")
            seed = (base_seed if seed_mode == "fixed" else base_seed + i if seed_mode == "increment"
                    else random.randint(1, 2**48))
            if seg.get("seed"): seed = int(seg["seed"])
            S.update(state="running", seed=seed, started=time.time())
            job["current"] = i; job["phase"] = "submitting"
            prefix = f"mmx/{job['name']}/seg{i+1:02d}"
            images = dict(up["images"])
            if i > 0:
                images[FIRST_SLOT] = {"file": chain_file, "label": f"last frame of segment {i}"}
            template = t_first if i == 0 else (t_next or t_first)
            prompt, info = build_prompt(template, m, seg, images, up["videos"], up["audios"], seed, opts, prefix,
                                        i, chain_file, key)
            S.update(direction=info["direction"], references=info["listing"], guided=info["guided"])
            res = comfy("/prompt", data={"prompt": prompt, "client_id": f"mmx{job['id'][-4:]}"}, timeout=60)
            if res.get("node_errors"):
                raise RuntimeError(summarize_node_errors(res, prompt) +
                                   "  (fix the named input — usually a model filename that isn't on this instance)")
            if "prompt_id" not in res:
                raise RuntimeError(f"/prompt rejected: {json.dumps(res)[:600]}")
            S["prompt_id"] = res["prompt_id"]
            w, h = info["size"]
            log(job, f"seg {i+1}/{len(segs)} submitted {w}x{h} {seg.get('seconds')}s seed={seed} "
                     f"refs={len(info['listing'])}{' guided' if info['guided'] else ''}"
                     f"{' loras=' + ','.join(l['name'] for l in info['loras']) if info['loras'] else ''} id={res['prompt_id'][:8]}")
            entry = wait_for(job, res["prompt_id"], S)
            vid, last, text = pick_outputs(entry, m["video"], m["lastframe"], m["display"])
            if not vid:
                raise RuntimeError(f"segment {i+1} finished but produced no video output — ComfyUI ran only part of the graph; "
                                   f"check its log for 'Failed to validate prompt' (executed nodes: {sorted(entry.get('outputs', {}).keys())})")
            if not last: raise RuntimeError(f"segment {i+1} finished but produced no last-frame image")
            S.update(video=vid, lastframe=last, generated_prompt=text, state="done", finished=time.time())
            log(job, f"seg {i+1} done: {vid.get('filename')} ({int(time.time()-S['started'])}s)")
            # continuity measurement: previous last frame vs this segment's first decoded frame
            if i > 0 and chain_png:
                try:
                    vp = os.path.join(work, f"seg{i+1:02d}.mp4")
                    open(vp, "wb").write(comfy_bytes(view_url(vid["filename"], vid.get("subfolder", ""), vid.get("type", "output")), timeout=600))
                    S["continuity_psnr"] = psnr(chain_png, vp)
                    log(job, f"seg {i+1} first-frame continuity PSNR: {S['continuity_psnr'] if S['continuity_psnr'] is not None else 'n/a'} dB")
                except Exception as e:
                    log(job, f"psnr check skipped: {e}")
            # 4. last frame -> next segment's slot 9 + guide (via API, path-agnostic)
            if i + 1 < len(segs):
                job["phase"] = "chaining last frame"
                png = comfy_bytes(view_url(last["filename"], last.get("subfolder", ""), last.get("type", "output")))
                chain_png = os.path.join(work, f"seg{i+1:02d}_last.png"); open(chain_png, "wb").write(png)
                chain_file = comfy_upload(f"mmx_{job['id']}_seg{i+1:02d}_last.png", png)

        # 5. concat
        if spec.get("concat") and len(segs) > 1:
            job["phase"] = "concatenating"
            job["final"] = concat(job, [s["video"] for s in job["segments"]])
        job["state"] = "done"; job["phase"] = "complete"
        log(job, "chain complete")
    except Exception as e:
        job["error"] = str(e)
        job["state"] = "cancelled" if str(e) == "cancelled" else "failed"
        job["phase"] = job["state"]
        cur = job.get("current")
        if cur is not None and job["segments"][cur]["state"] == "running":
            job["segments"][cur].update(state=job["state"], error=str(e), finished=time.time())
        log(job, f"{job['state']}: {e}")
    finally:
        job["finished"] = time.time()
        shutil.rmtree(work, ignore_errors=True)


def kill_predecessors():
    """SIGTERM every other python process whose cmdline mentions mmx_runner.py (no fuser/lsof needed)."""
    import signal
    killed = []
    me = os.getpid()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me: continue
        try:
            argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        except Exception:
            continue
        if argv and os.path.basename(argv[0]).startswith(b"python") and any(a.endswith(b"mmx_runner.py") for a in argv[1:3]):
            try: os.kill(int(pid), signal.SIGTERM); killed.append(int(pid))
            except Exception: pass
    return killed

def output_dir():
    env = os.environ.get("COMFY_OUTPUT")
    for d in ([env] if env else []) + OUTPUT_CANDIDATES:
        if d and os.path.isdir(d): return d
    return None

def probe_size(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0", path], capture_output=True, text=True)
    try:
        w, h = r.stdout.strip().split(",")[:2]; return int(w), int(h)
    except Exception:
        return (0, 0)

def concat(job, videos):
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found on instance; concat skipped")
    work = tempfile.mkdtemp(prefix="mmx_concat_")
    paths = []
    for i, v in enumerate(videos):
        data = comfy_bytes(view_url(v["filename"], v.get("subfolder", ""), v.get("type", "output")), timeout=600)
        p = os.path.join(work, f"seg{i+1:02d}.mp4")
        open(p, "wb").write(data); paths.append(p)
    lst = os.path.join(work, "list.txt")
    open(lst, "w").write("".join(f"file '{p}'\n" for p in paths))
    out_dir = output_dir()
    sub = os.path.join("mmx", job["name"])
    final_name = f"{job['name']}_final.mp4"
    dest = os.path.join(out_dir, sub, final_name) if out_dir else os.path.join(work, final_name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    sizes = [probe_size(p) for p in paths]
    if len(set(sizes)) > 1:
        W, H = sizes[0]
        log(job, f"mixed segment sizes {sizes} -> letterboxing to {W}x{H}")
        fc = "".join(f"[{i}:v]scale={W}:{H}:force_original_aspect_ratio=decrease,"
                     f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,setsar=1[v{i}];" for i in range(len(paths)))
        fc += "".join(f"[v{i}][{i}:a]" for i in range(len(paths))) + f"concat=n={len(paths)}:v=1:a=1[v][a]"
        cmd = ["ffmpeg", "-y", "-loglevel", "error"] + sum([["-i", p] for p in paths], []) + \
              ["-filter_complex", fc, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "14",
               "-pix_fmt", "yuv420p", "-c:a", "aac", dest]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("concat (letterbox) failed: " + r.stderr.strip()[-300:])
    else:
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", dest]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            log(job, "stream-copy concat failed, re-encoding: " + r.stderr.strip()[-200:])
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst,
                   "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "-c:a", "aac", dest]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError("concat failed: " + r.stderr.strip()[-300:])
    log(job, f"final: {dest}")
    if out_dir:
        return {"filename": final_name, "subfolder": sub, "type": "output", "path": dest}
    return {"path": dest, "note": "ComfyUI output dir not found; final left in temp dir"}


# ── HTTP ─────────────────────────────────────────────────────────────────────
def check_spec(spec):
    for k in ("template", "segments"):
        if k not in spec: raise ValueError(f"spec missing '{k}'")
    if not isinstance(spec["template"], dict) or not spec["template"]:
        raise ValueError("template must be a non-empty API-format graph")
    if not spec["segments"]: raise ValueError("no segments")
    slot_table(spec)

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self._cors()
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def _bytes(self, data, ctype, cache=None):
        self.send_response(200); self._cors()
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        if cache: self.send_header("Cache-Control", cache)
        self.end_headers(); self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/health":
            ok = True
            try: comfy("/system_stats", timeout=5)
            except Exception: ok = False
            cfg = _nas_config()
            return self._json({"ok": True, "version": VERSION, "comfy": ok, "ffmpeg": bool(shutil.which("ffmpeg")),
                               "openrouter_key": bool(openrouter_key()),
                               "nas": {"configured": bool(cfg["local_root"]) or os.path.exists(cfg["key"]),
                                       "mode": "local" if cfg["local_root"] else "nas", "kinds": library_kinds()},
                               "output_dir": output_dir(), "jobs": len(JOBS), "pid": os.getpid()})
        if u.path == "/models":
            return self._json(model_lists(fresh=q.get("fresh", ["0"])[0] == "1"))
        if u.path == "/library/state":
            try: return self._json(library_state())
            except Exception as e: return self._json({"configured": False, "error": str(e)}, 500)
        if u.path == "/library":
            try:
                return self._json(library_list(q.get("kind", [""])[0].lower(), fresh=q.get("fresh", ["0"])[0] == "1"))
            except ValueError as e:
                return self._json({"error": str(e)}, 400)
            except Exception as e:
                return self._json({"error": str(e)}, 502)
        if u.path == "/library/thumb":
            try:
                data = library_thumb(q.get("path", [""])[0])
            except ValueError as e:
                return self._json({"error": str(e)}, 400)
            except Exception as e:
                return self._json({"error": str(e)}, 502)
            return self._bytes(data, "image/jpeg", cache="private, max-age=3600")
        if u.path == "/jobs":
            return self._json([{k: j[k] for k in ("id", "name", "state", "phase", "created")} for j in JOBS.values()])
        if u.path.startswith("/job/"):
            j = JOBS.get(u.path.split("/")[2])
            return self._json(public(j)) if j else self._json({"error": "no such job"}, 404)
        if u.path == "/media":
            try:
                data = comfy_bytes(view_url(q.get("f", [""])[0], q.get("sub", [""])[0], q.get("type", ["output"])[0]), timeout=600)
            except Exception as e:
                return self._json({"error": str(e)}, 502)
            return self._bytes(data, mimetypes.guess_type(q.get("f", [""])[0])[0] or "application/octet-stream")
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if u.path in ("/job", "/validate"):
            try:
                spec = upgrade_spec(json.loads(raw))
                check_spec(spec)
            except Exception as e:
                return self._json({"error": f"bad spec: {e}"}, 400)
            plans, errors = plan_segments(spec)
            if u.path == "/validate":
                return self._json({"ok": not errors, "errors": errors, "spec_version": spec["spec_version"],
                                   "segments": [{"index": p["index"], "prompt": p["prompt"], "references": p["listing"],
                                                 "guided": p["guided"]} for p in plans]})
            if errors:
                return self._json({"error": "; ".join(errors)}, 400)
            job = new_job(spec)
            with JOBS_LOCK: JOBS[job["id"]] = job
            threading.Thread(target=run_job, args=(job, spec), daemon=True).start()
            return self._json({"job": job["id"]})
        if u.path.startswith("/job/") and u.path.endswith("/cancel"):
            j = JOBS.get(u.path.split("/")[2])
            if not j: return self._json({"error": "no such job"}, 404)
            j["cancel"] = True
            return self._json({"ok": True})
        self._json({"error": "not found"}, 404)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("MMX_PORT", 8190)))
    ap.add_argument("--comfy", default=os.environ.get("COMFY_URL", COMFY))
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--version", action="store_true")
    a = ap.parse_args()
    if a.version:
        print(VERSION); sys.exit(0)
    COMFY = a.comfy.rstrip("/")
    import signal
    PIDFILE = f"/tmp/mmx_runner_{a.port}.pid"
    try:
        old = int(open(PIDFILE).read().strip())
        if old != os.getpid():
            os.kill(old, signal.SIGTERM); time.sleep(0.6)
    except Exception:
        pass
    for attempt in range(10):
        try:
            srv = http.server.ThreadingHTTPServer((a.bind, a.port), H); break
        except OSError:
            if attempt == 0:
                print(f"[mmx] port {a.port} busy — replacing the old runner", flush=True)
                try:
                    old_pid = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{a.port}/health", timeout=3).read()).get("pid")
                    if old_pid: os.kill(int(old_pid), signal.SIGTERM)
                except Exception:
                    pass
                for pid in kill_predecessors():
                    print(f"[mmx] stopped previous runner pid {pid}", flush=True)
            time.sleep(0.7)
    else:
        sys.exit(f"[mmx] could not bind port {a.port}")
    open(PIDFILE, "w").write(str(os.getpid()))
    key = openrouter_key()
    src = next((k for k in KEY_ENV if os.environ.get(k, "").strip()), None)
    print("[mmx] OpenRouter key: " + (f"present from {src} (…{key[-4:]})" if key else
                                     "NOT set — auto-prompt will fail, passthrough only"), flush=True)
    cfg = _nas_config()
    print(f"[mmx] library: " + (f"local root {cfg['local_root']}" if cfg["local_root"] else
                                f"{cfg['userhost']}:{cfg['share']} key={'ok' if os.path.exists(cfg['key']) else 'MISSING'} "
                                f"proxy={'on' if cfg['proxy'] != 'none' else 'off'}") + f" kinds={library_kinds()}", flush=True)
    print(f"[mmx] runner v{VERSION} pid {os.getpid()} on {a.bind}:{a.port} -> ComfyUI {COMFY}", flush=True)
    srv.daemon_threads = True
    srv.serve_forever()
