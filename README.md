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

## What the form controls

| Field | Effect |
|---|---|
| `cluster_create` | **On** → provision a new ROKS cluster (`cluster up`). **Off** → attach to the existing cluster named in `cluster_name` (`cluster register`). |
| `cluster_name` | New cluster name, or the name/ID of the existing cluster to attach to. |
| `region`, `resource_group` | Inherit from the selected IBM credential template (overridable). |
| `openshift_version`, `workers_per_zone` | New-cluster sizing (ignored for an existing cluster). |
| `install_bnk` | Install BIG-IP Next for Kubernetes (`bnk up`). |
| `testing_vpc` | Testing phase — external client VPC + Transit Gateway jumphost. |
| `existing_transit_gateway` | Adopt an existing Transit Gateway by name/ID (`resources.transit_gateway.existing`) instead of creating one. Required to use `testing_vpc` against an existing cluster; also lets a new cluster adopt a shared corporate TGW. |
| `testing_in_cluster` | Testing phase — in-cluster per-AZ jumphosts. |
| `install_gateway` | Deploy the gateway phase (`gateway up`). |

Booleans render the matching `resources.*` toggles into `config.yaml` and gate the
corresponding `roksbnkctl <phase> up --auto` task. Cluster-phase infra
(`transit_gateway` / `registry_cos` / `cert_manager`) is created with a **new**
cluster (matching `roksbnkctl init` defaults) and assumed already present for an
**existing** one. Teardown runs the phases in reverse; an adopted existing cluster
is never destroyed.

## Why one workspace pack (not per-phase packs)

roksbnkctl is **workspace-stateful across phases**: cluster → BNK → testing →
gateway share one `~/.roksbnkctl/<ws>` (config, terraform state,
`cluster-outputs.json`). BNK Forge modules are **independent runs with independent
workspaces**, so splitting the phases into separate packs would break roksbnkctl's
shared state. The robust unit is therefore **one pack** that runs the selected
phases in one workspace, with the form's booleans choosing which phases run.
(Finer per-phase modules are possible later but require solving cross-run state
sharing — e.g. remote state + an existing-cluster handoff.)

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
  (a first run with only the cluster — `install_bnk`/testing/gateway off — then a
  second run enabling the rest) or raise the runner timeout.
- **Existing-cluster infra.** Attaching to an existing cluster (`cluster_create`
  off) skips creating `transit_gateway`/`registry_cos`/`cert_manager` (they're
  assumed present). To run `testing_vpc` against an existing cluster, set
  `existing_transit_gateway` to the cluster's Transit Gateway name/ID — the
  template renders `resources.transit_gateway.{create: false, existing: …}` so the
  testing phase finds it. (`registry_cos` adoption for an existing cluster is via
  `cluster register --registry-cos-name`; see the playbook comment.)
- **Destroy needs the state.** `destroy.yml` runs `roksbnkctl <phase> down`, which
  needs the terraform state from apply. State lives under `ROKSBNKCTL_HOME` (pinned into
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
