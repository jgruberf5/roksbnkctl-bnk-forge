#!/usr/bin/env node
// Reset a Forge back to pre-demo state so the walkthrough can be re-recorded.
// Removes: the imported ROKS blueprint, the blueprint sources this repo created,
// the module source, and (with --creds) the demo credential template.
//
//   FORGE_PASSWORD=… npm run reset -- --url https://forge --user admin
//   … --dry                 report what it would delete
//   … --creds --cred-name ibm-demo
//
// Icon-only action buttons carry no aria-label; they're identified by their Lucide
// SVG class (e.g. svg.lucide-trash2). That's brittle by nature — --dry first.
import readline from 'node:readline/promises';
import puppeteer from 'puppeteer';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(`--${n}`);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const DRY = flag('dry');
const say = console.log;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SOURCE_NAME = opt('source-name', 'roksbnkctl-bnk-forge');
const CRED_NAME = opt('cred-name', 'ibm-demo');
const BP_TEXT = opt('blueprint', 'IBM ROKS + BNK');
const PROJECT_NAME = opt('project-name', 'roks-bnk-demo');

/**
 * Radix confirmations render as role="alertdialog" (NOT role="dialog"), stacked over the
 * dialog that triggered them. Some deletes instead use a native window.confirm, which the
 * page 'dialog' handler accepts.
 */
async function confirmDialog(page, words = ['Delete Source', 'Delete', 'Remove', 'Confirm', 'Yes']) {
  await sleep(1200);
  for (const w of words) {
    const h = await page.$(`[role=alertdialog] button::-p-text(${w})`);
    if (h) { await h.click(); await sleep(2200); return w; }
  }
  return null;
}

