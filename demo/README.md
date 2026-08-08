# Demo recorder — install this repo into BNK Forge and deploy IBM ROKS + BNK

Drives a real **BNK Forge** UI with headless Chromium (Puppeteer), narrates it with
**piper**, and produces two 1080p videos with identical picture and different voice-overs:

```
out/demo-en-1080p.mp4     en_US-ryan-high
out/demo-fr-1080p.mp4     fr_FR-tom-medium
```

The recorded walkthrough: sign in → add the **IBM Cloud credential template** (prompts for
the API key) → register this repo as a **module source** → let it sync → **Import** the
discovered blueprint → **Deploy Blueprint** (creates the project *IBM ROKS + BNK
(roksbnkctl)* with 4 pending phase modules) → open the project → **Deploy all** →
**Start Deployment** → watch `cluster` then `bnk` converge on the project page → open the
**Kubernetes** page, select the newly-registered cluster, run an **auto-detect scan**, and
show it healthy (nodes ready, resources up). The two long waits — the `cluster` build and
the Kubernetes scan — are recorded live and compressed **4×**.

> The Kubernetes-page ending (`cluster_registered`, `k8s_scan`, `k8s_healthy` scenes) can
> only capture real content once a deployment actually succeeds — it reads the live cluster
> list and node/resource counts. It is a no-op on an instance where the deploy fails.

> **Deploy is two steps in this UI.** "Deploy Blueprint" only *creates* the project and
> its modules (all `Pending`); it launches nothing. The actual run starts from the project
> page: **Deploy all → Start Deployment**, which executes the dependency pipeline
> (Layer 0 `cluster` ~45 min → Layer 1 `bnk` + `testing` → Layer 2 `gateway`). With
> `install_testing`/`install_gateway` off, those modules initialise and no-op.

> ## ⚠️ This recorder targets a retired blueprint
>
> The scenes below drive **IBM ROKS + BNK (roksbnkctl)** — one blueprint with four
> phase modules (`cluster` → `bnk` → `testing` → `gateway`) and the
> `cluster_create` / `install_bnk` / `install_testing` / `install_gateway` toggles.
> That blueprint no longer exists. The catalog now ships **seven** blueprints over
> **seven** modules, and the ROKS ones are `cluster-create`/`cluster-registry` →
> `bnk-install`, with no phase toggles at all.
>
> `config/selectors.json` still maps the old field ids
> (`#imported-input-install_testing` and friends), so a run against the current
> catalog will not find them; `scenes/narration.json` narrates the retired
> four-phase structure throughout. Re-record only after retargeting both.
>
> The screenshot-driven customer walkthrough is maintained instead, and is current:
> [**An end to end demo using BNK Forge and roksbnkctl**](../scripts/demo/An%20end%20to%20end%20demo%20using%20BNK%20Forge%20and%20roksbnkctl%20for%20deployment%20use%20cases.md).

**UI facts worth keeping**, verified against a live BNK Forge 3.1.6 and still true:

| | |
|---|---|
| Left nav → **Modules** | No such nav item. Modules live under **Catalog**, behind the **Advanced** switch. `/modules` redirects to `/catalog`. |
| Sources | Registering **one** source auto-creates its companion (`<name> blueprints`). Adding the second by hand just makes a duplicate. |
| After a sync | A blueprint may land in state **`discovered`** with **Deploy** disabled — **Import** is the "enable the blueprint" step. |
| Credentials | The **Deploy** dialog creates the project inline (project name + credential template + region). There is no separate Projects step. |
| Left nav **Blueprints** page | Points at `/stacks`. `/blueprints` is a 404. |

## Requirements

| | |
|---|---|
| Node | ≥ 18 (`npm install` pulls Puppeteer + its Chromium) |
| ffmpeg / ffprobe | on `PATH` |
| piper | `~/.local/bin/piper` |
| voices | `~/.local/share/piper/voices/{en_US-ryan-high,fr_FR-tom-medium}.onnx` |

