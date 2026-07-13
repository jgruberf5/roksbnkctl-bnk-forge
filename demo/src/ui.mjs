// Resilient UI driver for the BNK Forge (React + Radix + Tailwind) UI, plus on-screen
// affordances (synthetic cursor, click ripple, highlight) that make a headless capture
// read like someone is actually using the app.
//
// Selector spec — a logical name maps to an ordered list of these; first match wins:
//   'css:button[type=submit]'  or bare CSS            plain query
//   'label:Repository URL'     control bound to a <label> (handles `for=`, and the
//                              *-form-item ids Radix generates, which change per render)
//   'btn:Add Source'           <button> whose text matches
//   'text:IBM ROKS + BNK'      any element whose text matches
//   'dlg>…'                    scope the above to the TOPMOST open [role=dialog] or
//                              [role=alertdialog] (Radix confirm popups use alertdialog)
//
// Why not data-testid / name= ? This build ships neither on form controls; ids look like
// ':r2e:-form-item' and are regenerated on every render.
import fs from 'node:fs';

const norm = (s) => (s || '').replace(/\s*\*\s*$/, '').replace(/\s+/g, ' ').trim().toLowerCase();

export class UI {
  constructor(page, selectors, cfg, log = console.log) {
    this.page = page;
    this.sel = selectors;
    this.cfg = cfg;
    this.log = log;
    this.cursor = { x: 960, y: 540 };
  }

  candidates(name) {
    const c = this.sel[name];
    if (!c) throw new Error(`No selector entry for "${name}" — add it to config/selectors.json`);
    return Array.isArray(c) ? c : [c];
  }

  /** Resolve one spec to a visible ElementHandle, or null. */
  async resolveOne(spec) {
    const inDialog = spec.startsWith('dlg>');
    const s = inDialog ? spec.slice(4) : spec;

    let handle = null;
    if (s.startsWith('label:')) handle = await this.#byLabel(s.slice(6), inDialog);
    else if (s.startsWith('btn:')) handle = await this.#byText(s.slice(4), inDialog, 'button');
    else if (s.startsWith('text:')) handle = await this.#byText(s.slice(5), inDialog, '*');
    else handle = await this.#byCss(s.startsWith('css:') ? s.slice(4) : s, inDialog);

    if (!handle) return null;
    const box = await handle.boundingBox().catch(() => null);
    if (!box || box.width === 0 || box.height === 0) return null;
    return handle;
  }

