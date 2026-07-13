// Headless screencast recorder — fixed-rate sampler.
//
// puppeteer's page.screencast() needs a headed browser (silently writes 0 bytes under
// headless), so we drive CDP Page.startScreencast directly. Chrome emits frames at a
// variable rate (fast during animation, ~1/s when idle); saving every one and feeding
// them through ffmpeg's concat demuxer with per-frame durations is O(n) slow and blows
// up to 100k+ files across a 45-minute deploy wait.
//
// Instead we keep only the LATEST decoded frame in memory and flush it to a sequentially
// numbered file on a fixed-rate timer (captureFps). The result is a constant-rate image
// sequence the fast image2 demuxer can read (`-framerate N -i f%07d.jpg`), and scene
// boundaries are recorded as frame indices, so cuts land on exact frames.
import fs from 'node:fs';
import path from 'node:path';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class Recorder {
  constructor(page, { framesDir, jpegQuality, width, height, captureFps, startIndex = 0, keepExisting = false }) {
    this.page = page;
    this.framesDir = framesDir;
    this.jpegQuality = jpegQuality;
    this.width = width;
    this.height = height;
    this.fps = captureFps;
    this.n = startIndex;        // next frame index (>0 to append/resume a prior capture)
    this.keepExisting = keepExisting;
    this.latest = null;         // most recent JPEG buffer
    this.marks = [];            // { id, kind, frame }
  }

  async start() {
    // keepExisting: append to a prior capture (salvage/resume) without wiping its frames.
    if (!this.keepExisting) fs.rmSync(this.framesDir, { recursive: true, force: true });
    fs.mkdirSync(this.framesDir, { recursive: true });
    this.cdp = await this.page.createCDPSession();

    this.cdp.on('Page.screencastFrame', (f) => {
      // Ack immediately; Chrome stalls the stream until the prior frame is acked.
      this.cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {});
      this.latest = Buffer.from(f.data, 'base64');
    });

    await this.cdp.send('Page.startScreencast', {
      format: 'jpeg',
      quality: this.jpegQuality,
      maxWidth: this.width,
      maxHeight: this.height,
      everyNthFrame: 1,
    });

    // Wait for the first frame so the sequence never starts with a gap.
    const t0 = Date.now();
    while (!this.latest && Date.now() - t0 < 10000) await sleep(50);
    this.#flush();                                   // frame 0
    this.timer = setInterval(() => this.#flush(), Math.round(1000 / this.fps));
  }

  #flush() {
    if (!this.latest) return;
    fs.writeFileSync(path.join(this.framesDir, `f${String(this.n).padStart(7, '0')}.jpg`), this.latest);
    this.n++;
  }

  /** Current position in seconds — handy for logging. */
  now() {
    return this.n / this.fps;
  }

  mark(id, kind) {
    this.marks.push({ id, kind, frame: this.n });
  }

  async stop() {
    clearInterval(this.timer);
    try { await this.cdp.send('Page.stopScreencast'); } catch {}
    this.#flush();                                   // capture the final state
    if (this.n === 0) throw new Error('recorder captured zero frames');
    return { frameCount: this.n, marks: this.marks, fps: this.fps };
  }
}

/**
 * Convert frame-indexed marks into per-scene spans:
 *   scenes: [{ id, kind, start, end, realDur }]   (start/end in seconds)
 * Fixed capture rate means frame index / fps == wall-clock seconds exactly.
 */
export function buildTimeline({ frameCount, marks, fps }) {
  const scenes = marks.map((m, i) => {
    const startFrame = m.frame;
    const endFrame = i + 1 < marks.length ? marks[i + 1].frame : frameCount;
    return {
      id: m.id,
      kind: m.kind,
      start: startFrame / fps,
      end: endFrame / fps,
      realDur: Math.max((endFrame - startFrame) / fps, 1 / fps),
    };
  });
  return { scenes, total: frameCount / fps };
}
