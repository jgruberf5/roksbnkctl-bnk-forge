#!/usr/bin/env node
// Hear a narration line instantly while editing scenes/narration.json — no video, no browser.
//
//   node src/preview.mjs en "We open the Catalog and register the repository."
//   node src/preview.mjs fr cred_secret          # preview a scene's CURRENT text from narration.json
//
// Writes out/preview-<lang>.mp3 (and .wav) using the current audio settings from
// config/demo.config.json (lengthScale, sentenceSilenceSec). Play it in any media player.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { synth, voiceSampleRate } from './tts.mjs';

const execFileP = promisify(execFile);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'demo.config.json'), 'utf8'));
const narration = JSON.parse(fs.readFileSync(path.join(ROOT, 'scenes', 'narration.json'), 'utf8'));

const lang = (process.argv[2] || 'en').toLowerCase();
const rest = process.argv.slice(3).join(' ').trim();
if (!cfg.voices[lang]) { console.error(`unknown lang "${lang}" (have: ${Object.keys(cfg.voices).join(', ')})`); process.exit(1); }
if (!rest) { console.error('usage: node src/preview.mjs <en|fr> "<text>"  |  <en|fr> <sceneId>'); process.exit(1); }

// If `rest` is exactly a scene id, preview that scene's current text; otherwise treat as literal text.
const text = narration[lang][rest] ?? rest;
const outDir = path.join(ROOT, 'out');
fs.mkdirSync(outDir, { recursive: true });
const wav = path.join(outDir, `preview-${lang}.wav`);
const mp3 = path.join(outDir, `preview-${lang}.mp3`);

const dur = await synth({
  text, model: cfg.voices[lang], outFile: wav,
  sampleRate: voiceSampleRate(cfg.voices[lang]),
  sentenceSilenceSec: cfg.audio.sentenceSilenceSec, lengthScale: cfg.audio.lengthScale,
});
await execFileP('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'libmp3lame', '-b:a', '160k', mp3]);

console.log(`\n  text : ${text}`);
console.log(`  lang : ${lang}   lengthScale ${cfg.audio.lengthScale}   sentenceSilence ${cfg.audio.sentenceSilenceSec}s`);
console.log(`  dur  : ${dur.toFixed(2)}s`);
console.log(`  play : ${mp3}\n`);