Paths are set in [`config/demo.config.json`](config/demo.config.json).

## Run it

```bash
npm install

# 1. Calibrate selectors against YOUR Forge (once per Forge version).
npm run probe -- --url https://forge.example.com --user admin

# 2. Full UI drive, synthetic long-waits, stops at the filled deploy form.
#    Creates no IBM resources and spends nothing.
npm run record-dry

# 3. The real thing: provisions a ROKS cluster (30–45 min) and installs BNK.
npm run demo

# 4. Put the Forge back the way it was, so the demo can be re-recorded.
FORGE_PASSWORD=… npm run reset -- --url https://forge.example.com --user admin --creds

# 4b. If a real cluster was deployed, tear down its IBM resources first:
FORGE_PASSWORD=… npm run reset -- --url https://forge.example.com --user admin --creds --destroy
```

`npm run reset` deletes the demo **project**, the imported blueprint, the blueprint
sources, and the module source; add `--creds` to also drop the demo credential template.
Run it with `--dry` first — it reports what it would delete without touching anything.

**`--destroy` is important after a real deployment.** Deleting a project removes its
config but **not** the IBM Cloud resources it created. `--destroy` runs the project's
**Destroy all** (roksbnkctl `<phase> down`, reverse dependency order) and waits for
teardown before deleting — otherwise the ROKS cluster keeps costing money.

You are prompted for the Forge **URL**, **username**, **password**, the **IBM Cloud API
key**, and every blueprint form value. Non-secret answers are saved to `answers.json`
and replayed on the next run (Enter keeps each value), which is what makes the demo
repeatable. Re-run unattended with:

```bash
export FORGE_PASSWORD=… IBMCLOUD_API_KEY=…
npm run demo -- --answers answers.json --no-prompt
```

**Secrets are never written to `answers.json`, never logged, and typed into password
fields** — but note the API key *is* keystroked into the Forge form on camera, so it
appears in the video as whatever the Forge renders (normally `••••`). Use a scratch
API key for recordings you intend to publish.

## Selector calibration

`config/selectors.json` maps a logical name (`cred.apiKey`) to an **ordered list of
candidate specs**; the first that resolves to a visible element wins:

| Prefix | Meaning |
|---|---|
| `label:Repository URL` | the control bound to that `<label>` |
| `btn:Add Source` | a `<button>` with that text |
| `text:IBM ROKS + BNK` | any element with that text |
| `dlg>…` | scope to the **topmost** `[role=dialog]` **or** `[role=alertdialog]` |
| *(bare)* | plain CSS |

Label binding is not a nicety here — this build ships **no `data-testid` and no `name`**
on form controls, and its ids look like `:r2e:-form-item`, regenerated on every render.
The deploy dialog is the exception: it has stable ids (`imported-input-<var>`), so those
are pinned directly.

`npm run probe` logs in, walks the pages the demo touches, screenshots each, dumps every
interactive control with a suggested selector, and lists which logical names are still
**UNRESOLVED**.

### Things that will bite you in this UI

- **Radix menus and selects need trusted clicks.** An `element.click()` from inside
  `page.evaluate()` does nothing; drive them with a real Puppeteer click.
- **Confirmations are `role="alertdialog"`**, not `role="dialog"` — except credential
  and module-source deletion, which use a **native `window.confirm`** (handle
  `page.on('dialog')`).
- **Blueprint booleans render as free-text inputs**, not switches, so `install_bnk` is
  typed as `"true"` / `"false"`. (Looks like a Forge form-rendering bug.)
- **The catalog has ~13 `Deploy` buttons.** Locate one relative to the row naming the
  blueprint (`ui.clickRowButton('IBM ROKS + BNK', 'Deploy')`).
- **The credential dialog swaps fields by provider.** `#ibmcloud_api_key` and
  `#ibmcloud_resource_group` exist only after picking *IBM Cloud*, and the region input
  has **no id at all** — only `placeholder="e.g., us-south"`.

## How the timing works

