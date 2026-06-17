# DEPLOY-ENGINE-EXT-007 — Governed Pipeline Engine and CI-Style Deployment Runner

> Status: **Proposed** (draft for the BNK Forge team). Depends on the Tool Store
> component type (DEPLOY-ENGINE-EXT-008, below) for binary provisioning.

## Objective

Add a `pipeline` deployment-pack engine whose governed runner executes a declared
**sequence of tool steps** — a CI-style deployment runner — instead of wrapping a
binary CLI inside an Ansible playbook. This is the native home for the growing
family of binary `ctl` tools (roksbnkctl and siblings): a pack declares the tools
it needs and the steps to run, the platform provisions verified binaries onto
`PATH` from the Tool Store, injects credentials as environment, runs each step as
an argv (no shell), and normalizes a structured outputs artifact.

## Decision summary

### Adopt

1. **New engine `pipeline`** added as one `EngineSpec` row in `engine_registry.py`,
   exactly as `ansible` was added (EXT-005). Governed runner profile
   `pipeline-default`.
2. **Steps are tool invocations, not shell.** A step is either a built-in governed
   action or `{run: <tool>, args: [...]}` where `<tool>` MUST be a tool declared in
   the pack's `tools[]` and resolved+verified by the Tool Store. Args are an argv
   array (no shell, no metacharacter interpretation), templated only from typed
   inputs and prior-step outputs.
3. **Binaries come only from the Tool Store** (EXT-008) — never from pack-declared
   URLs, images, or install steps. The runner stages verified, cached binaries
   into a per-run `bin/` and prepends it to the step `PATH`.
4. **Truthful lifecycle.** `init`/`plan`/`apply`/`destroy` map to named step-sets;
   `apply` required; `destroy` requires a `destroy` step-set. No fake OpenTofu-style
   parity.
5. **Reuse the existing execution spine** — Celery task lifecycle, deployment
   records, task logs, `credentials_env` injection, structured-outputs artifact —
   the same contract the Ansible engine uses.

### Explicitly NOT a generic script runner

EXT-005 chose Ansible over "a generic script runner" to avoid opening arbitrary
CLI execution. This engine is **not** that, and the distinction is the whole
security argument:

| Generic script runner (rejected) | Governed pipeline runner (this spec) |
|---|---|
| runs any command / `sh -c` | runs only tools declared in `tools[]`, resolved from the Tool Store |
| arbitrary binaries from anywhere | binaries verified (sha256/sig) from admin-allowlisted hosts |
| shell string, metacharacters | argv array, no shell, no interpolation into a shell |
| free-form args | args templated from **typed inputs** + prior-step outputs only |
| unbounded | bounded workspace, per-step + per-run timeout, secret redaction |

The set of runnable commands equals the **resolved, admin-approvable tool
dependency set** — a pinned allowlist, not a shell.

## Relationship to other specs

- **EXT-003** (`bnkforge.pack.json` manifest) — extended with `engine: pipeline`,
  a `tools[]` block, and a `steps` block. Same manifest file + validator.
- **EXT-005** (governed Ansible runner) — this engine is additive and mirrors its
  patterns (workspace confinement, outputs artifact, secret redaction, the
  `_DISALLOWED_*` denylist idea). Ansible packs are unaffected.
- **EXT-008 — Tool Store / binary-release component type** (companion spec):
  defines `bnkforge.tool.json`, the governed fetch→verify→cache pipeline, the
  source-host allowlist, and the cache volume. **This engine depends on it** — the
  pipeline runner resolves `run:` targets against Tool-Store-provisioned binaries.
  Ship EXT-008 first or together.

## Engine integration model

- Add to `_ENGINES` in `services/engine_registry.py`:
  ```
  EngineSpec(name="pipeline", pack_engine="pipeline",
             execution_engine="pipeline", legacy_engine_type=None,
             runner_profiles=("pipeline-default",), router_priority=<n>)
  ```
  All five derived views (valid pack engines, runner-profile map, pack→execution,
  router priority) pick it up from that one row.
- Implement `services/execution/pipeline_engine.py` + `pipeline_runner.py`
  conforming to the existing `DeploymentEngine` / `ModuleContext` interface
  (reuse `module_id`, `project_id`, `path`, `variables`, `credentials_env`,
  `workspace_path`).
- Wire engine-aware dispatch in `engine_router.py` / `task_dispatch.py`, adding
  pipeline task functions that mirror the k8s/opentofu/ansible signatures.

## Manifest contract (`deployment_pack.engine = "pipeline"`)

