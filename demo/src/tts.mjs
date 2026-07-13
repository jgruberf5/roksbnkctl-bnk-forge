// Piper TTS: synthesize narration per scene per language, report exact durations.
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';

const execFileP = promisify(execFile);

/** Run a command, feeding `input` on stdin. (execFile's `input` option is sync-only.) */
function runWithStdin(cmd, args, input) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ['pipe', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', reject);
    p.on('close', (code) => (code === 0
      ? resolve()
      : reject(new Error(`${cmd} exited ${code}: ${err.trim().slice(0, 400)}`))));
    p.stdin.end(input);
  });
}

export function expandHome(p) {
  return p.startsWith('~') ? path.join(os.homedir(), p.slice(1)) : p;
}

/** A piper voice's native sample rate, read from its <model>.json config. */
export function voiceSampleRate(model) {
  const cfg = JSON.parse(fs.readFileSync(expandHome(model) + '.json', 'utf8'));
  const r = cfg?.audio?.sample_rate;
  if (!r) throw new Error(`no audio.sample_rate in ${model}.json`);
  return r;
}

/** Sample rate of an existing audio file. */
export async function probeSampleRate(file) {
  const { stdout } = await execFileP('ffprobe', [
    '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=sample_rate',
    '-of', 'default=nokey=1:noprint_wrappers=1', file,
  ]);
  return parseInt(stdout.trim(), 10);
}

/** Exact duration (seconds) of an audio/video file via ffprobe. */
export async function probeDuration(file) {
  const { stdout } = await execFileP('ffprobe', [
    '-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=nokey=1:noprint_wrappers=1', file,
  ]);
  const d = parseFloat(stdout.trim());
  if (!Number.isFinite(d)) throw new Error(`ffprobe: no duration for ${file}`);
  return d;
}

/**
 * Synthesize one narration line, sentence by sentence, with real silence between.
 *
 * Piper only inserts an inter-sentence pause when it DETECTS a sentence boundary, and our
 * phonetic respellings put a lowercase word after the period ("…IBM Cloud. rocks BNK
 * cuddle…"), which Piper doesn't treat as a new sentence — so a whole multi-sentence
 * narration comes out as one breathless run-on that's hard to follow. So we split on
 * sentence punctuation ourselves, synth each piece with default Piper settings, and
 * concatenate the pieces with `sentenceSilenceSec` of inserted silence. (Approach taken
 * from the working roksbnkctl CLI demo's narrate.py.)
 *
 * Piper voices differ in native sample rate (en_US-ryan-high=22050, fr_FR-tom-medium=44100),
 * so the concatenated clip is resampled to one project rate before it reaches the timeline.
 */
export async function synth({ text, model, outFile, sampleRate, sentenceSilenceSec = 1.0,
                              lengthScale = 1.0, piperBin = '~/.local/bin/piper' }) {
  // Split after . ! ? when followed by whitespace; leaves "24.04" / "v1.17" intact.
  const parts = text.split(/(?<=[.!?])\s+/).map((s) => s.trim()).filter(Boolean);
  const pieces = parts.length ? parts : [text];

  // Work in a NATIVE temp dir, not next to outFile: the cache lives on the /mnt/d Windows
  // mount (drvfs), where unlinking a file ffmpeg/piper just wrote can fail with EACCES.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tts-'));
  const wavs = [];
  for (let i = 0; i < pieces.length; i++) {
    const w = path.join(tmp, `${i}.wav`);
    // --length-scale > 1 slows/relaxes delivery (default piper is hurried for narration);
    // trailing newline matches the reference demo and helps piper end the utterance cleanly.
    await runWithStdin(expandHome(piperBin),
      ['-m', expandHome(model), '--length-scale', String(lengthScale), '-f', w], pieces[i] + '\n');
    if (fs.existsSync(w) && fs.statSync(w).size > 44) wavs.push(w);
  }
  if (!wavs.length) throw new Error(`piper produced no audio for: ${text.slice(0, 60)}`);

  // Concat the sentence WAVs with silence between, then resample to the project rate.
  const listFile = path.join(tmp, 'list.txt');
  const sil = path.join(tmp, 'sil.wav');
  await execFileP('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-t', sentenceSilenceSec.toFixed(3), '-i', `anullsrc=r=${sampleRate}:cl=mono`,
    '-ar', String(sampleRate), '-ac', '1', sil]);
  const resampled = [];
  for (let i = 0; i < wavs.length; i++) {
    const r = path.join(tmp, `r${i}.wav`);
    await execFileP('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y',
      '-i', wavs[i], '-ar', String(sampleRate), '-ac', '1', r]);
    resampled.push(r);
  }
  const seq = resampled.flatMap((r, i) => (i ? [sil, r] : [r]));
  fs.writeFileSync(listFile, seq.map((f) => `file '${path.resolve(f)}'`).join('\n') + '\n');
  await execFileP('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'concat', '-safe', '0', '-i', listFile, '-ar', String(sampleRate), '-ac', '1', outFile]);

  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* OS cleans tmp */ }
  return probeDuration(outFile);
}

/**
 * Synthesize every scene in every language.
 * Returns { [sceneId]: { [lang]: { file, dur } } }
 *
 * Piper samples noise, so the same line re-synthesized is a slightly different length.
 * Results are cached by (text, voice, rate) hash so repeat runs reuse identical audio
 * and the video timeline stays reproducible. Delete the cache dir to re-voice.
 */
export async function synthAll({ scenes, narration, voices, outDir, sampleRate, sentenceSilenceSec = 1.0, lengthScale = 1.0, log = () => {} }) {
  const cacheDir = path.join(outDir, 'cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  const langs = Object.keys(voices);
  const out = {};

  // Each voice stays at its NATIVE rate — no upsampling (that muddied the audio); EN and FR
  // just end up as separate tracks at their own rates, which is fine (muxed independently).
  const rate = Object.fromEntries(langs.map((l) => [l, voiceSampleRate(voices[l])]));

  for (const scene of scenes) {
    out[scene.id] = {};
    for (const lang of langs) {
      const text = narration[lang]?.[scene.id];
      if (!text) throw new Error(`Missing ${lang} narration for scene "${scene.id}"`);
      const sr = rate[lang];
      const key = createHash('sha256')
        .update(`${text} ${voices[lang]} ${sr} ss${sentenceSilenceSec} ls${lengthScale}`).digest('hex').slice(0, 16);
      const file = path.join(cacheDir, `${scene.id}.${lang}.${key}.wav`);

      let dur;
      if (fs.existsSync(file)) {
        dur = await probeDuration(file);
        log(`  tts ${lang} ${scene.id}: ${dur.toFixed(2)}s (cached)`);
      } else {
        dur = await synth({ text, model: voices[lang], outFile: file, sampleRate: sr, sentenceSilenceSec, lengthScale });
        log(`  tts ${lang} ${scene.id}: ${dur.toFixed(2)}s`);
      }
      out[scene.id][lang] = { file, dur, sampleRate: sr };
    }
  }
  return out;
}

/** Longest narration across languages — drives the minimum on-screen scene duration. */
export function maxNarrationDur(perScene) {
  return Math.max(...Object.values(perScene).map((v) => v.dur));
}