Narration is synthesized **before** the browser opens, so every scene's minimum on-screen
time is known up front.

```
speed     = 4 for `wait` scenes, 1 otherwise
spedDur   = realDur / speed
needed    = leadIn(0.5s) + max(narration across EN and FR) + tailGap(2.0s)
finalDur  = max(spedDur, needed)
```

- **Interactive scenes** hold the last frame until the narration would have finished.
- **Wait scenes** (`source_sync`, `bp_sync`, `wait_cluster`, `wait_bnk`) are recorded in
  real time and compressed **4×** (`setpts=PTS/4`). A 40-minute cluster build becomes
  10 minutes of screen time. If a sped-up scene ends up shorter than its narration, the
  last frame is held (`tpad`) rather than clipping the audio.
- `finalDur` is computed against the **longest** language, so one video track fits both
  audio tracks — EN and FR stay frame-identical.
- Each language's scene audio is `silence(0.5s) + narration + silence(rest)`, so the gap
  between two spoken sections is always `tailGap + leadIn` = **≥ 2.5 s**, satisfying the
  ≥ 2 s separation requirement with margin.

`out/timeline.json` records the resolved plan for every scene.

Verify the gaps on a finished render:

```bash
ffmpeg -i out/demo-en-1080p.mp4 -af silencedetect=noise=-50dB:d=2 -f null - 2>&1 | grep silence_duration
```

## Editing the script

- **Narration** — [`scenes/narration.json`](scenes/narration.json), keyed by scene id and
  language. Keep FR and EN close in length: a long French line stretches the scene for
  *both* videos. Piper reads acronyms better spelled out (`B N K`, `A P I`).
- **Flow** — [`src/scenes.mjs`](src/scenes.mjs). Each scene is `{ id, kind, run(ctx) }`
  with `kind: 'interactive' | 'wait'`. Scene ids must match the narration keys.
- **Pacing** — `audio.leadInSec`, `audio.tailGapSec`, `speed.waitSceneFactor` in the config.
- **Rehearsal waits** — `rehearse.clusterWaitSec`, `rehearse.phaseWaitSec`.
- **Capture rate / output fps** — `video.captureFps` (default 12) and `video.fps` (30).
  Raising `captureFps` gives smoother motion at the cost of disk and encode time.

## Notes

- Chromium's screencast captures the window **surface**, not the emulated viewport, so the
  window is launched at `1920×1167` to yield exactly `1920×1080` of content. Don't "fix"
  the window height to 1080 — you get 1920×993.
- `page.screencast()` needs a headed browser (it silently writes a 0-byte file under
  headless), so `src/recorder.mjs` drives CDP `Page.startScreencast` directly.
- **Capture is fixed-rate.** Chrome emits screencast frames at a variable rate; the
  recorder keeps only the latest frame and flushes it on a `captureFps` timer (default
  12) to sequentially-numbered files. The master is then encoded with the **image2**
  demuxer (`-framerate 12 -i f%07d.jpg`). The earlier design saved every frame and fed
  the ffmpeg **concat** demuxer with per-frame durations — that was O(n) pathological
  (~10 min to encode 8 600 frames, and a 45-min deploy wait produces 100 k+), so it would
  never finish the real run. Fixed rate + image2 encodes the same content in seconds.
  Because the rate is constant, a scene mark is just a frame index and cuts land exactly.
- The two piper voices have different native sample rates (22 050 Hz vs 44 100 Hz);
  everything is resampled to `audio.sampleRate` (48 kHz) before the timeline is built.
- On failure the current scene is screenshotted to `out/fail-<scene>.png`.
- Add `--keep-frames` to retain the raw JPEG capture in `out/work/frames`.
- Piper samples noise, so re-voicing the same line yields a slightly different duration —
  and therefore a slightly different video length. Synthesized clips are cached by
  `(text, voice, rate)` hash in `out/work/tts/cache/`, so repeat runs are byte-identical.
  Delete that directory to re-voice after editing narration (changed text re-synthesizes
  automatically; the hash covers it).