```json
{
  "schema_version": 1,
  "module": { "name": "...", "path": "...", "version": "...", "category": "bnk",
              "description": "...", "provider": "ibm", "supported_platforms": ["ocp"] },
  "deployment_pack": {
    "engine": "pipeline",
    "runner_profile": "pipeline-default",
    "working_directory": ".",
    "tools": [
      { "name": "roksbnkctl", "version": "1.11.4" },
      { "name": "terraform",  "version": "1.5.7" }
    ],
    "steps": {
      "apply": [
        { "name": "render config", "uses": "template",
          "with": { "src": "config.yaml.j2", "dest": "seed-config.yaml" } },
        { "name": "init", "run": "roksbnkctl",
          "args": ["init", "-w", "{{ inputs.workspace }}",
                   "--config-file", "seed-config.yaml", "--override-from-env"] },
        { "name": "cluster up", "run": "roksbnkctl",
          "args": ["-w", "{{ inputs.workspace }}", "cluster", "up", "--auto"],
          "when": "{{ inputs.cluster_create }}" },
        { "name": "cluster register", "run": "roksbnkctl",
          "args": ["-w", "{{ inputs.workspace }}", "cluster", "register", "{{ inputs.cluster_name }}"],
          "when": "{{ not inputs.cluster_create }}" },
        { "name": "bnk up", "run": "roksbnkctl",
          "args": ["-w", "{{ inputs.workspace }}", "bnk", "up", "--auto"],
          "when": "{{ inputs.install_bnk }}" },
        { "name": "collect outputs", "uses": "write_outputs",
          "with": { "from_file": ".roksbnkctl-home/{{ inputs.workspace }}/cluster-outputs.json",
                    "map": { "cluster_id": "cluster_id", "region": "region" } } }
      ],
      "destroy": [ { "name": "down", "run": "roksbnkctl",
                     "args": ["-w", "{{ inputs.workspace }}", "down", "--auto"] } ],
      "plan":    [ { "name": "plan", "run": "roksbnkctl",
                     "args": ["-w", "{{ inputs.workspace }}", "plan"] } ]
    },
    "lifecycle": { "supports_init": true, "supports_plan": true, "supports_apply": true,
                   "supports_destroy": true, "supports_refresh": false, "supports_drift": false },
    "outputs_file": "outputs.json"
  },
  "inputs":  { "required": [], "optional": [] },
  "outputs": { "key_outputs": [] },
  "credentials": { "required": [ { "name": "ibmcloud", "type": "cloud", "description": "..." } ] }
}
```

### Validator rules (extend `module_metadata.py`)

- `deployment_pack.engine = "pipeline"` ⇒ `runner_profile = "pipeline-default"`.
- `tools[]`: each `{name, version}`; every `name` must resolve to a Tool-Store tool
  component at sync/validation time (reject unknown tools).
- `steps` is a map of step-set name → list. Recognized sets: `init|plan|apply|destroy`.
  `apply` is required and non-empty. `supports_destroy=true` ⇒ non-empty `destroy`.
- Each step:
  - **exactly one of** `run` (a tool name that MUST be in `tools[]`) **or** `uses`
    (a built-in action: `template | write_outputs | read_outputs`).
  - `args` (for `run`): a JSON array of strings. **Reject** any element containing
    shell metacharacters or a step whose `run` is `sh`/`bash`/`/bin/*` or any name
    not in `tools[]`. No `command`/`shell`/`script` keys (denylist, mirroring
    `_DISALLOWED_DEPLOYMENT_PACK_KEYS`).
  - optional `when` (a boolean expression over typed inputs) and `name`.
- Reuse the EXT-003 `inputs`/`outputs`/`credentials` sections and secret-safety check.

## The CI-style deployment runner (`pipeline-default`)

Responsibilities, per step-set invocation:

1. **Materialize** the pack into a confined workspace (reuse the
   `resolve_workspace_subpath` boundary guard from `ansible_runner`).
2. **Provision tools.** Resolve `tools[]` → Tool Store `ensure(name, version, os,
   arch)` → symlink/copy the verified, cached binaries into a per-run `bin/` and
   **prepend it to the step `PATH`**. (Platform-owned, pre-verified — not a
   pack-declared install.)
3. **Inject credentials.** Merge `ctx.credentials_env` (e.g. `IBMCLOUD_API_KEY`)
   into the step environment; never log secret values (reuse the redaction pass).
4. **Run steps in order.** For each `run` step, execute `subprocess.run([tool,
   *args], cwd=workspace, env=…, timeout=…)` — **argv, never a shell string.**
   Render `args`/`when` from typed inputs + prior-step outputs via a bounded
   templater (no arbitrary eval). Stream stdout/stderr to task logs (redacted).
   Non-zero exit ⇒ fail the run (and the deployment record). Enforce per-step and
   per-run timeouts (default the per-run cap higher than Ansible's 3600 s for slow
   infra creates — make it a runner-profile constant, not pack-settable).
5. **Built-in actions** (`uses`): `template` (Jinja render a file from typed inputs),
   `read_outputs`/`write_outputs` (read a tool's JSON file, map keys into the
   outputs artifact). These cover the glue so packs never need shell.
