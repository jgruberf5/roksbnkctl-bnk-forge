#!/usr/bin/env node
// Selector calibration. Logs into a live BNK Forge, visits each page the demo touches,
// and reports (a) which logical selectors already resolve and (b) candidate selectors
// for the ones that don't — so config/selectors.json can be pinned to the real DOM.
//
//   npm run probe                      # prompts for URL + credentials
//   FORGE_PASSWORD=… npm run probe -- --url https://forge.example --user admin
//
// Writes out/selectors.discovered.json and a screenshot per page.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline/promises';
import puppeteer from 'puppeteer';
import { UI, loadSelectors, sleep } from './ui.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'demo.config.json'), 'utf8'));
const selectors = loadSelectors(path.join(ROOT, 'config', 'selectors.json'));
const OUT = path.join(ROOT, 'out');

/** Everything interactive on the page, described well enough to hand-pick a selector. */
const HARVEST = () => {
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  };
  const css = (el) => {
    if (el.dataset?.testid) return `[data-testid=${el.dataset.testid}]`;
    if (el.id) return `#${el.id}`;
    if (el.name) return `${el.tagName.toLowerCase()}[name=${el.name}]`;
    const cls = [...el.classList].filter((c) => !/^(css|sc)-/.test(c)).slice(0, 2);
    return el.tagName.toLowerCase() + (cls.length ? '.' + cls.join('.') : '');
  };
  const out = [];
  for (const el of document.querySelectorAll(
    'a,button,input,select,textarea,[role=button],[role=switch],[role=tab],[role=checkbox]')) {
    if (!vis(el)) continue;
    out.push({
      tag: el.tagName.toLowerCase(),
      type: el.getAttribute('type') || undefined,
      role: el.getAttribute('role') || undefined,
      name: el.getAttribute('name') || undefined,
      testid: el.dataset?.testid || undefined,
      href: el.getAttribute('href') || undefined,
      aria: el.getAttribute('aria-label') || undefined,
      text: (el.innerText || el.value || '').trim().slice(0, 48) || undefined,
      css: css(el),
    });
  }
  return { url: location.href, title: document.title, controls: out };
};

async function probePage(page, ui, label, report) {
  await sleep(1200);
  const harvest = await page.evaluate(HARVEST);
  const resolved = {};
  for (const name of Object.keys(selectors)) {
    for (const sel of ui.candidates(name)) {
      try {
        const el = await page.$(sel);
        if (el && (await el.boundingBox())) { resolved[name] = sel; break; }
      } catch {}
    }
  }
  report[label] = { url: harvest.url, title: harvest.title, resolved, controls: harvest.controls };
  await page.screenshot({ path: path.join(OUT, `probe-${label}.png`), fullPage: false }).catch(() => {});
  console.log(`\n=== ${label}  (${harvest.url}) ===`);
  console.log(`  resolved: ${Object.keys(resolved).join(', ') || '(none)'}`);
  console.log(`  ${harvest.controls.length} interactive controls:`);
  for (const c of harvest.controls.slice(0, 40)) {
    console.log(`    ${(c.testid ? '[testid] ' : '').padEnd(9)}${c.css.padEnd(34)} ${(c.text || c.aria || c.href || '').slice(0, 40)}`);
  }
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const url = opt('url', process.env.FORGE_URL) || await rl.question('Forge URL: ');
  const user = opt('user', process.env.FORGE_USERNAME) || await rl.question('Username: ');
  const pass = process.env.FORGE_PASSWORD || await rl.question('Password: ');
  rl.close();

  const browser = await puppeteer.launch({
    headless: true, defaultViewport: null,
    args: ['--no-sandbox', `--window-size=${cfg.video.windowWidth},${cfg.video.windowHeight}`,
           '--force-device-scale-factor=1', '--hide-scrollbars'],
    // Forge instances commonly use a self-signed cert. (Renamed from ignoreHTTPSErrors in v24.)
    acceptInsecureCerts: true,
  });
  const page = (await browser.pages())[0];
  const ui = new UI(page, selectors, cfg, () => {});
  const report = {};

  await page.goto(url, { waitUntil: 'networkidle2', timeout: cfg.timeouts.navMs });
  await probePage(page, ui, 'landing', report);

  // Best-effort login using whatever the login selectors resolve to.
  try {
    await ui.type('login.username', user);
    await ui.type('login.password', pass, { secret: true });
    await ui.click('login.submit');
    await sleep(4000);
  } catch (e) {
    console.log(`\n(login skipped/failed: ${e.message.split('\n')[0]})`);
  }
  await probePage(page, ui, 'after-login', report);

  const base = new URL(url).origin;
  for (const [label, p] of [
    ['auth-templates', '/auth-templates'],
    ['modules', '/modules'],
    ['blueprints', '/blueprints'],
    ['projects', '/projects'],
  ]) {
    try {
      await page.goto(base + p, { waitUntil: 'networkidle2', timeout: cfg.timeouts.navMs });
      await probePage(page, ui, label, report);
    } catch (e) {
      console.log(`\n=== ${label} === unreachable: ${e.message.split('\n')[0]}`);
    }
  }

  await browser.close();
  const f = path.join(OUT, 'selectors.discovered.json');
  fs.writeFileSync(f, JSON.stringify(report, null, 2));

  const missing = Object.keys(selectors).filter(
    (n) => !Object.values(report).some((r) => r.resolved[n]));
  console.log(`\nWrote ${f}`);
  console.log(`Screenshots: ${OUT}/probe-*.png`);
  if (missing.length) {
    console.log(`\nUNRESOLVED (${missing.length}) — pin these in config/selectors.json:`);
    for (const m of missing) console.log(`  ${m}`);
  } else {
    console.log('\nAll logical selectors resolved.');
  }
}

main().catch((e) => { console.error(`\nFAILED: ${e.message}`); process.exit(1); });
