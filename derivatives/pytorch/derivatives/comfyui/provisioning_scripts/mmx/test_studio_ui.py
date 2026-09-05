#!/usr/bin/env python3
"""Headless-Chromium (playwright) test of mmx_studio.html against mock_comfy + the real runner.

    python3 test_studio_ui.py            # from the mmx_v2 dir; ~40 s

Covers: template load, local refs -> slots (real HTML5 drag where Chromium delivers it,
the page's drag hook otherwise), F1 tag validation before Go, F4 tag buttons (occupied slots
only, insert at cursor, focus returns), F6 lock, F7 LoRA on a pool item copied to the lane +
missing-LoRA picker, F8 refresh toast, F3 NAS panes (local-root mode) + drag into a slot,
Go -> chained run -> tiles, F5 prompt modal + save to pool, and the runner-side remap
(<Picture 3>…<Picture 9> -> <Picture 2>…<Picture 3>) read back from mock_submitted.json.
"""
import json, os, shutil, subprocess, sys, tempfile, time
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
MOCK_PORT, RUN_PORT = 18288, 18290
TMP = tempfile.mkdtemp(prefix="mmx_ui_")
SUBMITTED = os.path.join(TMP, "submitted.json")
LIB = os.path.join(TMP, "lib")
TEMPLATE = os.path.join(HERE, "MiniMax - R2V - Auto Prompt v6 API v2.json")
results = []

def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (f"  — {detail}" if detail and not cond else ""), flush=True)

def png(color, path, size="96x54"):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s={size}:d=0.1", "-frames:v", "1", path], check=True)
def mp4(color, path):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c={color}:s=96x54:d=1:r=24", "-f", "lavfi", "-i",
                    "sine=frequency=300:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path], check=True)

