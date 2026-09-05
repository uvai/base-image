#!/usr/bin/env python3
"""Segment-1 first-frame A/B on a runner: slot 9 as guide AND reference ("guide+ref") versus
slot 9 as guide only ("guide"). One short segment per mode, same seed, same prompt.

    python3 live_ab_first_frame.py http://127.0.0.1:18390 --slot1 Subjects/jj/j1.jpg --slot9 Subjects/jj/j2.jpg \
        [--seconds 2] [--mp 0.2] [--auto] [--acc-off] [--out /tmp/ab]

Sources are NAS library paths by default (--local to read local files instead). Reports per mode:
PSNR(first decoded frame, slot-9 image) = framing fidelity, PSNR(first frame, slot-1 image) as a
control, the generated prompt, and writes side-by-side PNGs (slot9 | frame0 | frame at 1s) for a
visual identity check.
"""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.request

def api(base, path, data=None, raw=False, timeout=600):
    req = urllib.request.Request(base + path, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json"} if data is not None else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        b = r.read(); return b if raw else json.loads(b)

def psnr(a, b):
    r = subprocess.run(["ffmpeg", "-loglevel", "info", "-i", a, "-i", b, "-lavfi", "[0:v][1:v]scale2ref[x][y];[x][y]psnr", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.search(r"average:(inf|[\d.]+)", r.stderr)
    return None if not m else (99.0 if m.group(1) == "inf" else float(m.group(1)))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runner"); ap.add_argument("--slot1", required=True); ap.add_argument("--slot9", required=True)
    ap.add_argument("--seconds", type=float, default=2); ap.add_argument("--mp", type=float, default=0.2)
    ap.add_argument("--auto", action="store_true", help="auto-prompt on (OpenRouter)"); ap.add_argument("--model", default="google/gemini-3-flash-preview")
    ap.add_argument("--acc-off", action="store_true", help="switch lora_1 (acc LoRA) off in the template")
    ap.add_argument("--local", action="store_true", help="slot paths are local files, sent as base64")
    ap.add_argument("--template", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "MiniMax - R2V - Auto Prompt v6 API v2.json"))
    ap.add_argument("--out", default="/tmp/mmx_ab"); ap.add_argument("--seed", type=int, default=4242)
    ap.add_argument("--prompt", default="<Picture 1> is the subject. A calm medium shot: the subject looks at the camera, breathes, blinks and gives a small nod. Static camera, natural light.")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    t = json.load(open(a.template)); t.get("193", {}).get("inputs", {}).pop("value", None)
    if a.acc_off and "137" in t: t["137"]["inputs"]["lora_1"]["on"] = False
    def src(p):
        if a.local: return {"kind": "local", "name": os.path.basename(p), "data": base64.b64encode(open(p, "rb").read()).decode()}
        return {"kind": "library", "path": p}
    # the slot-9 image itself, for the PSNR reference (fetched through the runner in library mode)
    slot9_png = os.path.join(a.out, "slot9.png")
    if a.local: subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", a.slot9, slot9_png], check=True)
    else:
        open(os.path.join(a.out, "slot9_thumb.jpg"), "wb").write(api(a.runner, "/library/thumb?path=" + urllib.request.quote(a.slot9), raw=True))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", os.path.join(a.out, "slot9_thumb.jpg"), slot9_png], check=True)
    slot1_png = os.path.join(a.out, "slot1.png")
    if a.local: subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", a.slot1, slot1_png], check=True)
    else:
        open(os.path.join(a.out, "slot1_thumb.jpg"), "wb").write(api(a.runner, "/library/thumb?path=" + urllib.request.quote(a.slot1), raw=True))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", os.path.join(a.out, "slot1_thumb.jpg"), slot1_png], check=True)
    results = {}
    for mode in ("guide+ref", "guide"):
        name = "ab_" + mode.replace("+", "_")
        spec = {"spec_version": 2, "name": name, "template": t, "concat": False,
                "slots": {"images": [{"slot": 1, "src": src(a.slot1)}, {"slot": 9, "src": src(a.slot9)}], "videos": [], "audios": []},
                "segments": [{"prompt": a.prompt + " <Picture 9> is the absolute first frame of the video.", "seconds": a.seconds, "aspect": "16:9", "megapixels": a.mp}],
                "options": {"seed": a.seed, "seed_mode": "fixed", "fps": 24, "continuation": "guide", "first_frame_mode": mode, "first_clause": True,
                            "auto_prompt": {"enabled": a.auto, "model": a.model}}}
        v = api(a.runner, "/validate", spec)
        print(f"[{mode}] validate ok={v['ok']} errors={v['errors']} direction={v['segments'][0]['prompt']!r} refs={[r['tag'] for r in v['segments'][0]['references']]}", flush=True)
        jid = api(a.runner, "/job", spec)["job"]
        t0 = time.time()
        while True:
            j = api(a.runner, f"/job/{jid}")
            if j["state"] in ("done", "failed", "cancelled"): break
            time.sleep(4)
        s = j["segments"][0]
        print(f"[{mode}] {j['state']} in {int(time.time()-t0)}s; error={j.get('error')}", flush=True)
        if j["state"] != "done": results[mode] = {"state": j["state"], "error": j.get("error")}; continue
        vid = s["video"]; mp4 = os.path.join(a.out, name + ".mp4")
        open(mp4, "wb").write(api(a.runner, "/media?" + urllib.parse.urlencode({"f": vid["filename"], "sub": vid.get("subfolder", ""), "type": vid.get("type", "output")}), raw=True))
        f0 = os.path.join(a.out, name + "_f0.png"); f1 = os.path.join(a.out, name + "_1s.png")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp4, "-frames:v", "1", f0], check=True)
        mid = max(0.1, min(1.0, a.seconds / 2))   # a frame part-way in (1 s, or the midpoint of shorter clips)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(mid), "-i", mp4, "-frames:v", "1", f1], check=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", slot9_png, "-i", f0, "-i", f1, "-filter_complex",
                        "[0:v]scale=-2:320[a];[1:v]scale=-2:320[b];[2:v]scale=-2:320[c];[a][b][c]hstack=3", os.path.join(a.out, name + "_compare.png")], check=True)
        results[mode] = {"psnr_f0_vs_slot9": psnr(f0, slot9_png), "psnr_f0_vs_slot1": psnr(f0, slot1_png), "psnr_mid_vs_slot9": psnr(f1, slot9_png),
                         "runner_psnr": s["continuity_psnr"], "guide_source": s["guide_source"], "refs": [r["tag"] for r in s["references"]],
                         "clause": s["clause"], "generated_prompt": s["generated_prompt"], "took_s": int(s["finished"] - s["started"])}
        print(f"[{mode}] PSNR frame0 vs slot9 = {results[mode]['psnr_f0_vs_slot9']}  vs slot1 = {results[mode]['psnr_f0_vs_slot1']}  frame@mid vs slot9 = {results[mode]['psnr_mid_vs_slot9']}  (runner: {s['continuity_psnr']})", flush=True)
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    print(json.dumps(results, indent=1)[:3000])

if __name__ == "__main__":
    import urllib.parse
    main()
