#!/usr/bin/env node
// Records the BNK Forge walkthrough and produces demo-en-1080p.mp4 + demo-fr-1080p.mp4.
//
//   npm run demo                 # real deployment (prompts for URL/creds/API key)
//   npm run rehearse             # short synthetic waits, no real ROKS spend
//   npm run demo -- --answers answers.json --no-prompt
//
// Secrets are read from $FORGE_PASSWORD / $IBMCLOUD_API_KEY when set, are never
// written to answers.json, and are never echoed into the log or the video.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';

import { Recorder, buildTimeline } from './recorder.mjs';
import { UI, loadSelectors, sleep } from './ui.mjs';
import { SCENES as ALL_SCENES, DEPLOY_SCENES } from './scenes.mjs';
import { synthAll } from './tts.mjs';
import { collectAnswers } from './prompts.mjs';
import {
  planTimeline, encodeMaster, cutScenes, concatVideo, buildAudioTrack, mux,
} from './postprod.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(`--${n}`);
const opt = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};

const REHEARSE = flag('rehearse');
// --skip-deploy records the whole walkthrough but stops at the filled deploy form,
// so no IBM Cloud resources are created and no cluster charges accrue.
const SKIP_DEPLOY = flag('skip-deploy');
const SCENES = SKIP_DEPLOY ? ALL_SCENES.filter((s) => !DEPLOY_SCENES.includes(s.id)) : ALL_SCENES;
const KEEP = flag('keep-frames');
const OUT = path.resolve(opt('out', path.join(ROOT, 'out')));
const WORK = path.join(OUT, 'work');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'demo.config.json'), 'utf8'));
const selectors = loadSelectors(path.join(ROOT, 'config', 'selectors.json'));
const narration = JSON.parse(fs.readFileSync(path.join(ROOT, 'scenes', 'narration.json'), 'utf8'));
const blueprint = JSON.parse(fs.readFileSync(path.join(ROOT, '..', 'forge-blueprint.json'), 'utf8'));

const log = (...a) => console.log(...a);
const stamp = () => new Date().toISOString().slice(11, 19);

