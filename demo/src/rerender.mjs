#!/usr/bin/env node
// Re-render the EN/FR videos with updated narration WITHOUT re-encoding the master or
// re-recording. Reuses out/work/master.mp4 + out/timeline.json (frame timing is fixed;
// only the audio and the hold-to-narration timing change). Fast path for voice edits.
//
//   node src/rerender.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { synthAll } from './tts.mjs';
import { planTimeline, cutScenes, concatVideo, buildAudioTrack, mux } from './postprod.mjs';
import { SCENES } from './scenes.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const OUT = path.join(ROOT, 'out');
const WORK = path.join(OUT, 'work');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'demo.config.json'), 'utf8'));
const narration = JSON.parse(fs.readFileSync(path.join(ROOT, 'scenes', 'narration.json'), 'utf8'));
const master = path.join(WORK, 'master.mp4');
const log = (...a) => console.log(...a);
const stamp = () => new Date().toISOString().slice(11, 19);

async function main() {
  if (!fs.existsSync(master)) throw new Error(`no master.mp4 at ${master} — run a full record/salvage first`);
  const saved = JSON.parse(fs.readFileSync(path.join(OUT, 'timeline.json'), 'utf8')).plan;
  // Rebuild the raw timeline (frame-derived, fixed) from the saved plan.
  const timeline = {
    scenes: saved.map((s) => ({ id: s.id, kind: s.kind, start: s.start, end: s.end, realDur: s.realDur })),
    total: saved[saved.length - 1].end,
  };
  log(`reusing master (${timeline.scenes.length} scenes, ${(timeline.total / 60).toFixed(1)} min of source)`);

  log(`\n[${stamp()}] synthesizing narration (updated)…`);
  const audio = await synthAll({
    scenes: SCENES, narration, voices: cfg.voices, outDir: path.join(WORK, 'tts'),
    sampleRate: cfg.audio.sampleRate, sentenceSilenceSec: cfg.audio.sentenceSilenceSec,
    lengthScale: cfg.audio.lengthScale, log,
  });

  const plan = planTimeline({ timeline, audio, cfg });
  fs.writeFileSync(path.join(OUT, 'timeline.json'), JSON.stringify({ plan }, null, 2));
  const totalFinal = plan.reduce((a, s) => a + s.finalDur, 0);
  log(`\ntarget length: ${(totalFinal / 60).toFixed(1)} min`);

  log(`[${stamp()}] cutting scenes from master (4x on waits)…`);
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
main().catch((e) => { console.error(`\nRERENDER FAILED: ${e.message}`); if (process.env.DEBUG) console.error(e.stack); process.exit(1); });
