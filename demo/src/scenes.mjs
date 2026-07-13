// The demo flow, one entry per narrated scene, calibrated against BNK Forge 3.1.6.
//
// kind: 'interactive' plays at 1x; 'wait' is recorded in real time and compressed 4x in
// post. A scene never runs shorter than its narration (postprod.planTimeline holds the
// last frame), so actions that finish early simply linger.
//
// Flow notes that differ from docs/USING-WITH-BNK-FORGE.md (that doc predates this build):
//   * Left nav has no "Modules" — modules live under Catalog, behind the "Advanced" switch.
//   * Registering the MODULE source auto-creates a companion blueprint source
//     ("<name> blueprints"), so there is no second source to add by hand.
//   * A synced blueprint lands in state "discovered" and must be IMPORTED before its
//     Deploy button enables. That is the "enable the blueprint" step.
//   * Deploy creates the project inline (project name + credential template + region),
//     so there is no separate Projects step.
import { sleep } from './ui.mjs';

export const BLUEPRINT_ROW = 'IBM ROKS + BNK';

/** Scenes dropped by --skip-deploy: everything from project creation onward. */
export const DEPLOY_SCENES = ['deploy_start', 'open_project', 'launch', 'wait_cluster', 'wait_bnk',
  'outputs', 'cluster_registered', 'k8s_scan', 'k8s_healthy'];

const DONE_RE = /succeed|success|complete|completed|deployed|ready|failed|error/i;
const FAIL_RE = /failed|error/i;

/**
 * Poll until the named phase reaches a terminal state. Soft by design: on timeout it
 * logs and returns so the recording still produces a video. Reads the phase's own table
 * row when one exists, else falls back to a page-wide scan.
 */
async function waitForPhase(ctx, phase, timeoutMs) {
  const { ui, log } = ctx;

  // Guard: if the deployment never actually started (e.g. Deploy submitted nothing),
  // don't sit in the long poll for over an hour. Give it 90s to show ANY activity.
  const started = await ui.until(`${phase}: deployment active`,
    async () => {
      const t = await ctx.page.evaluate(() => (document.querySelector('main') || document.body).innerText)
        .catch(() => '');
      return /running|pending|queued|in progress|provision|deploying|succeed|success|complete|failed|error/i.test(t);
    }, { timeout: 90000, interval: 5000 }).catch(() => false);
  if (!started) {
    log(`    [${phase}] no deployment activity after 90s — skipping the long wait`);
    return false;
  }

  const deadline = Date.now() + timeoutMs;
  const names = [`roksbnkctl-${phase}`, `roksbnkctl/${phase}`, `roksbnkctl ${phase}`];
  let last = '';

  while (Date.now() < deadline) {
    let text = null;
    for (const n of names) {
      text = await ui.rowText(n).catch(() => null);
      if (text) break;
    }
    if (!text) {
      text = await ctx.page.evaluate(() => (document.querySelector('main') || document.body).innerText)
        .then((t) => t.split('\n').filter((l) => /succeed|success|complete|failed|error|running|pending/i.test(l)).join(' | '))
        .catch(() => '');
    }
    if (text && text !== last) { log(`    [${phase}] ${text.slice(0, 160)}`); last = text; }
    if (text && DONE_RE.test(text)) {
      log(`    [${phase}] terminal${FAIL_RE.test(text) ? ' (FAILED)' : ''}`);
      return !FAIL_RE.test(text);
    }
    // A dependency failure leaves this phase stuck on "Pending" forever — don't wait out
    // the full timeout. If any module on the page has failed, abandon the wait.
    if (/pending/i.test(text || '')) {
      const anyFailed = await ctx.page.evaluate(() => /apply failed|failed/i.test(document.body.innerText)).catch(() => false);
      if (anyFailed) { log(`    [${phase}] a dependency failed — abandoning wait`); return false; }
    }
    await sleep(15000);
  }
  log(`    [${phase}] still not terminal after ${Math.round(timeoutMs / 60000)}m — continuing anyway`);
  return false;
}

