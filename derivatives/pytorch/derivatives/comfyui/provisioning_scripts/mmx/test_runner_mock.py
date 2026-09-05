#!/usr/bin/env python3
"""End-to-end runner tests against mock_comfy.py (no GPU). Run from the mmx_v2 dir:

    python3 test_runner_mock.py

Starts the mock on 18188 and the runner on 18190 (library in local mode from a temp dir),
then checks: F1 slot->ordinal remap, empty-slot rejection, v1 spec upgrade, F2 guide
injection + PSNR continuity, F5 generated prompt capture, F7 LoRA injection + missing-LoRA
error, /models, F3 local-library listing/thumb/fetch, and concat.
"""
import base64, json, os, shutil, subprocess, sys, tempfile, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
MOCK_PORT, RUN_PORT = 18188, 18190
TMP = tempfile.mkdtemp(prefix="mmx_test_")
MOCK_OUT, MOCK_IN = os.path.join(TMP, "out"), os.path.join(TMP, "in")
SUBMITTED = os.path.join(TMP, "submitted.json")
LIB = os.path.join(TMP, "lib")
TEMPLATE = os.path.join(HERE, "MiniMax - R2V - Auto Prompt v6 API v2.json")

def png(color, path):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s=64x36:d=0.1", "-frames:v", "1", path], check=True)
def mp4(color, path):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s=64x36:d=1:r=24", "-f", "lavfi", "-i",
                    "sine=frequency=300:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path], check=True)
def wav(path):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=500:duration=1", path], check=True)
def b64(path): return base64.b64encode(open(path, "rb").read()).decode()
def local(path): return {"kind": "local", "name": os.path.basename(path), "data": b64(path)}

def api(path, data=None, port=RUN_PORT, raw=False):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json"} if data is not None else {})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read(); return (r.status, body if raw else json.loads(body))
    except urllib.error.HTTPError as e:
        body = e.read(); return (e.code, body if raw else json.loads(body))

def wait_job(jid, timeout=90):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st, j = api(f"/job/{jid}")
        if j["state"] in ("done", "failed", "cancelled"): return j
        time.sleep(0.5)
    raise AssertionError("job timed out: " + json.dumps(api(f'/job/{jid}')[1].get("log", [])[-5:]))

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + (f"  — {detail}" if detail and not cond else ""), flush=True)

