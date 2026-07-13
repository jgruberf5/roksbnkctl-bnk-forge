#!/usr/bin/env node
// Salvage a crashed full run: the walkthrough + real cluster/BNK build were captured
// (out/work/frames, 56k+ frames) but the run threw at a k8s-tail scene before
// post-production. This reconstructs the main timeline from the run log's per-scene
// durations, records ONLY the k8s tail against the still-live cluster (appending frames),
// then stitches everything into demo-en/fr-1080p.mp4.
//
//   FORGE_PASSWORD=… node src/salvage.mjs --log /tmp/fullrun.log
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';
import { Recorder, buildTimeline } from './recorder.mjs';
import { UI, loadSelectors, sleep } from './ui.mjs';
import { SCENES } from './scenes.mjs';
import { synthAll } from './tts.mjs';
import { planTimeline, encodeMaster, cutScenes, concatVideo, buildAudioTrack, mux } from './postprod.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const LOG = opt('log', '/tmp/fullrun.log');
const OUT = path.join(ROOT, 'out');
const WORK = path.join(OUT, 'work');
const FRAMES = path.join(WORK, 'frames');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'demo.config.json'), 'utf8'));
const selectors = loadSelectors(path.join(ROOT, 'config', 'selectors.json'));
const narration = JSON.parse(fs.readFileSync(path.join(ROOT, 'scenes', 'narration.json'), 'utf8'));
const log = (...a) => console.log(...a);
const stamp = () => new Date().toISOString().slice(11, 19);

const KIND = Object.fromEntries(SCENES.map((s) => [s.id, s.kind]));
const byId = Object.fromEntries(SCENES.map((s) => [s.id, s]));
const TAIL = ['cluster_registered', 'k8s_scan', 'k8s_healthy', 'outro'];

