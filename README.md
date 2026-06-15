# roksbnkctl-bnk-forge

A BNK Forge **module source** that runs [roksbnkctl](https://github.com/jgruberf5/roksbnkctl)
from a BNK Forge blueprint: a form populates the workspace `config.yaml`, an IBM
Cloud **credential template** supplies the API key, and roksbnkctl provisions an
IBM Cloud ROKS cluster and installs BIG-IP Next for Kubernetes (BNK).

Register this repo once as a Git module source (`POST /api/module-sources`); the
sync ingests both the deployment pack and the blueprint.

## How it works

```
BNK Forge blueprint form ──▶ config.yaml (rendered) ──▶ roksbnkctl init/up
   (prefix, cluster_name,            │                        │
    region, resource_group,         │                        ▼
    openshift_version, …)           │                  IBM ROKS + BNK
                                    │
IBM credential template ──▶ IBMCLOUD_API_KEY (env) ─────┘   cluster-outputs.json
   (region, resource_group                                        │
    auto-inherited)                                               ▼
                                                            outputs.json → Forge
```

- **Form → `config.yaml`.** The blueprint's `inputs` render the deploy form. Their
  values flow into the pack via `${name}` interpolation on the module `inputs`,
  reach the playbook as Ansible `--extra-vars`, and the playbook renders
  `config.yaml` from `config.yaml.j2` and runs `roksbnkctl init --config-file …
  --override-from-env`. **No `config.yaml` is hand-edited.**
- **Credential template → API key.** Selecting an IBM credential template on the
  Forge project injects `IBMCLOUD_API_KEY` into the run environment
  (`credentials_service.get_cloud_credentials_env`). roksbnkctl consumes it
  natively (env-first resolver; `--override-from-env` maps it into the workspace).
  `region` and `resource_group` **auto-inherit** from the template via the form
  cascade (`source: credential_template`).
- **Outputs.** The playbook reads `cluster-outputs.json` and writes the manifest's
  `outputs_file` (`outputs.json`); Forge imports it as module outputs.

## Why one workspace pack (not per-phase packs)

roksbnkctl is **workspace-stateful across phases**: cluster → BNK → testing →
gateway share one `~/.roksbnkctl/<ws>` (config, terraform state,
`cluster-outputs.json`), and `roksbnkctl up` owns the phase ordering + the
BNK∥testing parallelism. BNK Forge modules are **independent runs with independent
workspaces**, so splitting the phases into separate packs would break roksbnkctl's
shared state. The robust unit is therefore **one pack that runs the whole
lifecycle**, with the form's `target` input choosing `cluster` vs `all`. (Finer
per-phase modules are possible later but require solving cross-run state sharing —
e.g. remote state + an existing-cluster handoff.)

## Layout

```
roksbnkctl/workspace/
  bnkforge.pack.json   # engine: ansible, runner_profile: ansible-default
  playbook.yml         # render config.yaml → roksbnkctl init → up → write outputs.json
  destroy.yml          # roksbnkctl down
  config.yaml.j2       # the config.yaml seed, fed by the form
forge-blueprint.json   # the form + module wiring (cloud_provider: ibm)
docs/backend-Dockerfile.snippet   # the runner-image addition (see Prerequisite)
```

`module.path` in the manifest (`roksbnkctl/workspace`) must equal the pack's
repo-relative directory — BNK Forge enforces this and resolves the blueprint's
`module:` ref by that path.

## Prerequisite: bake roksbnkctl into the runner image

The `ansible-default` worker image bundles `tofu`/`helm`/`kubectl` but **not
roksbnkctl**, and the governed runner contract forbids per-pack images / runtime
installs — so roksbnkctl must be **baked into the BNK Forge worker image**. Apply
`docs/backend-Dockerfile.snippet` to the worker stage of `backend/Dockerfile`
(next to the OpenTofu/kubectl install). Confirm `ansible-core` is present there
too (the ansible engine needs `ansible-playbook`).

This is the only BNK Forge code/image change required — everything else is pack
content synced from this repo.

## Caveats / things to verify

- **Runner timeout.** The ansible runner caps a run at **3600 s (1 h)**. A full
  ROKS create + BNK install can approach that; for slow regions, deploy in stages
  (`target: cluster` first, then a second run for the rest) or raise the runner
  timeout.
- **Destroy needs the state.** `destroy.yml` runs `roksbnkctl down`, which needs
  the terraform state from apply. State lives under `ROKSBNKCTL_HOME` (pinned into
  the module workspace). If Forge does **not** persist the module workspace between
  apply and destroy, configure **remote state** so it survives — `roksbnkctl state
  s3 …` writes a `state:` block that keeps terraform state in IBM COS. (You can add
  an `s3_*` set of form inputs + a `state:` block to `config.yaml.j2` to wire this
  from the blueprint.)
- **Non-interactive confirm flag.** Verify the exact `roksbnkctl down` flag for
  your release (the destroy playbook uses `--yes`); destroy must never prompt.
- **`roksbnkctl version`** — verify the version subcommand name for your release
  (the readiness check uses `roksbnkctl version`).
- **Plan semantics.** A Forge "plan" runs `ansible --check`, which we map to a
  read-only `roksbnkctl plan`. It does not promise OpenTofu-style change precision.

## Relationship to the auto-registration feature

This is **Approach 2** (Forge *drives* roksbnkctl). It is complementary to the
roksbnkctl `bnkforge register` feature (**Approach 1**, where roksbnkctl runs
*outside* Forge and registers the cluster back). When Forge drives roksbnkctl,
Forge already owns the cluster — no registration step is needed.