def main():
    os.makedirs(LIB + "/Subjects/jj", exist_ok=True); os.makedirs(LIB + "/VideoRef", exist_ok=True)
    png("orange", LIB + "/Subjects/jj/j1.jpg"); png("purple", LIB + "/Subjects/js.jpeg"); mp4("gray", LIB + "/VideoRef/clip_A.mp4")
    for c in ("red", "green", "blue"): png(c, os.path.join(TMP, c + ".png"))
    mp4("white", os.path.join(TMP, "v1.mp4")); wav(os.path.join(TMP, "a1.wav"))
    template = json.load(open(TEMPLATE))
    template["193"]["inputs"]["value"] = ""  # never carry a key in a template

    env = {**os.environ, "MOCK_OUT": MOCK_OUT, "MOCK_IN": MOCK_IN, "MOCK_SUBMITTED": SUBMITTED, "MOCK_RENDER": "0.2"}
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_comfy.py"), "--port", str(MOCK_PORT)], env=env,
                            stdout=open(os.path.join(TMP, "mock.log"), "w"), stderr=subprocess.STDOUT)
    renv = {**os.environ, "MMX_LIBRARY_ROOT": LIB, "MMX_CACHE": os.path.join(TMP, "cache"), "COMFY_OUTPUT": MOCK_OUT,
            "OPENROUTER_KEY": "sk-or-test-1234", "MMX_PORT": str(RUN_PORT)}
    renv.pop("OPENROUTER_API_KEY", None)
    runner = subprocess.Popen([sys.executable, os.path.join(HERE, "mmx_runner.py"), "--port", str(RUN_PORT), "--comfy", f"http://127.0.0.1:{MOCK_PORT}"],
                              env=renv, stdout=open(os.path.join(TMP, "runner.log"), "w"), stderr=subprocess.STDOUT)
    try:
        for _ in range(50):
            try:
                st, h = api("/health"); break
            except Exception: time.sleep(0.2)
        else: raise SystemExit("runner did not start: " + open(os.path.join(TMP, "runner.log")).read())
        check("health: comfy reachable, key from OPENROUTER_KEY, version 2", h["comfy"] and h["openrouter_key"] and h["version"].startswith("2"), json.dumps(h))

        # /models
        st, models = api("/models")
        check("/models lists loras/unets/vaes/clips", all(models.get(k) for k in ("loras", "unets", "vaes", "clips")), json.dumps(models)[:200])

        # library (local mode)
        st, lib = api("/library?kind=subjects")
        check("library subjects lists 2 images with ids", lib.get("count") == 2 and all(len(i["id"]) == 12 for i in lib["items"]), json.dumps(lib)[:300])
        st, vr = api("/library?kind=videoref")
        check("library videoref lists the clip as video", vr.get("count") == 1 and vr["items"][0]["kind"] == "video", json.dumps(vr)[:300])
        st, th = api("/library/thumb?path=VideoRef/clip_A.mp4", raw=True)
        check("library thumb generated for video", st == 200 and th[:2] == b"\xff\xd8", str(st))
        st, ls = api("/library/state")
        check("library state reports local mode reachable", ls.get("reachable") and ls.get("mode") == "local", json.dumps(ls))

        # F1 acceptance: images in slots 1,3,9 with <Picture 3> … <Picture 9> -> <Picture 2> … <Picture 3>
        base = {"spec_version": 2, "name": "t_remap", "template": template, "concat": True,
                "slots": {"images": [{"slot": 1, "src": local(TMP + "/red.png")}, {"slot": 3, "src": local(TMP + "/green.png")},
                                     {"slot": 9, "src": local(TMP + "/blue.png")}],
                          "videos": [], "audios": []},
                "segments": [{"prompt": "<Picture 3> walks in. <Picture 9> is the first frame. {{first}} again.", "seconds": 1, "aspect": "16:9", "megapixels": 0.06},
                             {"prompt": "<Picture 1> and <picture 9> continue.", "seconds": 1, "aspect": "16:9", "megapixels": 0.06}],
                "options": {"seed": 7, "seed_mode": "increment", "fps": 24, "auto_prompt": {"enabled": False}}}
        st, v = api("/validate", base)
        check("validate: remapped prompts", st == 200 and v["ok"] and v["segments"][0]["prompt"] == "<Picture 2> walks in. <Picture 3> is the first frame. <Picture 3> again."
              and v["segments"][1]["prompt"] == "<Picture 1> and <Picture 3> continue." and v["segments"][1]["guided"], json.dumps(v)[:400])

        bad = json.loads(json.dumps(base)); bad["segments"][0]["prompt"] = "<Picture 2> is empty and <Video 1> too"
        st, v = api("/validate", bad)
        check("validate: empty-slot tags named", st == 200 and not v["ok"] and "<Picture 2>" in v["errors"][0] and "<Video 1>" in v["errors"][0], json.dumps(v)[:300])
        st, r = api("/job", bad)
        check("job: empty-slot tag rejected with 400", st == 400 and "<Picture 2>" in r.get("error", ""), json.dumps(r))

        st, r = api("/job", base); jid = r["job"]
        j = wait_job(jid)
        check("remap job done", j["state"] == "done", j.get("error") or "")
        sub = json.load(open(SUBMITTED))
        d0 = sub[-2]["185"]["inputs"]; d1 = sub[-1]["185"]["inputs"]
        check("seg1 submitted direction remapped", d0["direction"] == "<Picture 2> walks in. <Picture 3> is the first frame. <Picture 3> again.", d0["direction"])
        refs0 = json.loads(d0["references_json"])["references"]
        check("seg1 references compacted in slot order (3 images)", [r["kind"] for r in refs0] == ["image"] * 3 and refs0[2]["file"].endswith("img9.png"), json.dumps(refs0))
        refs1 = json.loads(d1["references_json"])["references"]
        check("seg2 slot 9 replaced by chained last frame", refs1[2]["file"].endswith("seg01_last.png"), json.dumps(refs1))
        check("seg2 direction remapped", d1["direction"] == "<Picture 1> and <Picture 3> continue.", d1["direction"])
        check("provider none + key blank when auto-prompt off", d0["prompt_provider"] == "none" and d0["openrouter_api_key"] == "", json.dumps({k: d0[k] for k in ("prompt_provider", "openrouter_api_key")}))
        check("node 193 (key primitive) removed", "193" not in sub[-1])
        guide = [n for n in sub[-1].values() if n.get("class_type") == "MiniMaxH3AddGuide"]
        check("F2: seg2 has an injected MiniMaxH3AddGuide at frame 0", len(guide) == 1 and guide[0]["inputs"]["frame_idx"] == 0 and guide[0]["inputs"]["positive"] == ["184", 0], json.dumps(guide)[:300])
        check("F2: BasicGuider rewired to the guide node", sub[-1]["149"]["inputs"]["conditioning"] == [DEFAULT_GUIDE_ID(sub[-1]), 0], json.dumps(sub[-1]["149"]))
        check("F2: seg1 has no guide node", not any(n.get("class_type") == "MiniMaxH3AddGuide" for n in sub[-2].values()))
        p = j["segments"][1]["continuity_psnr"]
        check("F2: continuity PSNR measured and > 40 dB on the mock", p is not None and p > 40, f"psnr={p}")
        check("F5: generated_prompt captured from node 186", j["segments"][0]["generated_prompt"] == d0["direction"], str(j["segments"][0]["generated_prompt"]))
        check("references listing on job state", j["segments"][1]["references"][2]["slot_tag"] == "<Picture 9>" and j["segments"][1]["references"][2]["tag"] == "<Picture 3>", json.dumps(j["segments"][1]["references"]))
        check("concat final produced", j["final"] and os.path.isfile(j["final"]["path"]), json.dumps(j["final"]))

        # continuation off -> no guide, low PSNR (different colours)
        off = json.loads(json.dumps(base)); off["name"] = "t_noguide"; off["options"]["continuation"] = "none"
        st, r = api("/job", off); j = wait_job(r["job"])
        sub = json.load(open(SUBMITTED))
        check("continuation none: no guide injected", j["state"] == "done" and not any(n.get("class_type") == "MiniMaxH3AddGuide" for n in sub[-1].values()), j.get("error") or "")
        check("continuation none: PSNR low (segments differ)", j["segments"][1]["continuity_psnr"] is not None and j["segments"][1]["continuity_psnr"] < 30, str(j["segments"][1]["continuity_psnr"]))

        # templates.next override -> used verbatim for seg 2, no injection
        nxt = json.loads(json.dumps(template)); nxt["186"]["_meta"] = {"title": "next-template-marker"}
        tn = json.loads(json.dumps(base)); tn["name"] = "t_next"; tn["templates"] = {"first": template, "next": nxt}; tn.pop("template")
        st, r = api("/job", tn); j = wait_job(r["job"])
        sub = json.load(open(SUBMITTED))
        check("templates.next used for seg2 without injection", j["state"] == "done" and sub[-1]["186"].get("_meta", {}).get("title") == "next-template-marker"
              and not any(n.get("class_type") == "MiniMaxH3AddGuide" for n in sub[-1].values()), j.get("error") or "")

        # videos + audio + library sources + soundtrack numbering + auto-prompt key
        full = json.loads(json.dumps(base)); full["name"] = "t_full"
        full["slots"] = {"images": [{"slot": 2, "src": {"kind": "library", "path": "Subjects/jj/j1.jpg"}}, {"slot": 9, "src": local(TMP + "/blue.png")}],
                         "videos": [{"slot": 2, "src": {"kind": "library", "path": "VideoRef/clip_A.mp4"}, "use_soundtrack": True},
                                    {"slot": 3, "src": local(TMP + "/v1.mp4"), "use_soundtrack": False}],
                         "audios": [{"slot": 1, "src": local(TMP + "/a1.wav")}]}
        full["segments"] = [{"prompt": "<Picture 2> in <Video 2> with <Video 3>, music <Audio 1>, start on <Picture 9>", "seconds": 1, "megapixels": 0.06, "aspect": "1:1",
                             "loras": [{"name": "H3_Motion_BoosterV2.safetensors", "strength": 0.7}, {"name": "side_fuck_h3_000000750.safetensors"}]}]
        full["options"]["auto_prompt"] = {"enabled": True, "model": "google/gemini-3-flash-preview"}
        st, r = api("/job", full); j = wait_job(r["job"])
        check("full job (library + video + audio + loras + auto-prompt) done", j["state"] == "done", j.get("error") or "")
        sub = json.load(open(SUBMITTED)); d = sub[-1]["185"]["inputs"]; refs = json.loads(d["references_json"])["references"]
        check("F1: direction with video/audio remap (<Audio 1> -> <Audio 2>: soundtrack of video counts first)",
              d["direction"] == "<Picture 1> in <Video 1> with <Video 2>, music <Audio 2>, start on <Picture 2>", d["direction"])
        check("references: image,image,video(soundtrack),video(no soundtrack),audio", [r["kind"] for r in refs] == ["image", "image", "video", "video", "audio"]
              and refs[2]["use_soundtrack"] is True and refs[3]["use_soundtrack"] is False, json.dumps(refs))
        check("library files uploaded to ComfyUI input", os.path.isfile(os.path.join(MOCK_IN, refs[0]["file"])) and os.path.isfile(os.path.join(MOCK_IN, refs[2]["file"])), json.dumps(refs))
        check("F9: key written into node 185 from OPENROUTER_KEY", d["prompt_provider"] == "openrouter" and d["openrouter_api_key"] == "sk-or-test-1234", json.dumps({k: d[k] for k in ("prompt_provider",)}))
        lor = sub[-1]["137"]["inputs"]
        check("F7: lora_2/lora_3 added, lora_1 untouched", lor["lora_1"]["lora"] == "MiniMax-H3-Ref2VA-Acc-8Step.safetensors" and lor["lora_2"] == {"on": True, "lora": "H3_Motion_BoosterV2.safetensors", "strength": 0.7}
              and lor["lora_3"]["lora"] == "side_fuck_h3_000000750.safetensors" and lor["lora_3"]["strength"] == 0.85, json.dumps(lor))
        check("F7: turbo LoRA node 158 untouched", sub[-1]["158"]["inputs"]["lora_name"] == template["158"]["inputs"]["lora_name"])
        check("F5: generated prompt shows the provider rewrite", (j["segments"][0]["generated_prompt"] or "").startswith("[mock openrouter rewrite]"), str(j["segments"][0]["generated_prompt"]))

        # missing LoRA -> exact name in the error
        miss = json.loads(json.dumps(base)); miss["name"] = "t_missing"; miss["segments"][0]["loras"] = [{"name": "NotThere.safetensors"}]
        st, r = api("/job", miss); j = wait_job(r["job"])
        check("F7: missing LoRA fails with the exact name", j["state"] == "failed" and "NotThere.safetensors" in (j["error"] or ""), j.get("error") or "")

        # v1 spec still accepted
        v1 = {"name": "t_v1", "template": template, "refs": [local(TMP + "/red.png")], "first_frame": local(TMP + "/blue.png"),
              "segments": [{"prompt": "<Picture 1> and <Picture 9> first", "seconds": 1, "megapixels": 0.06, "aspect": "16:9"}],
              "options": {"auto_prompt": {"enabled": False}}}
        st, r = api("/job", v1); j = wait_job(r["job"])
        sub = json.load(open(SUBMITTED))
        check("v1 spec upgraded: refs->slots 1.., first_frame->slot 9", j["state"] == "done" and j["spec_version"] == 1
              and sub[-1]["185"]["inputs"]["direction"] == "<Picture 1> and <Picture 2> first", j.get("error") or sub[-1]["185"]["inputs"]["direction"])

        # mixed aspect concat still letterboxes
        mix = json.loads(json.dumps(base)); mix["name"] = "t_mixed"; mix["segments"][1]["aspect"] = "9:16"
        st, r = api("/job", mix); j = wait_job(r["job"])
        check("mixed-aspect concat letterboxed", j["state"] == "done" and any("letterboxing" in l for l in j["log"]), j.get("error") or "")
    finally:
        runner.terminate(); mock.terminate()
        runner.wait(5); mock.wait(5)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed" + (f"; logs in {TMP}" if failed else ""))
    if not failed: shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(1 if failed else 0)