def main():
    os.makedirs(LIB + "/Subjects/jj", exist_ok=True); os.makedirs(LIB + "/VideoRef", exist_ok=True)
    png("orange", LIB + "/Subjects/jj/j1.jpg"); png("purple", LIB + "/Subjects/js.jpeg"); mp4("gray", LIB + "/VideoRef/clip_A.mp4")
    files = {}
    for c in ("red", "green", "blue"):
        files[c] = os.path.join(TMP, c + ".png"); png(c, files[c])
    env = {**os.environ, "MOCK_OUT": TMP + "/out", "MOCK_IN": TMP + "/in", "MOCK_SUBMITTED": SUBMITTED, "MOCK_RENDER": "0.3"}
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_comfy.py"), "--port", str(MOCK_PORT)], env=env,
                            stdout=open(TMP + "/mock.log", "w"), stderr=subprocess.STDOUT)
    renv = {**os.environ, "MMX_LIBRARY_ROOT": LIB, "MMX_CACHE": TMP + "/cache", "COMFY_OUTPUT": TMP + "/out", "OPENROUTER_KEY": "sk-or-test"}
    runner = subprocess.Popen([sys.executable, os.path.join(HERE, "mmx_runner.py"), "--port", str(RUN_PORT), "--comfy", f"http://127.0.0.1:{MOCK_PORT}"],
                              env=renv, stdout=open(TMP + "/runner.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(1.5)
    try:
        with sync_playwright() as pw:
            b = pw.chromium.launch()
            ctx = b.new_context(viewport={"width": 1500, "height": 1000})
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto("file://" + os.path.join(HERE, "mmx_studio.html"))
            page.fill("#runner", f"http://127.0.0.1:{RUN_PORT}"); page.dispatch_event("#runner", "change")
            page.wait_for_function("document.getElementById('htxt').textContent.includes('runner + ComfyUI')", timeout=15000)
            check("health shows runner + ComfyUI + key", "key loaded" in page.text_content("#htxt"), page.text_content("#htxt"))

            # template
            with page.expect_file_chooser() as fc: page.click("#btnTpl")
            fc.value.set_files(TEMPLATE)
            page.wait_for_function("document.getElementById('ttxt').textContent.includes('✓')")
            check("template loaded (nodes present)", True)

            # local refs
            with page.expect_file_chooser() as fc: page.click("#btnAddRefs")
            fc.value.set_files([files["red"], files["green"], files["blue"]])
            page.wait_for_function("document.querySelectorAll('#thumbs .thumb').length === 3")
            check("3 local refs in the library", True)

            # drag red -> slot 1 (real drag), green -> slot 3, blue -> slot 9
            page.drag_and_drop("#thumbs .thumb:nth-child(1)", ".slot[data-kind=images][data-slot='1']")
            real_dnd = page.evaluate("!!window.mmx.slots.images[0]")
            if not real_dnd:
                page.evaluate("window.mmx.simulateDrag({type:'ref', id: window.mmx.refs()[0].id, kind:'image'}, document.querySelector(\".slot[data-kind=images][data-slot='1']\"))")
            check("drag red into slot 1 " + ("(real HTML5 drag)" if real_dnd else "(page drag hook)"), page.evaluate("!!window.mmx.slots.images[0]"))
            page.evaluate("window.mmx.simulateDrag({type:'ref', id: window.mmx.refs()[1].id, kind:'image'}, document.querySelector(\".slot[data-kind=images][data-slot='3']\"))")
            page.evaluate("window.mmx.simulateDrag({type:'ref', id: window.mmx.refs()[2].id, kind:'image'}, document.querySelector(\".slot[data-kind=images][data-slot='9']\"))")
            occ = page.evaluate("window.mmx.slots.images.map(x=>!!x)")
            check("slots 1, 3, 9 occupied", occ == [True, False, True, False, False, False, False, False, True], str(occ))
            check("a video ref cannot be dropped in an image slot", page.evaluate("(()=>{ const t=document.querySelector(\".slot[data-kind=images][data-slot='2']\"); window.mmx.simulateDrag({type:'lib', item:{path:'VideoRef/clip_A.mp4', kind:'video', name:'clip_A.mp4'}}, t); return !window.mmx.slots.images[1]; })()"))

            # F4: tag buttons only for occupied slots, in the first lane
            tags = page.eval_on_selector_all(".lane:nth-child(1) .tags button", "els => els.map(e=>e.textContent)")
            check("tag buttons = occupied slots + subjects", tags == ["<Picture 1>", "<Picture 3>", "<Picture 9>", "<Subject 1>", "<Subject 2>", "<Subject 3>"], str(tags))
            check("tag buttons carry slot thumbnails", page.eval_on_selector_all(".lane:nth-child(1) .tags button.pic img", "els => els.length") == 3)
            tags2 = page.eval_on_selector_all(".lane:nth-child(2) .tags button", "els => els.map(e=>e.textContent)")
            check("segment 2 offers <Picture 9> (chained frame) too", "<Picture 9>" in tags2, str(tags2))
            page.fill(".lane:nth-child(1) textarea", "walks in and looks around")
            page.evaluate("(()=>{ const ta=document.querySelector('.lane:nth-child(1) textarea'); ta.focus(); ta.setSelectionRange(0,0); })()")
            page.click(".lane:nth-child(1) .tags button:nth-child(2)")   # <Picture 3>
            page.evaluate("(()=>{ const ta=document.querySelector('.lane:nth-child(1) textarea'); ta.setSelectionRange(ta.value.length, ta.value.length); })()")
            page.click(".lane:nth-child(1) .tags button:nth-child(3)")   # <Picture 9>
            v = page.input_value(".lane:nth-child(1) textarea")
            check("tag insert at cursor (start + end)", v == "<Picture 3> walks in and looks around <Picture 9>", v)
            check("focus returned to the textarea", page.evaluate("document.activeElement === document.querySelector('.lane:nth-child(1) textarea')"))
            check("lane prompt persisted", page.evaluate("window.mmx.lanes[0].prompt") == v)

            # F1: a tag for an empty slot is blocked before Go
            page.fill(".lane:nth-child(2) textarea", "<Picture 2> enters")
            page.dispatch_event(".lane:nth-child(2) textarea", "input")
            page.uncheck("#dFirstClause")
            page.click("#btnGo")
            page.wait_for_function("document.getElementById('toast').classList.contains('show')")
            t = page.text_content("#toast")
            check("empty-slot tag blocked before Go with a clear message", "segment 2" in t and "<Picture 2>" in t and "empty slot" in t, t)
            check("no job was submitted", page.evaluate("window.mmx.job") is None and not os.path.exists(SUBMITTED))
            page.wait_for_timeout(300)

            # F3: NAS panes (local root) + drag a Subject into slot 2 and a VideoRef into video slot 1
            page.wait_for_function("document.querySelectorAll('#libSubjects .thumb').length === 2", timeout=15000)
            page.wait_for_function("document.querySelectorAll('#libVideoref .thumb').length === 1", timeout=15000)
            check("Subjects and VideoRef panes list the library", True)
            page.fill("#qSubjects", "js."); page.wait_for_function("document.querySelectorAll('#libSubjects .thumb').length === 1")
            check("library search filters", True); page.fill("#qSubjects", "")
            page.evaluate("window.mmx.simulateDrag({type:'lib', item: window.mmx.library.subjects.items[0]}, document.querySelector(\".slot[data-kind=images][data-slot='2']\"))")
            page.evaluate("window.mmx.simulateDrag({type:'lib', item: window.mmx.library.videoref.items[0]}, document.querySelector(\".slot[data-kind=videos][data-slot='1']\"))")
            check("library items dropped into image slot 2 and video slot 1", page.evaluate("window.mmx.slots.images[1]?.kind==='library' && window.mmx.slots.videos[0]?.kind==='library' && window.mmx.slots.videos[0].soundtrack===true"))
            check("NAS badge on library slot", page.locator(".slot[data-kind=images][data-slot='2'] .lib").count() == 1)
            page.click(".slot[data-kind=videos][data-slot='1'] .st input")
            check("video soundtrack toggle persisted", page.evaluate("window.mmx.slots.videos[0].soundtrack") is False)

            # F7: LoRA on a pool item, dropped onto lane 2
            page.wait_for_function("window.mmx.models && window.mmx.models.loras.length > 0")
            page.click("#btnAddPrompt")
            page.fill(".prompt.editing textarea", "<Picture 1> and <Video 1> dance to <Audio 1>. {{first}} starts it.")
            page.dispatch_event(".prompt.editing textarea", "input")
            page.select_option(".prompt.editing .lorarow select >> nth=0", "H3_Motion_BoosterV2.safetensors")
            page.fill(".prompt.editing .lorarow input[type=number] >> nth=0", "0.6"); page.dispatch_event(".prompt.editing .lorarow input[type=number] >> nth=0", "change")
            pl = page.evaluate("window.mmx.pool[0].loras")
            check("pool item LoRA stored", pl == [{"name": "H3_Motion_BoosterV2.safetensors", "strength": 0.6}], str(pl))
            page.evaluate("window.mmx.simulateDrag({type:'prompt', id: window.mmx.pool[0].id}, document.querySelector('.lane:nth-child(2)'))")
            ln = page.evaluate("window.mmx.lanes[1]")
            check("prompt + LoRA copied onto lane 2", ln["prompt"].startswith("<Picture 1> and <Video 1>") and ln["loras"] == pl, str(ln))
            # <Audio 1> refers to an empty audio slot -> blocked; fix by removing it
            page.click("#btnGo"); page.wait_for_function("document.getElementById('toast').classList.contains('show') && document.getElementById('toast').textContent.includes('Audio 1')")
            check("empty audio slot tag blocked", True); page.wait_for_timeout(300)
            page.evaluate("window.mmx.setLane(1, {prompt: '<Picture 1> and <Video 1> dance. {{first}} starts it.'})")

            # F6: lock aspect/mp to defaults
            page.select_option("#dAspect", "9:16"); page.fill("#dMp", "0.06"); page.dispatch_event("#dMp", "change"); page.fill("#dSeconds", "1"); page.dispatch_event("#dSeconds", "change")
            page.check("#dLock"); page.check("#dLockSeconds")
            check("lock disables lane aspect/mp/seconds controls", page.evaluate("[...document.querySelectorAll('.lane .row select, .lane .row input[type=number]')].filter(e=>e.disabled).length") == 6)
            check("lock shows on lanes", page.locator(".lane .badge.lock").count() == 2)

            # missing LoRA -> picker modal
            page.evaluate("window.mmx.setLane(1, {loras:[{name:'Gone.safetensors', strength:0.6}]})")
            page.fill("#jobname", "uitest")
            page.click("#btnGo")
            page.wait_for_function("document.getElementById('missingModal').classList.contains('show')", timeout=15000)
            check("missing LoRA caught client-side with a picker", "Gone.safetensors" in page.text_content("#mmList"))
            page.select_option("#mmList select", "side_fuck_h3_000000750.safetensors")
            page.click("#mmApply")
            check("picker applied to the lane", page.evaluate("window.mmx.lanes[1].loras[0].name") == "side_fuck_h3_000000750.safetensors")

            # the run (job was started by Apply and Go)
            page.wait_for_function("window.mmx.job && ['done','failed','cancelled'].includes(window.mmx.job.state)", timeout=60000)
            job = page.evaluate("window.mmx.job")
            check("chained job done", job["state"] == "done", job.get("error") or "")
            sub = json.load(open(SUBMITTED))
            d0, d1 = sub[-2]["185"]["inputs"], sub[-1]["185"]["inputs"]
            check("F1 remap seg1: <Picture 3>…<Picture 9> -> <Picture 3>…<Picture 4> (slots 1,2,3,9 occupied; 3 images before slot 9)",
                  d0["direction"] == "<Picture 3> walks in and looks around <Picture 4>", d0["direction"])
            check("F1 remap seg2 with video + chained frame", d1["direction"] == "<Picture 1> and <Video 1> dance. <Picture 4> starts it.", d1["direction"])
            refs1 = json.loads(d1["references_json"])["references"]
            check("seg2 references: 4 images (slot 9 = chained) + 1 video without soundtrack", [r["kind"] for r in refs1] == ["image"] * 4 + ["video"] and refs1[4]["use_soundtrack"] is False and refs1[3]["file"].endswith("seg01_last.png"), json.dumps(refs1))
            check("F6 lock applied: both segments 9:16 at defaults", sub[-1]["184"]["inputs"]["width"] < sub[-1]["184"]["inputs"]["height"] and sub[-2]["132"]["inputs"]["value"] == 1.0)
            check("F7 lora_2 on segment 2 only", "lora_2" not in sub[-2]["137"]["inputs"] and sub[-1]["137"]["inputs"]["lora_2"]["lora"] == "side_fuck_h3_000000750.safetensors")
            check("F2 guide injected for segment 2", any(n.get("class_type") == "MiniMaxH3AddGuide" for n in sub[-1].values()))
            check("tiles rendered with videos + final", page.locator(".tile video").count() == 3 and page.locator(".tile.final").count() == 1)
            check("continuity PSNR badge on segment 2", "dB" in page.text_content(".tile:nth-child(2) .cap"))

            # F5 prompt modal
            page.click(".tile:nth-child(1) .cap button")
            page.wait_for_function("document.getElementById('promptModal').classList.contains('show')")
            check("prompt modal shows direction + generated prompt", page.text_content("#pmDirection") == d0["direction"] and page.text_content("#pmGenerated") == d0["direction"])
            n0 = page.evaluate("window.mmx.pool.length")
            page.click("#pmSave")
            check("save generated as pool item", page.evaluate("window.mmx.pool.length") == n0 + 1 and page.evaluate("window.mmx.pool[0].text") == d0["direction"])
            page.click("#pmClose")

            # F8 refresh reports changes
            png("teal", LIB + "/Subjects/new_one.jpg")
            page.click("#btnRefresh")
            page.wait_for_function("document.getElementById('toast').classList.contains('show') && document.getElementById('toast').textContent.startsWith('Refreshed')", timeout=20000)
            t = page.text_content("#toast")
            check("refresh toast reports the new Subject", "1 new Subject" in t and "LoRAs" in t, t)

            # persistence across reload
            page.reload(); page.wait_for_function("document.querySelectorAll('#thumbs .thumb').length === 3", timeout=15000)
            occ = page.evaluate("window.mmx.slots.images.map(x=>!!x)")
            check("slots + lanes persist across reload", occ[0] and occ[1] and occ[2] and occ[8] and page.evaluate("window.mmx.lanes[1].loras[0].name") == "side_fuck_h3_000000750.safetensors", str(occ))
            check("no page errors", not errors, "; ".join(errors)[:300])
            b.close()
    finally:
        runner.terminate(); mock.terminate(); runner.wait(5); mock.wait(5)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed" + (f"; logs in {TMP}" if failed else ""))
    if not failed: shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