6. **Outputs.** Write/return the `outputs_file` JSON object; normalize into module
   outputs (same contract as the Ansible engine: present+parse ⇒ imported,
   missing+declared ⇒ partial/unavailable).

Bounds (governed-runner contract):
- No raw shell, no inline scripts, no pack-supplied binaries/URLs/images, no
  pack-declared package installs, no arbitrary pre/post hooks.
- Only declared, Tool-Store-verified tools are on `PATH`.
- Per-step + per-run timeout; secret-safe logging; workspace-confined paths.

## Lifecycle capability model

- **init** — optional; validate workspace + that all `tools[]` resolved (Tool Store
  presence). Cheap.
- **plan** — supported only if the pack declares a `plan` step-set (e.g. `roksbnkctl
  plan`); read-only. Do not promise resource-diff precision.
- **apply** — required; runs the `apply` step-set.
- **destroy** — supported only when a `destroy` step-set is declared.
- **refresh/drift** — off unless a real, truthful mapping exists.

## State / workspace model

Many `ctl` tools are **stateful** (roksbnkctl keeps Terraform state +
`cluster-outputs.json` under `ROKSBNKCTL_HOME`). The runner must either persist the
module workspace between `apply` and `destroy`, or the pack must point the tool at
remote state. Recommend: support a persistent per-module workspace (preferred),
and document remote state (e.g. roksbnkctl `state s3`) as the durable-destroy
fallback when workspaces are ephemeral. Set tool home dirs to a workspace-relative
path via a `template`/env step.

## Dispatch / routing

Prefer explicit `library_module.execution_engine = "pipeline"` for dispatch (same
engine-type-aware routing EXT-005 introduced); fall back to `engine_type` for
legacy rows. Pipeline tasks run on the worker queue alongside ansible/opentofu.

## Non-goals

- No raw shell, inline scripts, or shell step type.
- No pack-supplied container images, binary URLs, or package installs (tools come
  only via the Tool Store, EXT-008).
- No arbitrary network egress declared by the pack.
- Not a replacement for the Ansible engine — additive. The base language runtime
  and the engine itself (e.g. the Python/worker image) stay image-baked; the Tool
  Store provisions *invoked* CLIs, not the runtime that runs them.

## Phased delivery

1. **EXT-008 Tool Store** (dependency): `bnkforge.tool.json` component kind +
   fetch/verify/cache + source-host allowlist + cache volume.
2. **`pipeline` EngineSpec row + manifest validator** (engine/tools/steps rules).
3. **`pipeline_runner`**: tool PATH provisioning, argv execution, credential env,
   timeouts, secret-safe logs, outputs normalization; Celery dispatch + deployment
   records.
4. **Built-in actions** (`template`, `read_outputs`, `write_outputs`) + `when`/arg
   templating over typed inputs.
5. **Migrate the roksbnkctl module-source pack** from `engine: ansible` to
   `engine: pipeline` (steps become direct `roksbnkctl` invocations; drop the
   playbook wrapper).

## Acceptance criteria

1. A pipeline pack declaring `tools: [roksbnkctl, terraform]` runs its steps with
   both binaries on `PATH`, sourced from the verified Tool-Store cache — **zero
   per-run download** on subsequent runs.
2. A step whose `run` names a tool not in `tools[]`, or `sh`/`bash`/a path, or
   whose `args` contain shell metacharacters, is **rejected at validation**.
3. `credentials_env` (e.g. `IBMCLOUD_API_KEY`) is present to steps and **redacted**
   in logs.
4. A non-zero step exit fails the run and the deployment record; the `outputs_file`
   JSON is normalized into module outputs.
5. `destroy` step-set tears down; `supports_destroy: true` without a `destroy`
   step-set fails validation.
6. Air-gapped (pre-seeded Tool-Store cache): a pipeline run succeeds with no egress.

## Worked example

The `roksbnkctl/workspace` pack in this repo, re-expressed with `engine: pipeline`:
the Ansible playbook is replaced by the `steps` block above — `roksbnkctl init`,
`cluster up`/`register`, `bnk up`, `testing up`, `gateway up` become governed steps
gated by the same typed form inputs (`cluster_create`, `install_bnk`,
`testing_vpc`, `existing_transit_gateway`, …). No `ansible-core` on the worker, no
playbook indirection — the platform runs the `ctl` directly, with the binary
provisioned and verified by the Tool Store.

---

### Implementation note for the BNK Forge session

Verify these seams before building (don't trust this draft blindly):
`services/engine_registry.py` (`_ENGINES`, derived views), `services/module_metadata.py`
(pack validator + a `_DISALLOWED_*` denylist to mirror),
`services/execution/{engine_interface,engine_router,ansible_runner,ansible_engine}.py`
(the contract to conform to + the redaction/outputs/workspace helpers to reuse),
`services/execution/task_dispatch.py`, `models/module.py` (`execution_engine`,
`engine_type`), and the Tool Store from EXT-008. Land EXT-008 first.