async function main() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const url = opt('url', process.env.FORGE_URL) || await rl.question('Forge URL: ');
  const user = opt('user', process.env.FORGE_USERNAME) || await rl.question('Username: ');
  const pass = process.env.FORGE_PASSWORD || await rl.question('Password: ');
  rl.close();
  const base = new URL(url).origin;

  const browser = await puppeteer.launch({
    headless: true, defaultViewport: null, acceptInsecureCerts: true,
    args: ['--no-sandbox', '--window-size=1920,1167', '--hide-scrollbars'],
  });
  const page = (await browser.pages())[0];
  page.setDefaultTimeout(25000);
  page.on('dialog', async (d) => { say(`  native dialog: ${d.message()}`); await d.accept(); });

  await page.goto(base, { waitUntil: 'networkidle2' });
  await page.waitForSelector('#username', { timeout: 30000 });
  await page.type('#username', user);
  await page.type('#password', pass);
  await (await page.$('button::-p-text(Sign In)')).click();
  await sleep(3500);
  say(`logged in -> ${page.url()}${DRY ? '   [DRY RUN]' : ''}`);

  // 0. project — optionally destroy its real IBM resources, then delete it.
  // Delete alone removes the project/config but NOT the cloud resources; pass --destroy
  // to run the project's "Destroy all" (roksbnkctl <phase> down) first.
  await page.goto(`${base}/projects`, { waitUntil: 'networkidle2' });
  await sleep(2500);
  const projHref = await page.evaluate((name) => {
    const a = [...document.querySelectorAll('a')].find((x) => x.innerText.includes(name));
    if (a) return a.getAttribute('href');
    const el = [...document.querySelectorAll('td,div,h3,span')].find((x) => x.innerText.trim() === name);
    return el ? '__click__' : null;
  }, PROJECT_NAME);
  say(`\nproject "${PROJECT_NAME}": ${projHref ? 'present' : 'not present'}${DRY && projHref ? ' (would delete)' : ''}`);
  if (projHref && !DRY) {
    if (projHref === '__click__') {
      const h = (await page.evaluateHandle((name) =>
        [...document.querySelectorAll('td,div,h3,span')].find((x) => x.innerText.trim() === name) || null,
        PROJECT_NAME)).asElement();
      await h.click();
    } else {
      await page.goto(base + projHref, { waitUntil: 'networkidle2' });
    }
    await page.waitForFunction(() => /\/projects\/[^/]+$/.test(location.pathname), { timeout: 20000 }).catch(() => {});
    await sleep(2000);

    const openMore = async () => {
      const more = await page.$('main button::-p-text(More)');
      if (!more) return false;
      await more.click(); await sleep(1200); return true;
    };

    if (flag('destroy') && await openMore()) {
      const d = await page.$('[role=menuitem]::-p-text(Destroy all)');
      if (d) {
        await d.click();
        say(`  Destroy all: confirm ${await confirmDialog(page, ['Destroy', 'Confirm', 'Yes'])}`);
        say('  waiting for teardown to finish…');
        await page.waitForFunction(
          () => /destroyed|removed|deleted|complete|no operations|idle/i.test(document.body.innerText) &&
                !/running|in progress|destroying/i.test(document.body.innerText),
          { timeout: 45 * 60 * 1000, polling: 15000 }).catch(() => say('  (teardown wait timed out — check manually)'));
      }
    }

    if (await openMore()) {
      const del = await page.$('[role=menuitem]::-p-text(Delete project)');
      if (del) {
        await del.click();
        say(`  deleted project: confirm ${await confirmDialog(page, ['Delete', 'Confirm'])}`);
      } else say('  no "Delete project" menu item');
    }
  }

  const openCatalogTab = async (tab) => {
    await page.goto(`${base}/catalog`, { waitUntil: 'networkidle2' });
    await sleep(2200);
    if (tab === 'Modules') {
      await page.evaluate(() => {
        const i = document.querySelector('main input.sr-only.peer');
        if (i && !i.checked) (i.closest('label') || i).click();   // 'Advanced' reveals Modules
      });
      await sleep(1500);
    }
    const t = await page.$(`main button::-p-text(${tab})`);
    if (t) { await t.click(); await sleep(1600); }
  };

  // 1. imported blueprint -> remove from deployable catalog
  await openCatalogTab('Blueprints');
  const bpBtns = await page.evaluate((txt) => {
    const r = [...document.querySelectorAll('tr')].find((x) => x.innerText.includes(txt));
    return r ? [...r.querySelectorAll('button')].map((b) => b.getAttribute('aria-label') || b.innerText.trim()) : null;
  }, BP_TEXT);
  say(`\nblueprint "${BP_TEXT}": ${bpBtns ? JSON.stringify(bpBtns) : 'not present'}`);
  if (bpBtns && bpBtns.some((b) => /remove from deployable/i.test(b)) && !DRY) {
    await page.evaluate((txt) => {
      const r = [...document.querySelectorAll('tr')].find((x) => x.innerText.includes(txt));
      [...r.querySelectorAll('button')].find((b) => /remove from deployable/i.test(b.getAttribute('aria-label') || ''))?.click();
    }, BP_TEXT);
    say(`  confirmed: ${await confirmDialog(page)}`);
  }

  // 2. blueprint sources (ours + the companion the module source auto-creates)
  await openCatalogTab('Blueprints');
  await (await page.$('main button::-p-text(Sources)'))?.click();
  await sleep(2000);
  for (let pass = 0; pass < 4; pass++) {
    const target = await page.evaluate((name) => {
      const d = [...document.querySelectorAll('[role=dialog]')].pop();
      if (!d) return null;
      const r = [...d.querySelectorAll('tr')].find((x) => x.innerText.includes(name) && !/builtin/i.test(x.innerText));
      if (!r) return null;
      const del = [...r.querySelectorAll('button')].find((b) => /delete source/i.test(b.getAttribute('aria-label') || ''));
      return del ? r.innerText.split('\n')[0].trim() : null;
    }, SOURCE_NAME);
    if (!target) break;
    say(`\nblueprint source: ${target}${DRY ? ' (would delete)' : ''}`);
    if (DRY) break;
    await page.evaluate((name) => {
      const d = [...document.querySelectorAll('[role=dialog]')].pop();
      const r = [...d.querySelectorAll('tr')].find((x) => x.innerText.includes(name) && !/builtin/i.test(x.innerText));
      [...r.querySelectorAll('button')].find((b) => /delete source/i.test(b.getAttribute('aria-label') || ''))?.click();
    }, SOURCE_NAME);
    say(`  confirmed: ${await confirmDialog(page)}`);
  }
  await page.keyboard.press('Escape'); await sleep(800);

  // 3. module source (icon-only trash button)
  await openCatalogTab('Modules');
  await (await page.$('main button::-p-text(Sources)'))?.click();
  await sleep(2000);
  const modPresent = await page.evaluate((name) => {
    const d = [...document.querySelectorAll('[role=dialog]')].pop();
    return !!d && [...d.querySelectorAll('tr')].some((x) => x.innerText.includes(name));
  }, SOURCE_NAME);
  say(`\nmodule source "${SOURCE_NAME}": ${modPresent ? 'present' : 'not present'}${DRY && modPresent ? ' (would delete)' : ''}`);
  if (modPresent && !DRY) {
    const r = await page.evaluate((name) => {
      const d = [...document.querySelectorAll('[role=dialog]')].pop();
      const row = [...d.querySelectorAll('tr')].find((x) => x.innerText.includes(name));
      const del = row.querySelector('button:has(svg.lucide-trash2)');
      if (!del) return 'no trash button';
      del.click(); return 'clicked';
    }, SOURCE_NAME);
    say(`  ${r}, confirmed: ${await confirmDialog(page)}`);
  }
  await page.keyboard.press('Escape'); await sleep(800);

  // 4. credential template (opt-in — the instance may hold templates you did not create)
  if (flag('creds')) {
    await page.goto(`${base}/auth-templates`, { waitUntil: 'networkidle2' });
    await sleep(2000);
    const has = await page.evaluate((n) => [...document.querySelectorAll('tr')].some((r) => r.innerText.includes(n)), CRED_NAME);
    say(`\ncredential template "${CRED_NAME}": ${has ? 'present' : 'not present'}${DRY && has ? ' (would delete)' : ''}`);
    if (has && !DRY) {
      // Radix dropdown menus only open on a trusted pointer event — an in-page
      // element.click() from page.evaluate() does nothing here.
      const handle = (await page.evaluateHandle((n) => {
        const r = [...document.querySelectorAll('tr')].find((x) => x.innerText.includes(n));
        return r?.querySelector('button[aria-label="Template actions"]') || null;
      }, CRED_NAME)).asElement();
      if (!handle) { say('  no actions button'); }
      else {
        await handle.click();
        await sleep(1400);
        const del = await page.$('[role=menuitem]::-p-text(Delete)');
        if (!del) say('  no Delete menu item');
        else {
          await del.click();           // this one confirms via native window.confirm
          await sleep(2000);
          say(`  deleted (confirm: ${(await confirmDialog(page)) ?? 'native'})`);
        }
      }
    }
  }

  await browser.close();
  say(`\n${DRY ? 'DRY RUN complete — nothing changed.' : 'Reset complete.'}`);
}

main().catch((e) => { console.error(`\nFAILED: ${e.message}`); process.exit(1); });
