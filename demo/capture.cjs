// Screenshot driver for the customer walkthrough. Logs in once, then visits the
// paths it is given and writes a PNG per screen.
const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

const BASE = process.env.FORGE_URL || 'https://161.156.198.185:8443';
const USER = process.env.FORGE_USER || 'admin';
const PASS = process.env.FORGE_PASSWORD;
const OUT  = process.env.SHOT_DIR || path.join(__dirname, '..', 'scripts', 'demo', 'screenshots');

const steps = JSON.parse(process.env.SHOT_STEPS || '[]');   // [{name, path, waitMs, waitFor}]

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await puppeteer.launch({
    headless: 'new',
    ignoreHTTPSErrors: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--ignore-certificate-errors'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000, deviceScaleFactor: 1 });

  const shot = async (name) => {
    const f = path.join(OUT, `${name}.png`);
    await page.screenshot({ path: f, fullPage: false });
    console.log(`  captured ${name}.png`);
  };

  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle2', timeout: 60000 }).catch(() => {});
  await new Promise(r => setTimeout(r, 2500));
  if (process.env.SHOT_LOGIN === '1') await shot('01-login');

  // Log in via the form when it is present; fall back to seeding the token.
  const hasUser = await page.$('input[name="username"], input#username, input[type="text"]');
  if (hasUser) {
    await page.type('input[name="username"], input#username, input[type="text"]', USER, { delay: 20 });
    await page.type('input[name="password"], input#password, input[type="password"]', PASS, { delay: 20 });
    await Promise.all([
      page.click('button[type="submit"]').catch(() => {}),
      page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 45000 }).catch(() => {}),
    ]);
  }
  await new Promise(r => setTimeout(r, 3500));

  // Click an element whose visible text matches, without needing a brittle
  // CSS path — the UI is React and class names are generated.
  const clickText = async (text, tags = ['button', '[role="button"]', 'a',
                                         '[role="option"]', 'li', 'div', 'span']) => {
    for (const tag of tags) {
      const found = await page.evaluate((tag, text) => {
        const els = Array.from(document.querySelectorAll(tag))
          .filter(e => (e.innerText || '').trim().toLowerCase().includes(text.toLowerCase()));
        if (!els.length) return false;
        // Dropdown options are plain divs/spans, and so is every ancestor that
        // contains them — matching on text alone would click the page wrapper.
        // The smallest matching element is the option itself.
        els.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length);
        els[0].click();
        return true;
      }, tag, text);
      if (found) return true;
    }
    return false;
  };

  // The blueprint list is a long table whose search box is not reliably
  // reachable by selector, so scope the click to the row that names the
  // blueprint — a bare "Deploy" click just takes whichever row comes first.
  const clickInRow = async (rowText, btnText) => {
    return await page.evaluate((rowText, btnText) => {
      const rows = Array.from(document.querySelectorAll('tr, [role="row"], li'));
      const row = rows.find(r => (r.innerText || '').toLowerCase().includes(rowText.toLowerCase()));
      if (!row) return false;
      const btn = Array.from(row.querySelectorAll('button, a, [role="button"]'))
        .find(b => (b.innerText || '').trim().toLowerCase().includes(btnText.toLowerCase()));
      if (!btn) return false;
      btn.click();
      return true;
    }, rowText, btnText);
  };

  for (const s of steps) {
    if (s.path) {
      await page.goto(`${BASE}${s.path}`, { waitUntil: 'domcontentloaded', timeout: 45000 }).catch(() => {});
      await new Promise(r => setTimeout(r, s.waitMs || 3500));
    }
    if (s.clickInRow) {
      const ok = await clickInRow(s.clickInRow.row, s.clickInRow.button || 'Deploy');
      console.log(`    clickInRow "${s.clickInRow.row}" -> ${ok ? 'ok' : 'NOT FOUND'}`);
      await new Promise(r => setTimeout(r, s.afterClickMs || 3000));
    }
    for (const c of (s.click || [])) {
      const ok = await clickText(c);
      console.log(`    click "${c}" -> ${ok ? 'ok' : 'NOT FOUND'}`);
      await new Promise(r => setTimeout(r, s.afterClickMs || 2500));
    }
    // Keyboard sequence: type into the focused field, Tab between fields.
    for (const k of (s.keys || [])) {
      if (k.press) await page.keyboard.press(k.press);
      else if (k.type !== undefined) await page.keyboard.type(k.type, { delay: 25 });
      await new Promise(r => setTimeout(r, 250));
    }
    for (const [sel, val] of Object.entries(s.fill || {})) {
      await page.type(sel, val, { delay: 15 }).catch(() => console.log(`    fill ${sel} -> NOT FOUND`));
    }
    if (s.waitFor) await page.waitForSelector(s.waitFor, { timeout: 15000 }).catch(() => {});
    if (s.settleMs) await new Promise(r => setTimeout(r, s.settleMs));
    if (s.reportUrl) console.log('    url now: ' + page.url());
    await shot(s.name);
  }

  await browser.close();
})().catch(e => { console.error('  capture failed:', e.message); process.exit(1); });