  async #scopeExpr(inDialog) {
    return inDialog;
  }

  async #byCss(css, inDialog) {
    const h = await this.page.evaluateHandle((css, inDialog) => {
      const dlgs = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')];
      const root = inDialog ? dlgs[dlgs.length - 1] : document;
      return root ? root.querySelector(css) : null;
    }, css, inDialog);
    return h.asElement();
  }

  async #byLabel(text, inDialog) {
    const h = await this.page.evaluateHandle((text, inDialog) => {
      const N = (s) => (s || '').replace(/\s*\*\s*$/, '').replace(/\s+/g, ' ').trim().toLowerCase();
      const dlgs = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')];
      const root = inDialog ? dlgs[dlgs.length - 1] : document.body;
      if (!root) return null;
      const CTL = 'input,textarea,select,button[role=combobox],[role=switch],button[role=radio]';
      for (const l of root.querySelectorAll('label')) {
        if (N(l.innerText) !== N(text)) continue;
        const f = l.getAttribute('for');
        if (f) { const el = document.getElementById(f); if (el) return el; }
        // Radix FormItem: label and control are siblings under one wrapper.
        const wrap = l.parentElement;
        const c = wrap?.querySelector(CTL) || wrap?.parentElement?.querySelector(CTL);
        if (c) return c;
      }
      return null;
    }, text, inDialog);
    return h.asElement();
  }

  async #byText(text, inDialog, tag) {
    const h = await this.page.evaluateHandle((text, inDialog, tag) => {
      const N = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const dlgs = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')];
      const root = inDialog ? dlgs[dlgs.length - 1] : document.body;
      if (!root) return null;
      const want = N(text);
      const els = [...root.querySelectorAll(tag)];
      // exact first, then prefix — avoids "Add Source" matching "Add Source…" siblings
      return els.find((e) => N(e.innerText) === want)
          || els.find((e) => N(e.innerText).startsWith(want))
          || null;
    }, text, inDialog, tag);
    return h.asElement();
  }

  async find(name, { timeout } = {}) {
    const t = timeout ?? this.cfg.timeouts.elementMs;
    const cands = this.candidates(name);
    const deadline = Date.now() + t;
    while (Date.now() < deadline) {
      for (const spec of cands) {
        const el = await this.resolveOne(spec).catch(() => null);
        if (el) return { el, spec, box: await el.boundingBox() };
      }
      await sleep(200);
    }
    throw new Error(`"${name}" not found within ${t}ms. Tried:\n  ${cands.join('\n  ')}`);
  }

  async exists(name, timeout = 2500) {
    try { await this.find(name, { timeout }); return true; } catch { return false; }
  }

  // ---- on-screen affordances -------------------------------------------------
  async installCursor() {
    await this.page.evaluate(() => {
      if (document.getElementById('__demo_cursor')) return;
      const style = document.createElement('style');
      style.textContent = `
        #__demo_cursor{position:fixed;z-index:2147483647;width:22px;height:22px;margin:-4px 0 0 -4px;
          pointer-events:none;transition:transform .05s linear;filter:drop-shadow(0 2px 3px rgba(0,0,0,.5))}
        #__demo_ripple{position:fixed;z-index:2147483646;border:3px solid #f5c518;border-radius:50%;
          pointer-events:none;opacity:0;width:14px;height:14px;margin:-7px 0 0 -7px}
        @keyframes __demo_pop{0%{transform:scale(.4);opacity:.95}100%{transform:scale(3.4);opacity:0}}
        #__demo_hl{position:fixed;z-index:2147483645;border:3px solid #f5c518;border-radius:6px;
          pointer-events:none;transition:all .18s ease;opacity:0}`;
      document.head.appendChild(style);
      const c = document.createElement('div');
      c.id = '__demo_cursor';
      c.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22"><path d="M4 2 L4 20 L9 15.5 L12.5 22 L15.5 20.5 L12 14.5 L19 14 Z" fill="#fff" stroke="#111" stroke-width="1.3"/></svg>`;
      document.body.appendChild(c);
      const r = document.createElement('div'); r.id = '__demo_ripple'; document.body.appendChild(r);
      const h = document.createElement('div'); h.id = '__demo_hl'; document.body.appendChild(h);
      window.__demoCursor = (x, y) => { c.style.transform = `translate(${x}px,${y}px)`; };
      window.__demoRipple = (x, y) => {
        r.style.left = x + 'px'; r.style.top = y + 'px';
        r.style.animation = 'none'; void r.offsetWidth; r.style.animation = '__demo_pop .45s ease-out';
      };
      window.__demoHighlight = (b) => {
        if (!b) { h.style.opacity = '0'; return; }
        Object.assign(h.style, { opacity: '1', left: b.x - 4 + 'px', top: b.y - 4 + 'px',
          width: b.width + 8 + 'px', height: b.height + 8 + 'px' });
      };
    }).catch(() => {});
    await this.page.evaluate((p) => window.__demoCursor?.(p.x, p.y), this.cursor).catch(() => {});
  }

  async glideTo(x, y, steps = 22) {
    const from = { ...this.cursor };
    for (let i = 1; i <= steps; i++) {
      const k = ease(i / steps);
      const nx = from.x + (x - from.x) * k, ny = from.y + (y - from.y) * k;
      await this.page.mouse.move(nx, ny);
      await this.page.evaluate((p) => window.__demoCursor?.(p.x, p.y), { x: nx, y: ny }).catch(() => {});
      await sleep(10);
    }
    this.cursor = { x, y };
  }

  async highlight(name) {
    const { box } = await this.find(name);
    await this.page.evaluate((b) => window.__demoHighlight?.(b), box).catch(() => {});
    return box;
  }

  async clearHighlight() {
    await this.page.evaluate(() => window.__demoHighlight?.(null)).catch(() => {});
  }

  // ---- actions ---------------------------------------------------------------
  async click(name, { settle = 400 } = {}) {
    const { el, spec } = await this.find(name);
    await el.scrollIntoView().catch(() => {});
    await sleep(150);
    const b = await el.boundingBox();
    if (b) {
      const x = b.x + b.width / 2, y = b.y + b.height / 2;
      await this.glideTo(x, y);
      await this.page.evaluate((p) => window.__demoRipple?.(p.x, p.y), { x, y }).catch(() => {});
      await sleep(130);
    }
    await el.click();
    this.log(`    click ${name}  (${spec})`);
    await sleep(settle);
  }

  async type(name, value, { secret = false, delay = 32 } = {}) {
    const { el, spec } = await this.find(name);
    await el.scrollIntoView().catch(() => {});
    const b = await el.boundingBox();
    if (b) await this.glideTo(b.x + Math.min(b.width / 2, 220), b.y + b.height / 2);
    await el.click({ clickCount: 3 });
    await this.page.keyboard.press('Backspace');
    await el.type(String(value), { delay });
    this.log(`    type  ${name} = ${secret ? '••••••••' : value}  (${spec})`);
    await sleep(200);
  }

  /**
   * Radix Select: click the trigger, then click the [role=option] whose text matches.
   * Native <select> is handled too — this build renders BOTH in some dialogs, and the
   * native one is visually hidden, so the Radix trigger must win.
   */
  async selectOption(name, optionText) {
    const { el, spec } = await this.find(name);
    const isNative = await el.evaluate((n) => n.tagName === 'SELECT');
    if (isNative) {
      await el.select(optionText);
      this.log(`    select ${name} = ${optionText} (native)`);
      await sleep(300);
      return;
    }
    const b = await el.boundingBox();
    if (b) await this.glideTo(b.x + b.width / 2, b.y + b.height / 2);
    await el.click();
    await sleep(700);
    const opt = await this.page.evaluateHandle((want) => {
      const N = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const opts = [...document.querySelectorAll('[role=option]')];
      return opts.find((o) => N(o.innerText) === N(want))
          || opts.find((o) => N(o.innerText).includes(N(want))) || null;
    }, optionText);
    const oe = opt.asElement();
    if (!oe) {
      const seen = await this.page.evaluate(() => [...document.querySelectorAll('[role=option]')].map((o) => o.innerText.trim()));
      await this.page.keyboard.press('Escape');
      throw new Error(`option "${optionText}" not found for ${name}. Options: ${JSON.stringify(seen)}`);
    }
    await oe.click();
    this.log(`    select ${name} = ${optionText}  (${spec})`);
    await sleep(500);
  }

  /** Radix switch/checkbox to an explicit state. */
  async setToggle(name, on) {
    const { el } = await this.find(name);
    const cur = await el.evaluate((n) => {
      const a = n.getAttribute('aria-checked') ?? n.getAttribute('data-state');
      if (a === 'true' || a === 'checked') return true;
      if (a === 'false' || a === 'unchecked') return false;
      if ('checked' in n) return !!n.checked;
      return null;
    });
    if (cur === on) { this.log(`    toggle ${name} already ${on}`); return; }
    await this.click(name);
    this.log(`    toggle ${name} -> ${on}`);
  }

  async goto(url) {
    await this.page.goto(url, { waitUntil: 'networkidle2', timeout: this.cfg.timeouts.navMs });
    await this.installCursor();
  }

  /**
   * Navigate and wait for the SPA to actually paint one of `readyNames`. Headless first
   * paint is occasionally blank (the JS bundle hasn't run); reload up to `retries` times
   * rather than letting a downstream `find` fail on an empty page.
   */
  async gotoApp(url, readyNames, { retries = 2 } = {}) {
    for (let attempt = 0; attempt <= retries; attempt++) {
      await this.page.goto(url, { waitUntil: 'networkidle2', timeout: this.cfg.timeouts.navMs }).catch(() => {});
      for (const name of readyNames) {
        if (await this.exists(name, 15000)) { await this.installCursor(); return name; }
      }
      this.log(`    app not ready (blank paint?), reloading [${attempt + 1}/${retries}]`);
      await this.page.reload({ waitUntil: 'networkidle2', timeout: this.cfg.timeouts.navMs }).catch(() => {});
    }
    await this.installCursor();
    return null;
  }

  /** Click a left-nav entry by its href, then reinstall the cursor layer. */
  async nav(name) {
    await this.click(name);
    await sleep(900);
    await this.installCursor();
  }

  async until(label, fn, { timeout, interval = 5000 } = {}) {
    const t = timeout ?? this.cfg.timeouts.phaseMs;
    const deadline = Date.now() + t;
    while (Date.now() < deadline) {
      if (await fn().catch(() => false)) { this.log(`    ${label}: satisfied`); return true; }
      await sleep(interval);
    }
    throw new Error(`Timed out after ${t}ms waiting for: ${label}`);
  }

  /** True when any element's text matches — used for status badges in tables. */
  async pageHasText(text) {
    return this.page.evaluate((t) => document.body.innerText.toLowerCase().includes(t.toLowerCase()), text);
  }

  // ---- table rows ------------------------------------------------------------
  // The catalog lists a dozen blueprints, each with its own "Deploy" button, so buttons
  // must be located relative to the row that names the blueprint.
  //
  // `inDialog` matters more than it looks: the Sources dialog's table sits ON TOP of the
  // Modules table, and both contain rows whose text includes "roksbnkctl". A page-wide
  // scan silently returns the wrong row.

  async #rowHandle(rowText, sel, inDialog = false) {
    const h = await this.page.evaluateHandle((rowText, sel, inDialog) => {
      const dlgs = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')];
      const root = inDialog ? dlgs[dlgs.length - 1] : document;
      if (!root) return null;
      const row = [...root.querySelectorAll('tr')].find((r) => r.innerText.includes(rowText));
      if (!row) return null;
      if (!sel) return row;
      if (sel.kind === 'button') {
        const N = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
        return [...row.querySelectorAll('button')].find((b) =>
          N(b.innerText) === N(sel.text) || N(b.getAttribute('aria-label')) === N(sel.text)) || null;
      }
      return row.querySelector(sel.css) || null;
    }, rowText, sel ?? null, inDialog);
    return h.asElement();
  }

  async rowText(rowText, { inDialog = false } = {}) {
    const el = await this.#rowHandle(rowText, null, inDialog);
    return el ? el.evaluate((r) => r.innerText.replace(/\s+/g, ' ').trim()) : null;
  }

  async rowExists(rowText, { inDialog = false } = {}) {
    return !!(await this.#rowHandle(rowText, null, inDialog));
  }

  /** Click a button inside the row that contains `rowText` (matches text or aria-label). */
  async clickRowButton(rowText, btnText, { inDialog = false } = {}) {
    const el = await this.#rowHandle(rowText, { kind: 'button', text: btnText }, inDialog);
    if (!el) throw new Error(`row "${rowText}" has no button "${btnText}"`);
    const disabled = await el.evaluate((b) => !!b.disabled);
    if (disabled) throw new Error(`button "${btnText}" in row "${rowText}" is disabled`);
    await el.scrollIntoView().catch(() => {});
    await sleep(150);
    const b = await el.boundingBox();
    if (b) {
      const x = b.x + b.width / 2, y = b.y + b.height / 2;
      await this.glideTo(x, y);
      await this.page.evaluate((p) => window.__demoRipple?.(p.x, p.y), { x, y }).catch(() => {});
      await sleep(130);
    }
    await el.click();
    this.log(`    click row["${rowText}"] > ${btnText}`);
    await sleep(500);
  }

  async highlightRow(rowText, { inDialog = false } = {}) {
    const el = await this.#rowHandle(rowText, null, inDialog);
    if (!el) return null;
    const box = await el.boundingBox();
    await this.page.evaluate((b) => window.__demoHighlight?.(b), box).catch(() => {});
    return box;
  }

  /** Open a project from the /projects list by its name (the row isn't a plain link). */
  async openProjectByName(name) {
    const handle = (await this.page.evaluateHandle((name) => {
      const els = [...document.querySelectorAll('a,button,td,div,h3,span')];
      return els.find((e) => e.innerText.trim() === name)
          || els.find((e) => e.innerText.includes(name) && e.innerText.length < 60) || null;
    }, name)).asElement();
    if (!handle) throw new Error(`project "${name}" not found in list`);
    const b = await handle.boundingBox();
    if (b) await this.glideTo(b.x + Math.min(b.width / 2, 200), b.y + b.height / 2);
    await handle.click();
    await this.page.waitForFunction(() => /\/projects\/[^/]+$/.test(location.pathname), { timeout: this.cfg.timeouts.navMs })
      .catch(() => {});
    await this.installCursor();
    this.log(`    opened project ${name} -> ${this.page.url()}`);
  }

  /** Accept a Radix alertdialog confirmation (they use role=alertdialog, not dialog). */
  async confirmAlert(words = ['Delete Source', 'Delete', 'Remove', 'Confirm', 'Yes', 'Import']) {
    await sleep(900);
    for (const w of words) {
      const h = await this.page.$(`[role=alertdialog] button::-p-text(${w})`);
      if (h) { await h.click(); await sleep(1500); return w; }
    }
    return null;
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ease = (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

export function loadSelectors(file) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return Object.fromEntries(Object.entries(raw).filter(([k]) => !k.startsWith('_')));
}