async function main() {
  fs.mkdirSync(WORK, { recursive: true });

  // ---- 1. answers -----------------------------------------------------------
  const answersFile = path.resolve(opt('answers', path.join(ROOT, 'answers.json')));
  let A;
  if (flag('no-prompt')) {
    A = JSON.parse(fs.readFileSync(answersFile, 'utf8'));
    A.forgePassword = process.env.FORGE_PASSWORD;
    A.ibmApiKey = process.env.IBMCLOUD_API_KEY;
    if (!A.forgePassword || !A.ibmApiKey) {
      throw new Error('--no-prompt requires $FORGE_PASSWORD and $IBMCLOUD_API_KEY');
    }
  } else {
    A = await collectAnswers({ blueprint, answersFile, allOptional: flag('all-optional') });
  }
  if (REHEARSE) log('\n*** REHEARSAL MODE — long waits are synthetic ***');
  if (SKIP_DEPLOY) log('*** SKIP-DEPLOY — recording stops at the filled form; no IBM resources are created ***');

  // ---- 2. narration first: durations set each scene's minimum on-screen time --
  log(`\n[${stamp()}] synthesizing narration (en, fr)…`);
  const audio = await synthAll({
    scenes: SCENES, narration, voices: cfg.voices,
    outDir: path.join(WORK, 'tts'), sampleRate: cfg.audio.sampleRate,
    sentenceSilenceSec: cfg.audio.sentenceSilenceSec, lengthScale: cfg.audio.lengthScale, log,
  });
  const minDur = Object.fromEntries(SCENES.map((s) => [
    s.id,
    cfg.audio.leadInSec + Math.max(...Object.values(audio[s.id]).map((a) => a.dur)) + cfg.audio.tailGapSec,
  ]));

  // ---- 3. drive + record ----------------------------------------------------
  log(`\n[${stamp()}] launching browser…`);
  const browser = await puppeteer.launch({
    headless: true,
    defaultViewport: null,
    args: [
      '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage',
      // The screencast captures the window *surface*; 1167 leaves exactly 1080 of content.
      `--window-size=${cfg.video.windowWidth},${cfg.video.windowHeight}`,
      '--force-device-scale-factor=1', '--hide-scrollbars',
      '--disable-features=IsolateOrigins,site-per-process',
    ],
    // Forge instances commonly use a self-signed cert. (Renamed from ignoreHTTPSErrors in v24.)
    acceptInsecureCerts: true,
  });

  const page = (await browser.pages())[0];
  page.setDefaultTimeout(cfg.timeouts.elementMs);
  const ui = new UI(page, selectors, cfg, log);
  const rec = new Recorder(page, {
    framesDir: path.join(WORK, 'frames'),
    jpegQuality: cfg.video.jpegQuality,
    width: cfg.video.width,
    height: cfg.video.height,
    captureFps: cfg.video.captureFps,
  });

  const ctx = { ui, page, A, cfg, rehearse: REHEARSE, skipDeploy: SKIP_DEPLOY, log };
  let captured;
  try {
    await rec.start();
    for (const scene of SCENES) {
      rec.mark(scene.id, scene.kind);
      const t0 = Date.now();
      log(`[${stamp()}] scene ${scene.id} (${scene.kind})`);
      try {
        await scene.run(ctx);
      } catch (e) {
        log(`  !! ${scene.id} failed: ${e.message}`);
        await page.screenshot({ path: path.join(OUT, `fail-${scene.id}.png`) }).catch(() => {});
        throw e;
      }
      // Interactive scenes hold the frame until the narration would have finished.
      // Wait scenes are compressed 4x, so their real duration is left alone.
      if (scene.kind !== 'wait') {
        const remain = minDur[scene.id] * 1000 - (Date.now() - t0);
        if (remain > 0) await sleep(remain);
      }
      log(`  ${scene.id} took ${((Date.now() - t0) / 1000).toFixed(1)}s (min ${minDur[scene.id].toFixed(1)}s)`);
    }
  } finally {
    captured = await rec.stop().catch((e) => { log(`recorder stop: ${e.message}`); return null; });
    await browser.close().catch(() => {});
  }
  if (!captured) throw new Error('no capture');

  // ---- 4. post-production ---------------------------------------------------
  log(`\n[${stamp()}] captured ${captured.frameCount} frames at ${captured.fps}fps ` +
      `(${(captured.frameCount / captured.fps).toFixed(1)}s)`);
  const timeline = buildTimeline(captured);
  const plan = planTimeline({ timeline, audio, cfg });

  log('\nscene plan:');
  for (const s of plan) {
    log(`  ${s.id.padEnd(16)} ${String(s.speed) + 'x'} real=${s.realDur.toFixed(1)}s ` +
        `-> final=${s.finalDur.toFixed(1)}s` + (s.freezePad > 0.05 ? ` (+${s.freezePad.toFixed(1)}s hold)` : ''));
  }
  fs.writeFileSync(path.join(OUT, 'timeline.json'), JSON.stringify({ plan }, null, 2));

  log(`\n[${stamp()}] encoding master…`);
  const master = await encodeMaster({ framesDir: path.join(WORK, 'frames'), out: path.join(WORK, 'master.mp4'), cfg });

  log(`[${stamp()}] applying speed ramps…`);
  const { list } = await cutScenes({ master, plan, dir: path.join(WORK, 'segs'), cfg });
  const video = await concatVideo({ list, out: path.join(WORK, 'video.mp4') });

  const outputs = [];
  for (const lang of Object.keys(cfg.voices)) {
    log(`[${stamp()}] building ${lang} audio + mux…`);
    const track = await buildAudioTrack({
      lang, plan, audio, dir: path.join(WORK, 'audio'),
      out: path.join(WORK, `audio.${lang}.wav`), cfg,
    });
    const final = path.join(OUT, `demo-${lang}-1080p.mp4`);
    await mux({ video, audioTrack: track, out: final });
    outputs.push(final);
  }

  if (!KEEP) fs.rmSync(path.join(WORK, 'frames'), { recursive: true, force: true });

  log(`\n[${stamp()}] done:`);
  for (const o of outputs) log(`  ${o}`);
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  if (process.env.DEBUG) console.error(e.stack);
  process.exit(1);
});