async function main() {
  // ---- 1. main marks from the log's per-scene "took" durations -----------------
  const logText = fs.readFileSync(LOG, 'utf8');
  const took = [...logText.matchAll(/^\s+(\w+) took ([\d.]+)s/gm)].map((m) => ({ id: m[1], dur: parseFloat(m[2]) }));
  const mainScenes = took.filter((t) => KIND[t.id] && !TAIL.includes(t.id));
  if (!mainScenes.length) throw new Error('no scene durations parsed from log');
  const nMain = fs.readdirSync(FRAMES).filter((f) => /^f\d+\.jpg$/.test(f)).length;
  const total = mainScenes.reduce((a, s) => a + s.dur, 0);
  log(`parsed ${mainScenes.length} captured scenes, ${nMain} frames, ${total.toFixed(0)}s wall`);

  // Map scene boundaries proportionally onto the actual captured frames (absorbs the
  // small timer drift so the last scene ends exactly at the first tail frame).
  const mainMarks = [];
  let cum = 0;
  for (const s of mainScenes) {
    mainMarks.push({ id: s.id, kind: KIND[s.id], frame: Math.round((cum / total) * nMain) });
    cum += s.dur;
  }

  // ---- 2. narration for every scene (main cached + tail) -----------------------
  log(`\n[${stamp()}] synthesizing narration…`);
  const audio = await synthAll({
    scenes: SCENES, narration, voices: cfg.voices, outDir: path.join(WORK, 'tts'),
    sampleRate: cfg.audio.sampleRate, sentenceSilenceSec: cfg.audio.sentenceSilenceSec,
    lengthScale: cfg.audio.lengthScale, log,
  });
  const minDur = Object.fromEntries(SCENES.map((s) => [
    s.id, cfg.audio.leadInSec + Math.max(...Object.values(audio[s.id]).map((a) => a.dur)) + cfg.audio.tailGapSec,
  ]));

  // ---- 3. record the k8s tail, appending frames from nMain ---------------------
  log(`\n[${stamp()}] recording tail (${TAIL.join(', ')}) against the live cluster…`);
  const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'answers.json'), 'utf8'));
  A.forgePassword = process.env.FORGE_PASSWORD;
  A.ibmApiKey = process.env.IBMCLOUD_API_KEY || 'unused-for-tail';
  if (!A.forgePassword) throw new Error('need $FORGE_PASSWORD');

  const browser = await puppeteer.launch({
    headless: true, defaultViewport: null, acceptInsecureCerts: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage',
      `--window-size=${cfg.video.windowWidth},${cfg.video.windowHeight}`,
      '--force-device-scale-factor=1', '--hide-scrollbars'],
  });
  const page = (await browser.pages())[0];
  page.setDefaultTimeout(cfg.timeouts.elementMs);
  const ui = new UI(page, selectors, cfg, log);
  const rec = new Recorder(page, {
    framesDir: FRAMES, jpegQuality: cfg.video.jpegQuality, width: cfg.video.width,
    height: cfg.video.height, captureFps: cfg.video.captureFps,
    startIndex: nMain, keepExisting: true,
  });
  const ctx = { ui, page, A, cfg, rehearse: false, skipDeploy: false, log };
  let captured;
  try {
    await ui.gotoApp(A.forgeUrl, ['login.username', 'nav.catalog']);
    await byId.login.run(ctx);       // ensure authenticated (not recorded as a scene)
    await rec.start();
    for (const id of TAIL) {
      rec.mark(id, KIND[id]);
      const t0 = Date.now();
      log(`[${stamp()}] tail scene ${id} (${KIND[id]})`);
      await byId[id].run(ctx);
      if (KIND[id] !== 'wait') {
        const remain = minDur[id] * 1000 - (Date.now() - t0);
        if (remain > 0) await sleep(remain);
      }
    }
  } finally {
    captured = await rec.stop().catch((e) => { log(`recorder stop: ${e.message}`); return null; });
    await browser.close().catch(() => {});
  }
  if (!captured) throw new Error('tail capture failed');
  log(`tail added ${captured.frameCount - nMain} frames (total ${captured.frameCount})`);

  // ---- 4. combine + post-produce ----------------------------------------------
  const marks = [...mainMarks, ...captured.marks];
  const timeline = buildTimeline({ frameCount: captured.frameCount, marks, fps: cfg.video.captureFps });
  const plan = planTimeline({ timeline, audio, cfg });
  log('\nscene plan:');
  for (const s of plan) {
    log(`  ${s.id.padEnd(18)} ${s.speed}x real=${s.realDur.toFixed(1)}s -> ${s.finalDur.toFixed(1)}s`
      + (s.freezePad > 0.05 ? ` (+${s.freezePad.toFixed(1)}s hold)` : ''));
  }
  fs.writeFileSync(path.join(OUT, 'timeline.json'), JSON.stringify({ plan }, null, 2));

  log(`\n[${stamp()}] encoding master (${captured.frameCount} frames)…`);
  const master = await encodeMaster({ framesDir: FRAMES, out: path.join(WORK, 'master.mp4'), cfg });
  log(`[${stamp()}] applying speed ramps…`);
  const { list } = await cutScenes({ master, plan, dir: path.join(WORK, 'segs'), cfg });
  const video = await concatVideo({ list, out: path.join(WORK, 'video.mp4') });

  const outputs = [];
  for (const lang of Object.keys(cfg.voices)) {
    log(`[${stamp()}] building ${lang} audio + mux…`);
    const track = await buildAudioTrack({ lang, plan, audio, dir: path.join(WORK, 'audio'), out: path.join(WORK, `audio.${lang}.wav`), cfg });
    const final = path.join(OUT, `demo-${lang}-1080p.mp4`);
    await mux({ video, audioTrack: track, out: final });
    outputs.push(final);
  }
  log(`\n[${stamp()}] done:`);
  outputs.forEach((o) => log(`  ${o}`));
}

main().catch((e) => { console.error(`\nSALVAGE FAILED: ${e.message}`); if (process.env.DEBUG) console.error(e.stack); process.exit(1); });