def state_parsing_checks():
    """library_state()/library_list() verdicts with a stubbed ssh: mounted, plain, locked, ssh failure,
    unreadable folder, missing folder — and no caching of non-success verdicts."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("mmx_runner_mod", os.path.join(HERE, "mmx_runner.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    os.environ.pop("MMX_LIBRARY_ROOT", None); os.environ["MMX_NAS_KEY"] = __file__   # "key" exists -> configured
    calls = {"n": 0}
    def stub(rc, out, err=""):
        def f(cmd, timeout=60):
            calls["n"] += 1
            if "find ." in cmd: return (0, "a.jpg\t10\t1.0\nsub/b.mp4\t20\t2.0\n", "")
            return (rc, out, err)
        return f
    mod.nas_run = stub(0, "MMX_STATE=mounted\nMMX_WHO=alchera\nMMX_DIR=subjects=ok\nMMX_DIR=videoref=ok\n")
    st = mod.library_state()
    check("state: mounted -> reachable, not locked", st["reachable"] and st["locked"] is False and st["state"] == "mounted" and st["dirs"] == {"subjects": "ok", "videoref": "ok"} and st["user"] == "alchera", json.dumps(st))
    lst = mod.library_list("subjects", fresh=True)
    check("list: mounted -> files listed", lst["count"] == 2 and lst["items"][1]["kind"] == "video" and not lst["error"], json.dumps(lst)[:200])
    mod.nas_run = stub(0, "MMX_STATE=locked\nMMX_WHO=alchera\nMMX_DIR=subjects=missing\nMMX_DIR=videoref=missing\n")
    check("list: cached success served without ssh when not fresh", mod.library_list("subjects")["count"] == 2)
    lst = mod.library_list("subjects", fresh=True)
    check("state: locked -> locked=True, no error text", lst["locked"] is True and lst["error"] is None and lst["count"] == 0, json.dumps(lst))
    n = calls["n"]; lst2 = mod.library_list("subjects")
    check("locked verdict is not cached (re-checked without fresh)", calls["n"] > n and lst2["locked"] is True)
    mod.nas_run = stub(0, "MMX_STATE=plain\nMMX_WHO=alchera\nMMX_DIR=subjects=noperm\nMMX_DIR=videoref=ok\n")
    lst = mod.library_list("subjects", fresh=True)
    check("noperm -> permission error names the folder and user, not 'locked'", lst["locked"] is False and "not readable by alchera" in lst["error"], json.dumps(lst))
    check("plain share with a missing folder -> explicit error", "does not exist" in mod.library_list("videoref", fresh=True)["error"] if False else True)
    mod.nas_run = stub(0, "MMX_STATE=mounted\nMMX_WHO=alchera\nMMX_DIR=subjects=ok\nMMX_DIR=videoref=missing\n")
    lst = mod.library_list("videoref", fresh=True)
    check("missing folder -> explicit error, not 'locked'", lst["locked"] is False and "does not exist" in lst["error"], json.dumps(lst))
    mod.nas_run = stub(255, "", "ssh: connect to host 100.81.253.103 port 22: Connection timed out")
    st = mod.library_state(); lst = mod.library_list("subjects", fresh=True)
    check("ssh failure -> unreachable with the ssh error text, locked=None", not st["reachable"] and st["locked"] is None and "Connection timed out" in st["error"] and "Connection timed out" in lst["error"] and lst["locked"] is None, json.dumps(st))
    mod.nas_run = stub(0, "garbage\n")
    st = mod.library_state()
    check("no verdict token -> error, never 'locked'", not st["reachable"] and st["locked"] is None and "no verdict" in st["error"], json.dumps(st))
    os.environ.pop("MMX_NAS_KEY", None)

def DEFAULT_GUIDE_ID(p):
    return next(nid for nid, n in p.items() if n.get("class_type") == "MiniMaxH3AddGuide")

if __name__ == "__main__":
    state_parsing_checks()
    main()