export const SCENES = [
  {
    id: 'intro',
    kind: 'interactive',
    async run({ ui, A }) {
      // Wait for the app to actually render (login form or, if already authed, the nav).
      await ui.gotoApp(A.forgeUrl, ['login.username', 'nav.catalog']);
      await ui.clearHighlight();
    },
  },

  {
    id: 'login',
    kind: 'interactive',
    async run({ ui, A }) {
      // Already authenticated (SPA kept the session)? Skip straight past the form.
      if (!(await ui.exists('login.username', 4000)) && await ui.exists('nav.catalog', 2000)) {
        ui.log('    already authenticated');
        await ui.installCursor();
        return;
      }
      await ui.type('login.username', A.forgeUsername);
      await ui.type('login.password', A.forgePassword, { secret: true });
      await ui.click('login.submit');
      await ui.until('dashboard', () => ui.exists('nav.catalog', 3000), { timeout: 60000, interval: 1500 });
      await ui.installCursor();
    },
  },

  // ---- 1. IBM Cloud credential template -------------------------------------
  {
    id: 'cred_nav',
    kind: 'interactive',
    async run({ ui }) {
      await ui.nav('nav.accessMethods');
      await sleep(800);
    },
  },
  {
    id: 'cred_create',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.click('cred.add');
      await sleep(800);
      await ui.type('cred.name', A.credTemplateName);
      // Radix Select — the provider choice swaps the credential fields below it.
      await ui.selectOption('cred.provider', 'IBM Cloud');
      await sleep(800);
    },
  },
  {
    id: 'cred_secret',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.type('cred.apiKey', A.ibmApiKey, { secret: true });
      await ui.type('cred.region', A.region);
      await ui.type('cred.resourceGroup', A.resource_group);
    },
  },
  {
    id: 'cred_saved',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.click('cred.save');
      await ui.until('credential template listed', () => ui.pageHasText(A.credTemplateName),
        { timeout: 30000, interval: 1000 });
      await ui.installCursor();
    },
  },

  // ---- 2. Register this repo as a module source ------------------------------
  {
    id: 'catalog_nav',
    kind: 'interactive',
    async run({ ui }) {
      await ui.nav('nav.catalog');
      await sleep(1200);
      // "Advanced" reveals the Modules tab.
      await ui.setToggle('catalog.advancedToggle', true);
      await sleep(1200);
      await ui.click('catalog.tabModules');
      await sleep(800);
    },
  },
  {
    id: 'source_add',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.click('catalog.sourcesBtn');
      await sleep(1200);
      await ui.click('modsrc.add');
      await sleep(1000);
      await ui.type('modsrc.name', A.sourceName);
      await ui.type('modsrc.url', A.sourceUrl);
      await ui.type('modsrc.branch', A.sourceBranch);
      await ui.click('modsrc.submit');
    },
  },
  {
    id: 'source_sync',
    kind: 'wait',
    async run({ ui, rehearse, cfg, A }) {
      if (rehearse) { await sleep(cfg.rehearse.phaseWaitSec * 1000); return; }
      // Match on the git URL, not the name: the source *table* row is the only element
      // on the page containing the URL. The four discovered module rows share the
      // "roksbnkctl" name but show descriptions, not URLs — and they never say "success",
      // so a name match reads the wrong row and hangs. URL match is unambiguous and needs
      // no dialog scoping.
      await ui.until('module source synced',
        async () => /success/i.test((await ui.rowText(A.sourceUrl)) || ''),
        { timeout: cfg.timeouts.phaseMs, interval: 4000 });
    },
  },
  {
    id: 'source_synced',
    kind: 'interactive',
    async run({ ui, A }) {
      ui.log(`    module source row: ${await ui.rowText(A.sourceUrl)}`);
      await ui.highlightRow(A.sourceUrl);
      await sleep(1500);
      await ui.clearHighlight();
      await ui.click('modsrc.close');
      await sleep(800);
      await ui.installCursor();
    },
  },

  // ---- 3. Enable (import) the blueprint --------------------------------------
  {
    id: 'bp_discovered',
    kind: 'interactive',
    async run({ ui }) {
      await ui.click('catalog.tabBlueprints');
      await sleep(1500);
      await ui.until('blueprint discovered', () => ui.rowExists(BLUEPRINT_ROW),
        { timeout: 180000, interval: 4000 });
      await ui.highlightRow(BLUEPRINT_ROW);
      ui.log(`    ${await ui.rowText(BLUEPRINT_ROW)}`);
      await sleep(1500);
      await ui.clearHighlight();
    },
  },
  {
    id: 'bp_import',
    kind: 'interactive',
    async run({ ui }) {
      await ui.clickRowButton(BLUEPRINT_ROW, 'Import');
      await ui.confirmAlert(['Import', 'Confirm', 'Yes']);
      await ui.until('blueprint imported',
        async () => /imported/i.test((await ui.rowText(BLUEPRINT_ROW)) || ''),
        { timeout: 60000, interval: 2000 });
      await ui.highlightRow(BLUEPRINT_ROW);
      await sleep(1200);
      await ui.clearHighlight();
    },
  },

  // ---- 4. Deploy -------------------------------------------------------------
  {
    id: 'bp_open',
    kind: 'interactive',
    async run({ ui }) {
      await ui.clickRowButton(BLUEPRINT_ROW, 'Deploy');
      await sleep(2500);
    },
  },
  {
    id: 'form_project',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.type('deploy.projectName', A.projectName);
      await ui.selectOption('deploy.credentialTemplate', A.credTemplateName);
      await sleep(600);
      if (await ui.exists('deploy.ibmRegion', 2500)) await ui.type('deploy.ibmRegion', A.region);
    },
  },
  {
    id: 'form_fill',
    kind: 'interactive',
    async run({ ui, A }) {
      await ui.type('form.prefix', A.inputs.prefix);
      await ui.type('form.cluster_name', A.inputs.cluster_name);
      await ui.type('form.region', A.inputs.region || A.region);
      await ui.type('form.resource_group', A.inputs.resource_group || A.resource_group);
    },
  },
  {
    id: 'form_toggles',
    kind: 'interactive',
    async run({ ui, A }) {
      // This build renders blueprint booleans as free-text inputs, not switches,
      // so they are typed as "true"/"false" rather than toggled.
      const t = A.inputs;
      const bool = (v) => (v ? 'true' : 'false');
      await ui.type('form.cluster_create', bool(t.cluster_create));
      await ui.type('form.install_bnk', bool(t.install_bnk));
      await ui.type('form.install_testing', bool(t.install_testing));
      await ui.type('form.install_gateway', bool(t.install_gateway));
      for (const [k, sel] of [['openshift_version', 'form.openshift_version'],
                              ['workers_per_zone', 'form.workers_per_zone']]) {
        if (t[k] && await ui.exists(sel, 1500)) await ui.type(sel, t[k]);
      }
    },
  },
  {
    id: 'deploy_start',
    kind: 'interactive',
    async run({ ui, log }) {
      // "Deploy Blueprint" CREATES the project (4 modules, all Pending) — it does not
      // launch anything. The launch is a separate step on the project page.
      await ui.click('deploy.submit');
      await ui.confirmAlert(['Deploy', 'Confirm', 'Yes', 'Start']);
      await sleep(4000);
      log(`    project created; page: ${ui.page.url()}`);
    },
  },

  {
    id: 'open_project',
    kind: 'interactive',
    async run({ ui, A, log }) {
      await ui.nav('nav.projects');
      await sleep(1200);
      await ui.openProjectByName(A.projectName);
      await sleep(2000);
      log(`    project page: ${ui.page.url()}`);
      // Show the four phase modules pending + the dependency pipeline.
      if (await ui.exists('project.pipeline', 3000)) {
        await ui.highlight('project.pipeline');
        await sleep(1500);
        await ui.clearHighlight();
      }
    },
  },

  {
    id: 'launch',
    kind: 'interactive',
    async run({ ui }) {
      // Deploy all modules → the "Deploy All Modules" dialog → Start Deployment.
      await ui.click('project.deployAll');
      await sleep(1500);
      // The dialog defaults to the recommended Parallel plan; that's what we want.
      await ui.click('project.startDeployment');
      await sleep(3000);
    },
  },

  // ---- 5. The long waits (compressed 4x) -------------------------------------
  //
  // The post-deploy page is whatever the Forge navigates to; rather than hard-code a
  // status selector, poll for a terminal word near the phase name and NEVER throw. A
  // 45-minute recording must not be lost because a status badge moved.
  {
    id: 'wait_cluster',
    kind: 'wait',
    async run(ctx) {
      const { rehearse, cfg } = ctx;
      if (rehearse) { await sleep(cfg.rehearse.clusterWaitSec * 1000); return; }
      ctx.log('    waiting on cluster phase (30-45 minutes)…');
      await waitForPhase(ctx, 'cluster', cfg.timeouts.clusterDeployMs);
    },
  },
  {
    id: 'wait_bnk',
    kind: 'wait',
    async run(ctx) {
      const { rehearse, cfg, A } = ctx;
      if (!A.inputs.install_bnk) { await sleep(3000); return; }
      if (rehearse) { await sleep(cfg.rehearse.clusterWaitSec * 1000); return; }
      ctx.log('    waiting on bnk phase…');
      await waitForPhase(ctx, 'bnk', cfg.timeouts.clusterDeployMs);
    },
  },

  // ---- 6. Deployment complete: outputs, registered cluster, K8s scan ---------
  {
    id: 'outputs',
    kind: 'interactive',
    async run({ ui }) {
      // Show the project page with all phases succeeded + any outputs.
      if (await ui.exists('deploy.outputsTab', 4000)) await ui.click('deploy.outputsTab');
      if (await ui.exists('deploy.outputs', 4000)) {
        await ui.highlight('deploy.outputs');
        await sleep(1500);
        await ui.clearHighlight();
      } else {
        await sleep(1500);
      }
    },
  },
  {
    id: 'cluster_registered',
    kind: 'interactive',
    async run({ ui, log }) {
      // roksbnkctl registers the new cluster with the Forge. The Kubernetes page
      // auto-selects the (single) cluster and auto-scans it, so there's nothing to pick —
      // we just open the page and wait for the scan banner to render.
      await ui.nav('nav.kubernetes');
      await sleep(2000);
      await ui.until('cluster appears + scanned',
        () => ui.pageHasText('Cluster Ready') || ui.pageHasText('nodes ready') || ui.pageHasText('Scanned in'),
        { timeout: 90000, interval: 4000 });
      log(`    kubernetes page: ${await ui.page.evaluate(() => (document.querySelector('main')||document.body).innerText.split('\\n').find((l) => /Cluster Ready|nodes ready/i.test(l))?.trim() || '')}`);
      if (await ui.exists('k8s.clusterReady', 3000)) {
        await ui.highlight('k8s.clusterReady');
        await sleep(1800);
        await ui.clearHighlight();
      }
    },
  },
  {
    id: 'k8s_scan',
    kind: 'wait',
    async run(ctx) {
      const { ui, rehearse, cfg, log } = ctx;
      // Re-run the auto-detect scan on camera (the refresh-cw button), then wait for the
      // cluster to report healthy. It's usually already scanned, so this is quick.
      if (await ui.exists('k8s.rescan', 4000)) await ui.click('k8s.rescan');
      if (rehearse) { await sleep(cfg.rehearse.phaseWaitSec * 1000); return; }
      log('    waiting on Kubernetes scan to report healthy…');
      await ui.until('kubernetes scanned healthy',
        async () => {
          const t = await ctx.page.evaluate(() => (document.querySelector('main') || document.body).innerText).catch(() => '');
          return /Cluster Ready/i.test(t) && (/\d+\/\d+ nodes ready/i.test(t) || /BNK installed/i.test(t));
        },
        { timeout: cfg.timeouts.phaseMs, interval: 4000 });
    },
  },
  {
    id: 'k8s_healthy',
    kind: 'interactive',
    async run({ ui }) {
      // Rest on the healthy, scanned dashboard (Cluster Ready · nodes ready · BNK installed).
      if (await ui.exists('k8s.clusterReady', 3000)) {
        await ui.highlight('k8s.clusterReady');
        await sleep(2200);
        await ui.clearHighlight();
      } else {
        await sleep(1800);
      }
    },
  },
  {
    id: 'outro',
    kind: 'interactive',
    async run({ ui, skipDeploy }) {
      await ui.clearHighlight();
      if (skipDeploy) {
        // Leave the form on screen rather than submitting a real cluster build.
        const cancel = await ui.page.$('[role=dialog] button::-p-text(Cancel)');
        if (cancel) await cancel.click();
        await sleep(800);
      }
      await sleep(1200);
    },
  },
];
