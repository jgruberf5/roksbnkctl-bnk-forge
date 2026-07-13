// Interactive prompts for the demo runner.
//
// Repeatability: every non-secret answer is written to answers.json and can be replayed
// with `--answers answers.json`. Secrets (password, IBM API key) are NEVER written to
// disk; they come from the environment (FORGE_PASSWORD, IBMCLOUD_API_KEY) or are typed
// at run time.
import readline from 'node:readline';
import fs from 'node:fs';

const SECRET_ENV = {
  forgePassword: 'FORGE_PASSWORD',
  ibmApiKey: 'IBMCLOUD_API_KEY',
  bigip_password: 'BIGIP_PASSWORD',
};

function ask(question, { secret = false } = {}) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  return new Promise((resolve) => {
    if (!secret) {
      rl.question(question, (a) => { rl.close(); resolve(a); });
      return;
    }
    // Hidden input: swallow echo while still letting readline handle the line.
    const onKeypress = () => {
      readline.clearLine(process.stdout, 0);
      readline.cursorTo(process.stdout, 0);
      process.stdout.write(question);
    };
    process.stdout.write(question);
    rl.input.on('data', onKeypress);
    rl.question('', (a) => {
      rl.input.off('data', onKeypress);
      rl.close();
      process.stdout.write('\n');
      resolve(a);
    });
  });
}

async function askDefault(label, def, opts = {}) {
  const hint = def !== undefined && def !== '' ? ` [${def}]` : def === '' ? ' [blank]' : '';
  const a = (await ask(`  ${label}${hint}: `, opts)).trim();
  return a === '' ? def : a;
}

async function askBool(label, def) {
  const hint = def ? 'Y/n' : 'y/N';
  const a = (await ask(`  ${label} (${hint}): `)).trim().toLowerCase();
  if (a === '') return def;
  return a.startsWith('y');
}

async function askSecret(label, key) {
  const env = process.env[SECRET_ENV[key]];
  if (env) {
    console.log(`  ${label}: (from $${SECRET_ENV[key]})`);
    return env;
  }
  let v = '';
  while (!v) {
    v = (await ask(`  ${label}: `, { secret: true })).trim();
    if (!v) console.log('    required.');
  }
  return v;
}

/** Optional blueprint inputs we surface by default; the rest stay at their blueprint defaults. */
const DEFAULT_OPTIONAL = [
  'cluster_create', 'openshift_version', 'workers_per_zone',
  'install_bnk', 'install_testing', 'install_gateway',
];

/**
 * Build the question set from the blueprint itself, so the demo tracks the real form.
 * Inputs with `source: credential_template` are inherited in the UI and not prompted.
 */
export async function collectAnswers({ blueprint, answersFile, allOptional = false, reuse = null }) {
  const saved = reuse ?? (answersFile && fs.existsSync(answersFile)
    ? JSON.parse(fs.readFileSync(answersFile, 'utf8'))
    : {});

  const A = { ...saved };
  const wasReused = Object.keys(saved).length > 0;
  if (wasReused) console.log(`\nReplaying answers from ${answersFile} (press Enter to keep each value).\n`);

  console.log('BNK Forge instance');
  A.forgeUrl = await askDefault('Forge URL (e.g. https://forge.example.com)', A.forgeUrl);
  A.forgeUsername = await askDefault('Username', A.forgeUsername || 'admin');
  A.forgePassword = await askSecret('Password', 'forgePassword');

  console.log('\nIBM Cloud credential template');
  A.credTemplateName = await askDefault('Credential template name', A.credTemplateName || 'ibm-demo');
  A.ibmApiKey = await askSecret('IBM Cloud API key', 'ibmApiKey');
  A.region = await askDefault('IBM Cloud region', A.region || 'eu-de');
  A.resource_group = await askDefault('Resource group', A.resource_group || 'default');

  console.log('\nSource repository');
  A.sourceName = await askDefault('Source name', A.sourceName || 'roksbnkctl-bnk-forge');
  A.sourceUrl = await askDefault('Git URL', A.sourceUrl || 'https://github.com/jgruberf5/roksbnkctl-bnk-forge.git');
  A.sourceBranch = await askDefault('Branch', A.sourceBranch || 'main');

  console.log('\nProject');
  A.projectName = await askDefault('Project name', A.projectName || 'roks-bnk-demo');

  console.log('\nBlueprint form');
  A.inputs = { ...(A.inputs || {}) };
  const required = blueprint.inputs?.required ?? [];
  const optional = blueprint.inputs?.optional ?? [];

  for (const inp of required) {
    if (inp.source === 'credential_template') {
      // Inherited from the credential template in the UI; mirror what we already asked.
      A.inputs[inp.name] = A[inp.name] ?? A.inputs[inp.name] ?? '';
      console.log(`  ${inp.label}: (inherits from credential template -> ${A.inputs[inp.name]})`);
      continue;
    }
    A.inputs[inp.name] = await askDefault(inp.label, A.inputs[inp.name] ?? inp.example ?? '');
  }

  const show = allOptional ? optional : optional.filter((o) => DEFAULT_OPTIONAL.includes(o.name));
  for (const inp of show) {
    const prev = A.inputs[inp.name];
    if (inp.type === 'boolean') {
      A.inputs[inp.name] = await askBool(inp.label, prev ?? inp.default ?? false);
    } else {
      const v = await askDefault(inp.label, prev ?? inp.default ?? '', { secret: !!inp.sensitive });
      if (inp.sensitive && v) A.__secretInputs = { ...(A.__secretInputs || {}), [inp.name]: v };
      A.inputs[inp.name] = v;
    }
  }

  if (answersFile) saveAnswers(answersFile, A);
  return A;
}

/** Persist everything except secrets. */
export function saveAnswers(file, A) {
  const clone = JSON.parse(JSON.stringify(A));
  delete clone.forgePassword;
  delete clone.ibmApiKey;
  delete clone.__secretInputs;
  for (const k of Object.keys(clone.inputs || {})) {
    if (k === 'bigip_password') delete clone.inputs[k];
  }
  fs.writeFileSync(file, JSON.stringify(clone, null, 2) + '\n');
  console.log(`\nAnswers saved to ${file} (secrets excluded).`);
}
