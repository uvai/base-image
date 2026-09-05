# mmx studio v2

Headless MiniMax H3 chain studio: `mmx_studio.html` (browser, `file://`) drives `mmx_runner.py`
(Vast instance, port 8190), which drives ComfyUI over its HTTP API only.

| file | where it runs | notes |
|---|---|---|
| `mmx_runner.py` | instance, `/workspace` | stdlib only; started by `additional_params.sh` under `/root/mmx_supervise.sh` (log `/workspace/mmx_runner.log`) |
| `mmx_studio.html` | Mac, `~/.local/share/mmx/` | single file, no build |
| `vgo` | Mac, `~/.local/bin/vgo` | v21: forwards 8190, `vgo studio`, runner pill in the dashboard |
| `mock_comfy.py` | dev | ComfyUI API mock (`/object_info`, Display Any text, guide-aware rendering) |
| `test_runner_mock.py`, `test_studio_ui.py` | dev | runner tests (37) and playwright UI tests (40) |
| `MiniMax - R2V - Auto Prompt v6 API v2.json` | Mac | the API-format template, **key stripped** (node 193 blank) |

## Install (Mac)

```
mkdir -p ~/.local/share/mmx ~/.local/bin
B=https://raw.githubusercontent.com/uvai/base-image/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/mmx
curl -fsSL $B/mmx_studio.html -o ~/.local/share/mmx/mmx_studio.html
curl -fsSL $B/vgo -o ~/.local/bin/vgo && chmod +x ~/.local/bin/vgo
vgo studio      # ensures the 8190 forward and opens the page
```

The instance side needs nothing: `additional_params.sh` (section 4) fetches the runner from this
repo on every boot and supervises it. It inherits the Vast template environment, so
`OPENROUTER_KEY` (or `OPENROUTER_API_KEY` / `LLM_KEY`) reaches the runner without manual steps.

## Dev loop

```
python3 test_runner_mock.py     # mock on 18188, runner on 18190, local-library mode
python3 test_studio_ui.py       # headless Chromium against the same pair
```

`mock_comfy.py` writes under `/tmp/mmx_mock` by default (`MOCK_OUT`, `MOCK_IN`, `MOCK_SUBMITTED`
override). `mock_submitted.json` holds every graph the runner submitted, in order.

## Spec v2 (runner contract)

See the docstring at the top of `mmx_runner.py`. Highlights:

- `slots.images[].slot` 1–9 (**9 = first frame**), `slots.videos[].slot` 1–3 with `use_soundtrack`,
  `slots.audios[].slot` 1–3. Sources are `{"kind":"local","name","data"}` (base64) or
  `{"kind":"library","path":"Subjects/j/j1.jpg"}` (fetched from the NAS by the runner).
- Prompt tags name **UI slots**. The runner compacts occupied slots in slot order and rewrites
  `<Picture N>` / `<Video N>` / `<Audio N>` to the ordinal the RefPack node assigns
  (`<Audio N>` counts video soundtracks before standalone audio, as the node does). `{{first}}` =
  `<Picture 9>`. A tag on an empty slot fails `POST /validate` and `POST /job` (400) with the tag named.
- Segments 2+: slot 9 becomes the previous segment's last frame **and**, with
  `options.continuation = "guide"` (default), the runner injects `MiniMaxH3AddGuide(frame_idx=0)` +
  `LoadImage` between the reference node and every consumer of its conditioning. `templates.next`
  overrides that (used verbatim, no injection). `options.continuation_unet` swaps the UNET for
  segments 2+. The runner measures PSNR between the previous last frame and the next segment's
  first decoded frame (`segments[i].continuity_psnr`, dB; 99 = identical).
- `segments[].loras` → `lora_2`, `lora_3`… on node 137; `lora_1` and node 158 are never touched.
  Names are validated against `/object_info` before upload and fail with the exact missing name.
- `segments[i].generated_prompt` = `history[id].outputs["186"].text[0]` (rgthree Display Any
  returns `{"ui": {"text": (value,)}}`); `direction` = the remapped text that was sent.
- v1 specs (`refs` + `first_frame`) are upgraded on arrival (`spec_version` 1 recorded on the job).

## NAS library data path (F3)

Decision: **the runner lists the share over ssh from the instance** and reuses the subgenula
viewer's thumbnails. The viewer (`/opt/subgenula`) keeps `_app/index.db` and
`_app/thumbs/t<sha1(relpath)[:12]>.jpg` on the share itself, so the runner computes the same id and
copies the viewer's thumb (`GET /library/thumb`), generating one with ffmpeg only when the viewer
has none yet. Listing uses GNU `find -printf` on the NAS (present on DSM). Reasons against calling
the viewer's HTTP API directly from the page: it is admin-gated by Tailscale identity, has no CORS
headers, and redeploying it locks the share; the ssh path is the one the NAS sync already uses
(`/root/.ssh/mmx_nas_key`, SOCKS via the instance's userspace tailscaled). At Go, library items are
fetched to `/workspace/mmx_cache/lib/` and uploaded to ComfyUI's input by the runner; only local
refs travel as base64.

Runner env knobs: `MMX_NAS` (`user@host`, default parsed from `NAS_DEST`), `MMX_NAS_KEY`,
`MMX_NAS_PROXY` (`none` to disable), `MMX_NAS_SHARE`, `MMX_LIBRARY_DIRS`
(`subjects=Subjects,videoref=VideoRef`), `MMX_LIBRARY_ROOT` (local directory instead of the NAS —
used by the tests), `MMX_CACHE`.

State surfaced to the page: `locked` (share not mounted → panes say so), `error` (unreachable /
missing folder), `reachable`.

## Live check 2026-09-05 (RTX PRO 6000, hybrid int8 UNET, turbo LoRA, acc LoRA off — not on the box)

Job `mmx_v2_livecheck2`: 2 × 2 s at 608×320, auto-prompt on (gemini-3-flash-preview), guide
continuation. Both segments rendered (27 s + 15 s), generated prompts captured from node 186,
concat produced. Continuity numbers (PSNR, ffmpeg, dB):

| pair | dB |
|---|---|
| h264 codec floor (last-frame PNG vs the same frame decoded from the mp4, CRF 12) | 37.5 |
| adjacent frames inside segment 1 / segment 2 | 26.3 / 22.1 |
| **hard: seg 1 last frame vs seg 2 first frame (injected guide)** | **22.7** |
| soft: slot-9 reference vs seg 1 first frame (ref2va hint only) | 7.2 |

So the guide makes the join as similar as two consecutive frames of the same clip (same
framing, composition and zoom; regeneration texture differs), versus a different crop entirely on
the soft path. It is not pixel-identical: the model regenerates frame 0 from the keyframe latent
(the same mechanism ComfyUI's own `video_minimax_h3_i2v_continuation` template uses), and > 40 dB
is unreachable through the h264 path anyway (floor 37.5). Things not yet tried that could raise it:
`options.continuation_unet`, more sampler steps for segments 2+, the acc LoRA (was absent).

## Not verified

- A fresh Vast rent end to end (needs the Vast CLI on the Mac). The deploy path was exercised by
  re-fetching `additional_params.sh` from raw main on the live box and running it under PID 1's
  environment, which is what a boot does; `/health` then reported `comfy: true, openrouter_key: true`.
- `vgo studio` on the Mac itself (syntax-checked here: `bash -n`, embedded Python compiled, page JS
  `node --check`).
- The runner with the acc LoRA on, and reference videos/audio on real hardware (mock only).
