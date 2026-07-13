// Post-production: frames -> master -> per-scene speed ramps -> per-language audio -> mux.
//
// Timing contract (this is the whole trick):
//   speed        = 4 for `wait` scenes, 1 otherwise
//   spedDur      = realDur / speed
//   needed       = leadIn + max(narration over ALL languages) + tailGap
//   finalDur     = max(spedDur, needed)          <- one video, valid for every language
//
// Because finalDur is computed against the LONGEST language, a single video track
// fits both the EN and FR audio tracks. Each language's audio for a scene is:
//   silence(leadIn) + narration(lang) + silence(finalDur - leadIn - narr)
// so the silence between two spoken sections is always tailGap + leadIn (>= 2.5s).
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import path from 'node:path';

const execFileP = promisify(execFile);
const MIN_TAIL = 0.02;

async function ff(args) {
  return execFileP('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], {
    maxBuffer: 1 << 28,
  });
}

/** Resolve each scene's final on-screen duration and how it gets there. */
export function planTimeline({ timeline, audio, cfg }) {
  const { leadInSec, tailGapSec } = cfg.audio;
  const factor = cfg.speed.waitSceneFactor;
  const fps = cfg.video.fps;
  // Snap to whole frames: a video segment can only be an integer number of frames, so
  // an unsnapped finalDur would round per scene and drift audio out of sync across 20+ scenes.
  const snap = (d) => Math.ceil(d * fps) / fps;

  return timeline.scenes.map((s) => {
    const speed = s.kind === 'wait' ? factor : 1;
    const spedDur = s.realDur / speed;
    const narrMax = Math.max(...Object.values(audio[s.id]).map((a) => a.dur));
    const needed = leadInSec + narrMax + tailGapSec;
    const finalDur = snap(Math.max(spedDur, needed));
    return { ...s, speed, spedDur, narrMax, needed, finalDur, freezePad: finalDur - spedDur };
  });
}

/**
 * Encode the master from the fixed-rate image sequence via the image2 demuxer — reads
 * `frames/f%07d.jpg` sequentially at `captureFps`, far faster than the concat demuxer.
 * Output is CFR at video.fps (frames duplicated if captureFps < video.fps).
 */
export async function encodeMaster({ framesDir, out, cfg }) {
  const { fps, crf, preset, width, height, captureFps } = cfg.video;
  await ff([
    '-framerate', String(captureFps),
    '-i', `${framesDir}/f%07d.jpg`,
    '-vf', `scale=${width}:${height}:force_original_aspect_ratio=decrease,` +
           `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,format=yuv420p`,
    '-r', String(fps),
    '-c:v', 'libx264', '-preset', preset, '-crf', String(crf),
    out,
  ]);
  return out;
}

export async function cutScenes({ master, plan, dir, cfg }) {
  fs.mkdirSync(dir, { recursive: true });
  const fps = cfg.video.fps;
  const segs = [];
  for (const [i, s] of plan.entries()) {
    const seg = path.join(dir, `seg${String(i).padStart(3, '0')}.mp4`);
    const frames = Math.round(s.finalDur * fps);
    // Always clone-pad past the target, then cut to an exact frame count. Relying on
    // tpad's duration alone leaves segments a frame short or long depending on rounding.
    const vf = [
      `setpts=PTS/${s.speed}`,
      `tpad=stop_mode=clone:stop_duration=${(s.freezePad + 0.5).toFixed(3)}`,
      `fps=${fps}`, 'format=yuv420p',
    ];
    await ff([
      '-ss', s.start.toFixed(3), '-t', s.realDur.toFixed(3), '-i', master,
      '-filter:v', vf.join(','), '-an', '-frames:v', String(frames),
      '-c:v', 'libx264', '-preset', cfg.video.preset, '-crf', String(cfg.video.crf),
      '-r', String(fps),
      seg,
    ]);
    segs.push(seg);
  }
  const list = path.join(dir, 'segs.txt');
  fs.writeFileSync(list, segs.map((s) => `file '${path.resolve(s)}'`).join('\n') + '\n');
  return { segs, list };
}

export async function concatVideo({ list, out }) {
  await ff(['-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', out]);
  return out;
}

/** Build one continuous narration track for a language, aligned to the final timeline. */
export async function buildAudioTrack({ lang, plan, audio, dir, out, cfg }) {
  fs.mkdirSync(dir, { recursive: true });
  // Use the voice's NATIVE rate (no upsample); every clip for a language shares it.
  const sr = audio[plan[0].id][lang].sampleRate || cfg.audio.sampleRate;
  const lead = cfg.audio.leadInSec;
  const parts = [];

  for (const [i, s] of plan.entries()) {
    const { file, dur } = audio[s.id][lang];
    const tail = Math.max(s.finalDur - lead - dur, MIN_TAIL);
    const part = path.join(dir, `a${String(i).padStart(3, '0')}.${lang}.wav`);
    await ff([
      '-f', 'lavfi', '-t', lead.toFixed(3), '-i', `anullsrc=r=${sr}:cl=mono`,
      '-i', file,
      '-f', 'lavfi', '-t', tail.toFixed(3), '-i', `anullsrc=r=${sr}:cl=mono`,
      '-filter_complex',
      `[0:a][1:a][2:a]concat=n=3:v=0:a=1,aresample=${sr}[a]`,
      '-map', '[a]', '-ar', String(sr), '-ac', '1', part,
    ]);
    parts.push(part);
  }

  const list = path.join(dir, `parts.${lang}.txt`);
  fs.writeFileSync(list, parts.map((p) => `file '${path.resolve(p)}'`).join('\n') + '\n');
  await ff(['-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', out]);
  return out;
}

export async function mux({ video, audioTrack, out }) {
  await ff([
    '-i', video, '-i', audioTrack,
    '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k',
    '-movflags', '+faststart', '-shortest',
    out,
  ]);
  return out;
}
