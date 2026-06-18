# roksbnkctl-bnk-forge

A [BNK Forge](https://github.com/jgruberf5) **module source** that runs
[roksbnkctl](https://github.com/jgruberf5/roksbnkctl) from a blueprint to
provision an IBM Cloud ROKS cluster and install BIG-IP Next for Kubernetes (BNK).

It ships **one BNK Forge artifact component per roksbnkctl phase**
(`roksbnkctl-cluster`, `roksbnkctl-bnk`, `roksbnkctl-testing`, `roksbnkctl-gateway`
— each `kind: container_image` wrapping the published `roksbnkctl-tools-runner`
image), plus a **blueprint** that composes them as a **dependency graph**
(`cluster → bnk → testing / gateway`). BNK Forge's **container engine** runs each
phase as a governed container step (argv only, no shell) on either a **Docker** or
**Kubernetes** substrate. Because the phases are separate modules, **each phase can
be deployed / re-run independently**, while a **deployment-scoped shared workspace**
(`state.scope: deployment`) keeps roksbnkctl's single `/work` state (tfstate,
generated keys, `cluster-outputs.json`) shared across them — so `bnk` sees the
cluster `cluster` created.

## How it works

```
Blueprint form ──▶ step env (ROKSBNKCTL_*)  ─┐
  prefix, cluster_name, region,             │   roksbnkctl-tools-runner image
  resource_group, cluster_create, …         ▼   (container step, argv only)
IBM credential template ──▶ IBMCLOUD_API_KEY ──▶ init --non-interactive
                                                 → cluster up --auto
                                                 → bnk up --auto  (…testing/gateway)
persistent /work volume  ◀── state (tfstate, keys, cluster-outputs.json) ──▶ outputs
```

- **Form → env → `config.yaml`.** Blueprint `inputs` render the deploy form and
  are wired to every phase module. Each phase artifact's `apply` step-set begins
  with an idempotent `init` step that maps the inputs to `ROKSBNKCTL_*` env vars
  and runs `roksbnkctl init --non-interactive` (builds `config.yaml` from the
  environment alone — roksbnkctl ≥ the `--non-interactive` release), then runs
  that phase's `cluster up` / `bnk up` / `testing up` / `gateway up`, gated by a
  typed input. Re-running a phase re-inits (idempotent) and re-converges.
- **Phases are separate modules over one shared workspace.** `cluster`, `bnk`,
  `testing`, `gateway` are distinct artifacts wired by the blueprint's
  `depends_on` graph; `state.scope: deployment` makes them share one roksbnkctl
  `/work`, so each phase sees the others' state. Whole-deployment teardown lives
  on the `cluster` phase's `destroy` (`roksbnkctl down`); the other phases'
  destroy is a no-op.
- **Credential template → API key.** Selecting an IBM credential template on the
  Forge project injects `IBMCLOUD_API_KEY` into the run; `region` and
  `resource_group` auto-inherit from the template via the form cascade.
- **State persists** on the mounted `/work` volume (`ROKSBNKCTL_HOME=/work/.roksbnkctl`),
  keyed to the deployment — so `destroy` tears down what `apply` created.
- **Outputs**: `cluster-outputs.json` is read back as the artifact's outputs.

## The form

| Field | Effect |
|---|---|
| `prefix` | Resource name prefix (e.g. `acme-eu`). |
| `cluster_name` | New cluster name, or existing cluster name/ID. |
| `region`, `resource_group` | Inherit from the selected IBM credential template. |
| `cluster_create` | On = provision a new ROKS cluster; Off = attach to the existing `cluster_name` (`cluster up` does both). |
| `install_bnk` | Install BIG-IP Next for Kubernetes. |
| `install_testing` | Deploy the testing phase. |
| `install_gateway` | Deploy the gateway phase. |

**Advanced (all optional):**

| Field | Effect |
|---|---|
| `existing_transit_gateway` | Adopt an existing Transit Gateway by name/ID (the new cluster + testing VPC attach to it) instead of creating one. |
| `testing_vpc_name` | Name the testing client VPC to create (testing phase). |
| `bigip_url` / `bigip_username` / `bigip_password` | BIG-IP target + credentials for the BNK **CIS** controller. |
| `zone<n>_int_vip_cidr` / `zone<n>_int_snat_cidr` / `zone<n>_ext_vlan_cidr` / `zone<n>_int_vlan_cidr` / `zone<n>_external_selfip` / `zone<n>_internal_selfip` (n = 1–3) | Per-AZ TMM network mapping — **listener (VIP)** and **SNAT** CIDRs + VLAN CIDRs + self-IPs for the BNK phase. Fill all six fields of a zone for it to apply. |

## Requirements

- A **BNK Forge** with the container-engine + Container Registries features
  (the artifact-component model).
- A **Container Registry** Access Method for `ghcr.io` (the runner image is public,
  but BNK Forge resolves a registry per image host) and an **IBM Cloud credential
  template** on the project.
- The `roksbnkctl-tools-runner` image pinned (by digest) in each phase artifact
  (`roksbnkctl/<phase>/bnkforge.artifact.json`) must be a build that includes
  `init --non-interactive` (roksbnkctl ≥ that release). All phases pin the same image.
- A BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`) — required so the phase modules share roksbnkctl's
  `/work` state.

## Using it

BNK Forge ingests **modules** and **blueprints** from *separate* source types, so
this repo must be registered as **both** — and the module source first, so the
module exists in the catalog when the blueprint deploys (otherwise project
creation fails with `BLUEPRINT_MODULES_MISSING`):

1. Register this repo as a Git **module source**. The module sync discovers the
   four per-phase `container`-engine packs — `roksbnkctl/{cluster,bnk,testing,gateway}/bnkforge.pack.json`
   — and registers a module for each, backed by the sibling `bnkforge.artifact.json`
   the container engine runs at deploy.
2. Register this repo as a Git **blueprint source**. The blueprint sync discovers
   [`forge-blueprint.json`](forge-blueprint.json) and imports the **IBM ROKS + BNK
   (roksbnkctl)** blueprint, which composes the four phase modules via a
   `depends_on` graph (`cluster → bnk → testing / gateway`).
3. On a project with an IBM credential template selected, deploy the blueprint and
   fill the form.

A step-by-step UI walkthrough lives in [`docs/USING-WITH-BNK-FORGE.md`](docs/USING-WITH-BNK-FORGE.md).

## Layout

```
roksbnkctl/cluster/   bnkforge.pack.json + bnkforge.artifact.json   # phase 1: ROKS cluster (provision/attach) — owns destroy (roksbnkctl down)
roksbnkctl/bnk/       bnkforge.pack.json + bnkforge.artifact.json   # phase 2: install BNK            (depends_on cluster)
roksbnkctl/testing/   bnkforge.pack.json + bnkforge.artifact.json   # phase 3: testing               (depends_on cluster)
roksbnkctl/gateway/   bnkforge.pack.json + bnkforge.artifact.json   # phase 4: gateway               (depends_on bnk)
forge-blueprint.json                                                # composes the 4 phases via depends_on (cloud_provider: ibm)
docs/USING-WITH-BNK-FORGE.md                                        # UI walkthrough for a manual test
docs/specs/                                                         # the design specs (historical; bnk-forge has since implemented them)
```

Each phase artifact declares `state.scope: deployment` so the four modules share
one roksbnkctl `/work` workspace; `apply` runs `[init, <phase> up]` (idempotent,
re-runnable). Deploy a single phase to re-run it, or deploy the blueprint /
project to run them in dependency order.

Validated against BNK Forge's `validate_pack_manifest` + `validate_artifact_manifest` + `BlueprintManifest`.
